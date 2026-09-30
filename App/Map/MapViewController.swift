import AppKit
import G8rCore
import G8rSymbols
import WebKit

/// Hosts the map viewer page and keeps it live. The page and everything
/// testable about it live in `MapViewer`; this only wires WebKit, timers
/// and windows to it.
final class MapViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    let planRoot: String
    var onBuild: ((_ component: String) -> Void)?
    var onRunTests: (() -> Void)?

    private var webView: WKWebView!
    private var map: LivingMap?
    private var pageReady = false
    private var measuring = false
    /// Another refresh was asked for while one was running.
    private var pending: Bool?
    private var mtimes: [String: Date] = [:]
    private var watchTimer: Timer?
    private var lastEventRefresh = Date.distantPast
    private var eventRefreshScheduled = false
    private var drawnWaiters: [() -> Void] = []
    private var fileWindows: [NSWindowController] = []

    init(planRoot: String) {
        self.planRoot = planRoot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(self), name: "g8r")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // no white flash before the page paints
        view = webView
        do {
            webView.loadHTMLString(try MapViewer.shell(), baseURL: nil)
        } catch {
            webView.loadHTMLString("<p>Couldn't load the map viewer: \(error)</p>", baseURL: nil)
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkWatchedFiles()
        }
    }

    deinit { watchTimer?.invalidate() }

    // MARK: - Refresh

    /// Measures the map again off the main thread, then redraws it.
    func refresh() { refresh(extract: false) }

    private func refresh(extract: Bool) {
        if measuring {
            pending = (pending ?? false) || extract
            return
        }
        measuring = true
        if map == nil { setBusy("Measuring…") }
        let root = planRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try StandardMap.build(planRoot: root, extract: extract) }
            DispatchQueue.main.async { self?.finished(result) }
        }
    }

    private func finished(_ result: Result<LivingMap, Error>) {
        measuring = false
        switch result {
        case .success(let map):
            self.map = map
            mtimes = currentMtimes()
            setBusy(nil)
            push()
        case .failure(let error):
            setBusy("Couldn't measure the map: \(error)")
        }
        if let extract = pending {
            pending = nil
            refresh(extract: extract)
        }
    }

    private func push() {
        guard pageReady, let map, let json = try? MapViewer.scriptJSON(map) else { return }
        webView.evaluateJavaScript("window.g8r.setMap(\(json))") { [weak self] _, _ in
            guard let self else { return }
            let waiters = drawnWaiters
            drawnWaiters = []
            waiters.forEach { $0() }
        }
    }

    func setBusy(_ text: String?) {
        guard pageReady else { return }
        let arg = text.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
        webView.evaluateJavaScript("window.g8r.setBusy(\(arg))")
    }

    /// Hook events redraw the map at most once a second; a finished test
    /// run redraws it at once.
    func noteEvent(_ event: G8rEvent) {
        if event.kind == "tests_ran" {
            refresh()
            return
        }
        guard !eventRefreshScheduled else { return }
        let wait = max(0, 1 - Date().timeIntervalSince(lastEventRefresh))
        eventRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            eventRefreshScheduled = false
            lastEventRefresh = Date()
            refresh()
        }
    }

    private func currentMtimes() -> [String: Date] {
        var out: [String: Date] = [:]
        for path in MapViewer.watchedFiles(planRoot: planRoot, map: map) {
            out[path] = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }
        return out
    }

    /// A plan doc or g8r.json changed on disk: measure again, and let a
    /// model read a free-form doc that changed.
    private func checkWatchedFiles() {
        guard map != nil, !measuring else { return }
        if currentMtimes() != mtimes { refresh(extract: true) }
    }

    // MARK: - Snapshot

    /// Writes a PNG of the map once it has been drawn.
    func snapshot(to path: String) {
        guard map != nil else {
            drawnWaiters.append { [weak self] in self?.snapshot(to: path) }
            return
        }
        // Let the page lay out the map it was just given.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.webView.takeSnapshot(with: nil) { image, _ in
                guard let image, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            if map == nil { refresh() } else { push() }
        case "build":
            guard let component = body["component"] as? String else { return }
            if let onBuild { onBuild(component) } else { setBusy("Building from the map isn't available yet.") }
        case "openFile":
            guard let path = body["path"] as? String else { return }
            openFile(path, component: body["component"] as? String)
        case "runTests":
            if let onRunTests { onRunTests() } else { setBusy("Running tests from the map isn't available yet.") }
        case "refresh":
            refresh(extract: true)
        default:
            break
        }
    }

    // Links in the page open in the browser, never in the map view.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: - Files

    private func openFile(_ relative: String, component: String?) {
        let url = URL(fileURLWithPath: MapViewer.codeRoot(planRoot: planRoot)).appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            setBusy("Couldn't read \(relative)")
            return
        }
        let symbols = component.flatMap { map?.node($0) }?.files.first { $0.path == relative }?.symbols ?? []
        let controller = FileWindowController(title: relative, text: text,
                                              tinted: MapViewer.symbolLines(in: text, symbols: symbols))
        controller.onClose = { [weak self, weak controller] in
            self?.fileWindows.removeAll { $0 === controller }
        }
        fileWindows.append(controller)
        controller.showWindow(nil)
    }
}

/// WKUserContentController keeps its handlers strongly.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A read-only window on one file, with the given lines tinted.
private final class FileWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(title: String, text: String, tinted: [Int]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let tint = NSColor.systemYellow.withAlphaComponent(0.22)
        let lineStarts = FileWindowController.lineRanges(in: text as NSString)
        for line in tinted where line < lineStarts.count {
            textView.textStorage?.addAttribute(.backgroundColor, value: tint, range: lineStarts[line])
        }
        window.contentView = scroll
        super.init(window: window)
        window.delegate = self
        window.center()
        if let first = tinted.first, first < lineStarts.count {
            textView.scrollRangeToVisible(lineStarts[first])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private static func lineRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
}
