import AppKit
import GaterCore

/// Placeholder for the map (spec §4.11, a later phase): a live tail of the
/// event log, so hook traffic is visible while the terminal work lands.
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

    func append(_ event: GaterEvent) {
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

    static func summary(of event: GaterEvent) -> String {
        let time = event.ts.map { String($0.dropFirst(11).prefix(8)) } ?? "--:--:--"
        let kind = event.kind ?? "?"
        let pane = event.pane ?? "-"
        var detail = ""
        switch kind {
        case "delegation":
            let gater = event.fields["gater"]
            let type = gater?.value(atPath: "type")?.stringValue ?? "?"
            let id = gater?.value(atPath: "id")?.stringValue ?? "?"
            let feature = gater?.value(atPath: "feature")?.stringValue.map { " \($0)" } ?? ""
            detail = "\(type) \(id)\(feature) → \(event["to_pane"]?.stringValue ?? event["to"]?.stringValue ?? "?")"
        case "message":
            let to = event["to_pane"]?.stringValue ?? event["to"]?.stringValue ?? "?"
            detail = "→ \(to): \(event["summary"]?.stringValue ?? "")"
        case "edit":
            detail = event["path"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? ""
        case "command":
            detail = event["command"]?.stringValue ?? ""
        case "symbols_changed":
            let changes = (event.fields["changes"]?.arrayValue ?? []).compactMap { change -> String? in
                guard let symbol = change.value(atPath: "symbol")?.stringValue,
                      let kind = change.value(atPath: "change")?.stringValue else { return nil }
                return "\(symbol):\(kind)"
            }
            let surface = event["public_surface"] == .bool(true) ? "⚠︎ " : ""
            detail = "\(surface)\(event["path"]?.stringValue ?? "") \(changes.joined(separator: ", "))"
        case "done_note":
            detail = "\(event["dish"]?.stringValue ?? "?"): \(event["did"]?.stringValue ?? "")"
        default:
            detail = event["text"]?.stringValue ?? event["tool_name"]?.stringValue ?? ""
        }
        return "\(time)  \(kind.padding(toLength: 18, withPad: " ", startingAt: 0)) \(pane.padding(toLength: 16, withPad: " ", startingAt: 0)) \(detail)"
    }
}
