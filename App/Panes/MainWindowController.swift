import AppKit
import G8rCore

/// The one G8r window:
///
///     ┌─────────────────────┬────────────────┬──────────────┐
///     │ [map][shell 1]      │ delegate: auth │ Events       │
///     │                     │  (terminal)    │ 15:02 edit … │
///     │  map or shell       ├────────────────┤ 15:02 stop … │
///     │  terminal           │ delegate: dash │              │
///     └─────────────────────┴────────────────┴──────────────┘
///
/// The map and shells are tabs; each delegate is a tile in the middle
/// column (hidden until the first delegate opens); the right column shows
/// what the sessions are doing, and is where the map will go.
final class MainWindowController: NSWindowController, NSTabViewDelegate {
    let paneManager: PaneManager
    let eventFeed = EventFeedView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
    private let tabView = NSTabView()
    /// A themed strip of tab buttons over a tabless NSTabView.
    private let tabBar = NSStackView()
    private let tabArea = NSView()
    private let rootSplit = NSSplitView()
    private let sideSplit = NSSplitView()
    /// Bottom of the delegate column: takes whatever height collapsed
    /// tiles leave (none while any tile is expanded).
    private let columnFiller = NSView()
    private var tiles: [String: PaneTileView] = [:]
    /// The pane whose terminal last had keyboard focus.
    private(set) var focusedPaneId: String?

    private static let feedWidth: CGFloat = 360

    init(paneManager: PaneManager) {
        self.paneManager = paneManager

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "G8r — \((paneManager.repoRoot as NSString).lastPathComponent)"
        window.setFrameAutosaveName("G8rMainWindow")
        window.minSize = NSSize(width: 700, height: 400)
        super.init(window: window)

        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.titlebarAppearsTransparent = true
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
        tabView.delegate = self
        buildTabArea()

        // NSSplitView records each pane's *current* size as its preferred
        // size on first layout, so seed real frames before adding them —
        // a zero-width pane otherwise loses the whole window to its sibling.
        let content = window.contentRect(forFrameRect: window.frame).size
        let feedWidth = min(Self.feedWidth, content.width / 3)
        rootSplit.frame = NSRect(origin: .zero, size: content)
        rootSplit.isVertical = true
        rootSplit.dividerStyle = .thin
        tabArea.frame = NSRect(x: 0, y: 0, width: content.width - feedWidth - 1, height: content.height)
        sideSplit.frame = NSRect(x: 0, y: 0, width: 0, height: content.height)
        sideSplit.isVertical = false
        sideSplit.dividerStyle = .thin
        sideSplit.isHidden = true // until the first delegate opens
        columnFiller.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        sideSplit.addArrangedSubview(columnFiller)
        eventFeed.frame = NSRect(x: content.width - feedWidth, y: 0, width: feedWidth, height: content.height)

        rootSplit.addArrangedSubview(tabArea)
        rootSplit.addArrangedSubview(sideSplit)
        rootSplit.addArrangedSubview(eventFeed)
        // Window resizes go to the terminals; the feed keeps its width.
        rootSplit.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 0)
        rootSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        rootSplit.setHoldingPriority(NSLayoutConstraint.Priority(270), forSubviewAt: 2)
        NSLayoutConstraint.activate([
            tabArea.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            eventFeed.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.line.cgColor // shows through as the split dividers
        rootSplit.autoresizingMask = [.width, .height]
        background.frame = rootSplit.frame
        background.addSubview(rootSplit)
        window.contentView = background
        window.center()

        paneManager.onPaneAdded = { [weak self] pane in self?.add(pane) }
        paneManager.onPaneRemoved = { [weak self] pane in self?.remove(pane) }
        paneManager.onPaneTitleChanged = { [weak self] pane in self?.refreshTitle(for: pane) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pane actions like Close and New Shell apply to: the focused one,
    /// else the selected tab.
    var selectedPane: Pane? {
        if let id = focusedPaneId, let pane = paneManager.pane(id: id) { return pane }
        return (tabView.selectedTabViewItem?.identifier as? String).flatMap(paneManager.pane(id:))
    }

    // MARK: - The map

    static let mapTabId = "map"

    /// The map is the first tab, ahead of the shells.
    func addMap(_ controller: NSViewController) {
        let item = NSTabViewItem(identifier: Self.mapTabId)
        item.label = "Map"
        item.view = controller.view
        tabView.insertTabViewItem(item, at: 0)
        refreshTabBar()
    }

    func showMap() {
        tabView.selectTabViewItem(withIdentifier: Self.mapTabId)
    }

    // MARK: - Adding and removing panes

    private func add(_ pane: Pane) {
        pane.view.onFocusChange = { [weak self, weak pane] focused in
            guard let self, let pane, focused else { return }
            self.focus(paneId: pane.id)
        }
        if pane.role == .delegate || pane.role == .build {
            addTile(for: pane)
        } else {
            addTab(for: pane)
        }
    }

    private func remove(_ pane: Pane) {
        if focusedPaneId == pane.id { focusedPaneId = nil }
        if let tile = tiles.removeValue(forKey: pane.id) {
            sideSplit.removeArrangedSubview(tile)
            tile.removeFromSuperview()
            if tiles.isEmpty { sideSplit.isHidden = true }
            layoutSideColumn()
        } else {
            let index = tabView.indexOfTabViewItem(withIdentifier: pane.id)
            if index != NSNotFound { tabView.removeTabViewItem(tabView.tabViewItem(at: index)) }
            refreshTabBar()
        }
        window?.makeFirstResponder(selectedPane?.view ?? tabView.selectedTabViewItem?.view)
    }

    private func addTab(for pane: Pane) {
        let item = NSTabViewItem(identifier: pane.id)
        item.label = pane.displayTitle
        item.view = pane.view
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        refreshTabBar()
        window?.makeFirstResponder(pane.view)
    }

    private func addTile(for pane: Pane) {
        let widenColumn = tiles.isEmpty
        let tile = PaneTileView(pane: pane)
        tile.onClose = { [weak self] pane in self?.paneManager.close(pane) }
        tile.onToggleCollapse = { [weak self] tile in self?.toggleCollapse(tile) }
        tiles[pane.id] = tile

        // Seed a sensible frame (see the NSSplitView note in init), then
        // insert above the filler.
        tile.frame = NSRect(x: 0, y: 0, width: sideSplit.bounds.width, height: sideSplit.bounds.height / 2)
        sideSplit.insertArrangedSubview(tile, at: tiles.count - 1) // above the filler

        if widenColumn {
            // A delegate runs a full agent session; give its column room
            // between the tabs and the feed.
            sideSplit.isHidden = false
            rootSplit.layoutSubtreeIfNeeded()
            let total = rootSplit.bounds.width
            let feedWidth = min(max(eventFeed.frame.width, 240), total / 3)
            let tilesWidth = max((total - feedWidth) * 0.45, 360)
            rootSplit.setPosition(total - feedWidth - tilesWidth, ofDividerAt: 0)
            rootSplit.setPosition(total - feedWidth, ofDividerAt: 1)
        }
        layoutSideColumn()
        window?.makeFirstResponder(pane.view)
    }

    func setCollapsed(_ collapsed: Bool, paneId: String) {
        guard let tile = tiles[paneId], tile.isCollapsed != collapsed else { return }
        toggleCollapse(tile)
    }

    private func toggleCollapse(_ tile: PaneTileView) {
        tile.setCollapsed(!tile.isCollapsed)
        if tile.isCollapsed, focusedPaneId == tile.pane.id {
            // Don't type into a hidden pane.
            window?.makeFirstResponder(tabView.selectedTabViewItem?.view)
        } else if !tile.isCollapsed {
            window?.makeFirstResponder(tile.pane.view)
        }
        layoutSideColumn()
    }

    /// Collapsed tiles take just their header; expanded tiles share the
    /// rest of the column equally. With every tile collapsed, the filler
    /// below them takes the leftover space.
    private func layoutSideColumn() {
        sideSplit.layoutSubtreeIfNeeded()
        let ordered = sideSplit.arrangedSubviews.compactMap { $0 as? PaneTileView }
        guard !ordered.isEmpty else { return }

        let total = sideSplit.bounds.height
        let divider = sideSplit.dividerThickness
        let collapsedHeight = PaneTileView.headerHeight
        let expandedCount = ordered.filter { !$0.isCollapsed }.count
        let collapsedTotal = CGFloat(ordered.count - expandedCount) * collapsedHeight
        let expandedHeight = expandedCount > 0
            ? (total - collapsedTotal - CGFloat(ordered.count) * divider) / CGFloat(expandedCount)
            : 0
        // Window height changes go to expanded tiles (250) first; the filler
        // (740) only grows when every tile is collapsed (750).
        sideSplit.setHoldingPriority(NSLayoutConstraint.Priority(740), forSubviewAt: ordered.count)
        var y: CGFloat = 0
        for (index, tile) in ordered.enumerated() {
            sideSplit.setHoldingPriority(NSLayoutConstraint.Priority(tile.isCollapsed ? 750 : 250), forSubviewAt: index)
            y += tile.isCollapsed ? collapsedHeight : expandedHeight
            sideSplit.setPosition(y, ofDividerAt: index)
            sideSplit.layoutSubtreeIfNeeded()
            y += divider
        }
        if ProcessInfo.processInfo.environment["G8R_DEBUG_LAYOUT"] != nil {
            for view in sideSplit.arrangedSubviews {
                FileHandle.standardError.write("LAYOUT \(type(of: view)) \(view.frame) min=\(view.fittingSize.height)\n".data(using: .utf8)!)
            }
        }
    }

    // MARK: - Focus and titles

    private func focus(paneId: String) {
        focusedPaneId = paneId
        for (id, tile) in tiles { tile.setFocused(id == paneId) }
    }

    private func refreshTitle(for pane: Pane) {
        if let tile = tiles[pane.id] {
            tile.refreshTitle()
            return
        }
        let index = tabView.indexOfTabViewItem(withIdentifier: pane.id)
        guard index != NSNotFound else { return }
        let title = pane.session.title
        tabView.tabViewItem(at: index).label = title.isEmpty
            ? pane.displayTitle
            : "\(pane.displayTitle) — \(title.prefix(40))"
        refreshTabBar()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let view = tabViewItem?.view { window?.makeFirstResponder(view) }
        refreshTabBar()
    }

    // MARK: - Tab bar

    private static let tabBarHeight: CGFloat = 30

    private func buildTabArea() {
        tabArea.wantsLayer = true
        tabArea.layer?.backgroundColor = Theme.background.cgColor
        let strip = NSView()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = Theme.surface.cgColor
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.line.cgColor
        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.alignment = .bottom
        for v in [strip, rule, tabBar, tabView] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        tabArea.addSubview(strip)
        strip.addSubview(tabBar)
        strip.addSubview(rule)
        tabArea.addSubview(tabView)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: tabArea.topAnchor),
            strip.leadingAnchor.constraint(equalTo: tabArea.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: tabArea.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),
            tabBar.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 8),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: strip.trailingAnchor, constant: -8),
            tabBar.topAnchor.constraint(equalTo: strip.topAnchor, constant: 4),
            tabBar.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            tabView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: tabArea.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: tabArea.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: tabArea.bottomAnchor),
        ])
    }

    private func refreshTabBar() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let selected = tabView.selectedTabViewItem
        for (index, item) in tabView.tabViewItems.enumerated() {
            // Every pane's tab can be closed; the map's can't.
            let closable = (item.identifier as? String) != Self.mapTabId
            let tab = TabItemView(title: item.label, index: index, selected: item === selected, closable: closable)
            tab.onSelect = { [weak self] in self?.tabView.selectTabViewItem(at: index) }
            tab.onClose = { [weak self] in self?.closeTab(at: index) }
            tabBar.addArrangedSubview(tab)
        }
    }

    private func closeTab(at index: Int) {
        guard index < tabView.numberOfTabViewItems,
              let id = tabView.tabViewItem(at: index).identifier as? String,
              let pane = paneManager.pane(id: id) else { return }
        paneManager.close(pane)
    }

    /// ⌘1…⌘9: tabs first, then delegate tiles top to bottom.
    func selectPane(at index: Int) {
        if index < tabView.numberOfTabViewItems {
            tabView.selectTabViewItem(at: index)
            return
        }
        let tileIndex = index - tabView.numberOfTabViewItems
        let ordered = sideSplit.arrangedSubviews.compactMap { $0 as? PaneTileView }
        guard tileIndex < ordered.count else { return }
        window?.makeFirstResponder(ordered[tileIndex].pane.view)
    }
}

/// One tab in the themed tab bar: its label on a raised green tab when
/// selected, a muted label otherwise, and a close button inside the tab. A
/// long title (a terminal's own title is appended) is cut off with "…" so
/// the tab, and its close button, keep a fixed maximum width.
private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private static let maxWidth: CGFloat = 280
    private static let closeWidth: CGFloat = 18

    init(title: String, index: Int, selected: Bool, closable: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.backgroundColor = (selected ? Theme.raised : NSColor.clear).cgColor
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = Theme.line.cgColor
        toolTip = title

        let shortcut = index < 9 ? "  \u{2318}\(index + 1)" : ""
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: Theme.label(13, bold: selected),
            .foregroundColor: selected ? Theme.ink : Theme.muted,
        ])
        text.append(NSAttributedString(string: shortcut, attributes: [
            .font: Theme.label(10),
            .foregroundColor: selected ? Theme.brightAccent : Theme.line,
        ]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        let trailingSpace: CGFloat = closable ? Self.closeWidth + 6 : 12
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(equalToConstant: min(text.size().width + 12 + trailingSpace + 2, Self.maxWidth)),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingSpace),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        guard closable else { return }
        let close = NSButton(title: "×", target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.toolTip = "Close \(title)"
        close.attributedTitle = NSAttributedString(string: "×", attributes: [
            .font: Theme.label(13), .foregroundColor: selected ? Theme.ink : Theme.muted,
        ])
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: Self.closeWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    @objc private func closeClicked() { onClose?() }
}
