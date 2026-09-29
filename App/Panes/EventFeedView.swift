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
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Events")
        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
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
            .foregroundColor: NSColor.labelColor,
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
