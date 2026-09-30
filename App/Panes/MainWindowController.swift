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

        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self

        // NSSplitView records each pane's *current* size as its preferred
        // size on first layout, so seed real frames before adding them —
        // a zero-width pane otherwise loses the whole window to its sibling.
        let content = window.contentRect(forFrameRect: window.frame).size
        let feedWidth = min(Self.feedWidth, content.width / 3)
        rootSplit.frame = NSRect(origin: .zero, size: content)
        rootSplit.isVertical = true
        rootSplit.dividerStyle = .thin
        tabView.frame = NSRect(x: 0, y: 0, width: content.width - feedWidth - 1, height: content.height)
        sideSplit.frame = NSRect(x: 0, y: 0, width: 0, height: content.height)
        sideSplit.isVertical = false
        sideSplit.dividerStyle = .thin
        sideSplit.isHidden = true // until the first delegate opens
        columnFiller.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        sideSplit.addArrangedSubview(columnFiller)
        eventFeed.frame = NSRect(x: content.width - feedWidth, y: 0, width: feedWidth, height: content.height)

        rootSplit.addArrangedSubview(tabView)
        rootSplit.addArrangedSubview(sideSplit)
        rootSplit.addArrangedSubview(eventFeed)
        // Window resizes go to the terminals; the feed keeps its width.
        rootSplit.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 0)
        rootSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        rootSplit.setHoldingPriority(NSLayoutConstraint.Priority(270), forSubviewAt: 2)
        NSLayoutConstraint.activate([
            tabView.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            eventFeed.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        window.contentView = rootSplit
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
        }
        window?.makeFirstResponder(selectedPane?.view ?? tabView.selectedTabViewItem?.view)
    }

    private func addTab(for pane: Pane) {
        let item = NSTabViewItem(identifier: pane.id)
        item.label = pane.displayTitle
        item.view = pane.view
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
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
            // A delegate runs a full claude session; give its column room
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
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let view = tabViewItem?.view { window?.makeFirstResponder(view) }
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
