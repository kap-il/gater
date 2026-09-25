import AppKit

/// A delegate pane as a box in the side column: a title bar (name,
/// worktree branch, live terminal title) over the pane's terminal.
final class PaneTileView: NSView {
    let pane: Pane
    private let titleLabel = NSTextField(labelWithString: "")
    private let header = NSView()

    var onClose: ((Pane) -> Void)?

    init(pane: Pane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        layer?.masksToBounds = true

        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 10)
        close.toolTip = "Close pane (the worktree is kept)"
        close.translatesAutoresizingMaskIntoConstraints = false

        let terminal = pane.view
        terminal.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(titleLabel)
        header.addSubview(close)
        addSubview(header)
        addSubview(terminal)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        refreshTitle()
        setFocused(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refreshTitle() {
        let branch = "gater/\(pane.name)"
        let live = pane.session.title
        titleLabel.stringValue = live.isEmpty
            ? "\(pane.displayTitle)  ·  \(branch)"
            : "\(pane.displayTitle)  ·  \(branch)  ·  \(live)"
    }

    func setFocused(_ focused: Bool) {
        layer?.borderColor = (focused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = focused ? 2 : 1
        titleLabel.textColor = focused ? .labelColor : .secondaryLabelColor
    }

    @objc private func closeClicked() {
        onClose?(pane)
    }
}
