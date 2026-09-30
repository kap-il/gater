import AppKit
import G8rCore

/// A live tail of the event log: what each session is editing and running.
final class EventFeedView: NSView {
    private let textView: NSTextView
    private let scrollView = NSScrollView()
    private let maxLines = 500
    private var lineCount = 0

    override init(frame: NSRect) {
        textView = NSTextView(frame: frame)
        super.init(frame: frame)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Theme.typewriter(12)
        textView.drawsBackground = true
        textView.backgroundColor = Theme.surface
        textView.insertionPointColor = Theme.brightAccent
        textView.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.5)]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surface
        scrollView.scrollerKnobStyle = .light
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Events")
        header.font = Theme.heading(16)
        header.textColor = Theme.brightAccent
        let rule = NSTextField(labelWithString: String(repeating: "═", count: 80))
        rule.font = Theme.typewriter(11)
        rule.textColor = Theme.line
        rule.lineBreakMode = .byClipping
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        header.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 0),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func append(_ event: G8rEvent) {
        let line = Self.summary(of: event) + "\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: Self.color(for: event.kind ?? ""),
        ]
        guard let storage = textView.textStorage else { return }
        storage.append(NSAttributedString(string: line, attributes: attrs))
        lineCount += 1
        if lineCount > maxLines, let firstBreak = storage.string.firstIndex(of: "\n") {
            let length = storage.string.distance(from: storage.string.startIndex, to: firstBreak) + 1
            storage.deleteCharacters(in: NSRange(location: 0, length: length))
            lineCount -= 1
        }
        textView.scrollToEndOfDocument(nil)
    }

    /// Greens by kind, brass for commands, red for errors.
    static func color(for kind: String) -> NSColor {
        if kind.contains("error") || kind.contains("fail") { return Theme.error }
        switch kind {
        case "command": return Theme.brass
        case "edit": return Theme.brightAccent
        case "pane_opened", "pane_closed", "session_start", "stop": return Theme.muted
        default: return Theme.ink
        }
    }

    static func summary(of event: G8rEvent) -> String {
        let time = event.ts.map { String($0.dropFirst(11).prefix(8)) } ?? "--:--:--"
        let kind = event.kind ?? "?"
        let pane = event.pane ?? "-"
        var detail = ""
        switch kind {
        case "edit":
            detail = event["path"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? ""
        case "command":
            detail = event["description"]?.stringValue ?? event["command"]?.stringValue ?? ""
        case "pane_opened":
            detail = event["worktree"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? ""
        default:
            detail = event["text"]?.stringValue ?? event["tool_name"]?.stringValue ?? ""
        }
        return "\(time)  \(kind.padding(toLength: 18, withPad: " ", startingAt: 0)) \(pane.padding(toLength: 16, withPad: " ", startingAt: 0)) \(detail)"
    }
}
