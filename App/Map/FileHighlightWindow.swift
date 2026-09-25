import AppKit
import GaterCore
import GaterSymbols

/// File highlight view (spec §4.11): a feature's file, from the worktree
/// where that feature is being built.
/// - solid tint: lines owned by this feature (dashed-ownership symbols get
///   a lighter tint)
/// - faint underline: lines that use another feature's changed code
/// - red: lines in an active overlap
/// Ranges are recomputed from tree-sitter every time it opens.
final class FileHighlightWindow: NSWindowController {
    static var open: [FileHighlightWindow] = []

    init(feature: String, path: String, worktree: String, model: MapModel, pane: String?) {
        let absolute = (worktree as NSString).appendingPathComponent(path)
        let source = (try? String(contentsOfFile: absolute, encoding: .utf8)) ?? "(couldn't read \(absolute))"

        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "\(feature) — \(path)"
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = false
        super.init(window: window)

        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.backgroundColor = .textBackgroundColor

        let accent = FeatureCardView.color(.cooking)
        let lines = source.components(separatedBy: "\n")
        var owned: [Int: Bool] = [:] // line → uncertain?
        for symbol in (try? SymbolExtractor.symbols(source: source, path: path)) ?? [] {
            guard let owner = model.owner(of: symbol.id), owner.feature == feature else { continue }
            for line in symbol.startLine...symbol.endLine { owned[line] = owner.uncertain && (owned[line] ?? true) }
        }
        let uses = pane.map { model.useSites(inPane: $0).filter { $0.path == path } } ?? []

        let body = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (index, line) in lines.enumerated() {
            let number = index + 1
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            if let uncertain = owned[number] {
                attrs[.backgroundColor] = accent.withAlphaComponent(uncertain ? 0.10 : 0.22)
            }
            if let use = uses.first(where: { $0.line == number }) {
                if use.overlapping {
                    attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.30)
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    attrs[.underlineColor] = NSColor.secondaryLabelColor
                }
                attrs[.toolTip] = "uses \(use.symbol)\(use.overlapping ? " (overlap)" : "")"
            }
            let gutter = NSAttributedString(string: String(format: "%4d  ", number), attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            body.append(gutter)
            body.append(NSAttributedString(string: line + (number < lines.count ? "\n" : ""), attributes: attrs))
        }
        text.textStorage?.setAttributedString(body)

        let legend = NSTextField(labelWithString: "tint = owned by \(feature)   ·   lighter = uncertain   ·   dotted = uses another feature   ·   red = overlap")
        legend.font = NSFont.systemFont(ofSize: 10)
        legend.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [scroll, legend])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func show(feature: String, path: String, worktree: String, model: MapModel, pane: String?) {
        let controller = FileHighlightWindow(feature: feature, path: path, worktree: worktree, model: model, pane: pane)
        open.append(controller)
        controller.showWindow(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window,
                                               queue: .main) { _ in
            open.removeAll { $0 === controller }
        }
    }
}
