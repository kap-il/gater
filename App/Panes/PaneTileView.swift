import AppKit

/// A delegate pane as a box in the side column: a title bar (name,
/// worktree branch, live terminal title) over the pane's terminal.
final class PaneTileView: NSView {
    let pane: Pane
    private let titleLabel = NSTextField(labelWithString: "")
    private let header = NSView()
    private let chevron = NSButton()

    static let headerHeight: CGFloat = 22

    /// Collapsed tiles show only their header. The terminal is frozen at its
    /// last size rather than shrunk, so the agent sees no resize and keeps
    /// running undisturbed.
    private(set) var isCollapsed = false
    private var terminalBottom: NSLayoutConstraint!
    private var frozenTerminalHeight: NSLayoutConstraint!
    private var minHeight: NSLayoutConstraint!
    /// Required while collapsed: NSSplitView treats divider positions as
    /// preferences, so only a hard constraint keeps the tile header-sized.
    private var collapsedHeight: NSLayoutConstraint!

    var onClose: ((Pane) -> Void)?
    var onToggleCollapse: ((PaneTileView) -> Void)?

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

        chevron.isBordered = false
        chevron.title = "▾"
        chevron.font = NSFont.systemFont(ofSize: 11)
        chevron.target = self
        chevron.action = #selector(toggleClicked)
        chevron.toolTip = "Collapse / expand (or double-click the title bar)"
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleClicked))
        doubleClick.numberOfClicksRequired = 2
        header.addGestureRecognizer(doubleClick)

        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 10)
        close.toolTip = "Close pane (the worktree is kept)"
        close.translatesAutoresizingMaskIntoConstraints = false

        let terminal = pane.view
        terminal.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(chevron)
        header.addSubview(titleLabel)
        header.addSubview(close)
        addSubview(header)
        addSubview(terminal)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            chevron.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            chevron.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        terminalBottom = terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
        frozenTerminalHeight = terminal.heightAnchor.constraint(equalToConstant: 0)
        minHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        collapsedHeight = heightAnchor.constraint(equalToConstant: Self.headerHeight)
        NSLayoutConstraint.activate([terminalBottom, minHeight])
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

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        let terminal = pane.view
        if collapsed {
            frozenTerminalHeight.constant = terminal.frame.height
            terminalBottom.isActive = false
            frozenTerminalHeight.isActive = true
            minHeight.isActive = false
            collapsedHeight.isActive = true
        } else {
            collapsedHeight.isActive = false
            frozenTerminalHeight.isActive = false
            terminalBottom.isActive = true
            minHeight.isActive = true
        }
        terminal.isHidden = collapsed
        chevron.title = collapsed ? "▸" : "▾"
    }

    @objc private func toggleClicked() {
        onToggleCollapse?(self)
    }

    @objc private func closeClicked() {
        onClose?(pane)
    }
}
