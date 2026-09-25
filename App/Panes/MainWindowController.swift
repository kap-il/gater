import AppKit
import GaterCore

/// The one Gater window (spec §4.1 item 6):
///
///     ┌──────────────────────────┬─────────────────┐
///     │ [orchestrator][shell 1]  │ delegate: auth  │
///     │                          │  (terminal)     │
///     │  orchestrator terminal   ├─────────────────┤
///     │                          │ delegate: dash  │
///     │                          ├─────────────────┤
///     │                          │ events          │
///     └──────────────────────────┴─────────────────┘
///
/// Orchestrator and shells are tabs; each delegate is a tile stacked in
/// the side column above the event feed (the map's future home).
final class MainWindowController: NSWindowController, NSTabViewDelegate {
    let paneManager: PaneManager
    let eventFeed = EventFeedView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
    private let tabView = NSTabView()
    private let rootSplit = NSSplitView()
    private let sideSplit = NSSplitView()
    private var tiles: [String: PaneTileView] = [:]
    /// The pane whose terminal last had keyboard focus.
    private(set) var focusedPaneId: String?

    private static let sideWidth: CGFloat = 360
    private static let feedHeightWithTiles: CGFloat = 160

    init(paneManager: PaneManager) {
        self.paneManager = paneManager

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Gater — \((paneManager.repoRoot as NSString).lastPathComponent)"
        window.setFrameAutosaveName("GaterMainWindow")
        window.minSize = NSSize(width: 700, height: 400)
        super.init(window: window)

        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self

        // NSSplitView records each pane's *current* size as its preferred
        // size on first layout, so seed real frames before adding them —
        // a zero-width pane otherwise loses the whole window to its sibling.
        let content = window.contentRect(forFrameRect: window.frame).size
        let sideWidth = min(Self.sideWidth, content.width / 2)
        rootSplit.frame = NSRect(origin: .zero, size: content)
        rootSplit.isVertical = true
        rootSplit.dividerStyle = .thin
        tabView.frame = NSRect(x: 0, y: 0, width: content.width - sideWidth - 1, height: content.height)
        sideSplit.frame = NSRect(x: content.width - sideWidth, y: 0, width: sideWidth, height: content.height)
        sideSplit.isVertical = false
        sideSplit.dividerStyle = .thin
        eventFeed.frame = sideSplit.bounds
        sideSplit.addArrangedSubview(eventFeed)

        rootSplit.addArrangedSubview(tabView)
        rootSplit.addArrangedSubview(sideSplit)
        // Window resizes go to the main area; the side column keeps its width.
        rootSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        rootSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        NSLayoutConstraint.activate([
            tabView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            sideSplit.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            eventFeed.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
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

    // MARK: - Adding and removing panes

    private func add(_ pane: Pane) {
        pane.view.onFocusChange = { [weak self, weak pane] focused in
            guard let self, let pane, focused else { return }
            self.focus(paneId: pane.id)
        }
        if pane.role == .delegate {
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
            layoutSideColumn()
        } else {
            let index = tabView.indexOfTabViewItem(withIdentifier: pane.id)
            if index != NSNotFound { tabView.removeTabViewItem(tabView.tabViewItem(at: index)) }
        }
        if let next = selectedPane ?? paneManager.orchestrator { window?.makeFirstResponder(next.view) }
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
        tiles[pane.id] = tile

        // Seed a sensible frame (see the NSSplitView note in init), then
        // insert above the event feed.
        tile.frame = NSRect(x: 0, y: 0, width: sideSplit.bounds.width, height: sideSplit.bounds.height / 2)
        sideSplit.insertArrangedSubview(tile, at: tiles.count - 1)
        sideSplit.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: tiles.count - 1)

        if widenColumn {
            // A delegate runs a full claude session; give the column room.
            let target = max(rootSplit.bounds.width * 0.45, Self.sideWidth)
            rootSplit.setPosition(rootSplit.bounds.width - target, ofDividerAt: 0)
        }
        layoutSideColumn()
        window?.makeFirstResponder(pane.view)
    }

    /// Tiles share the column equally above a fixed-height event feed; with
    /// no tiles, the feed fills the column.
    private func layoutSideColumn() {
        sideSplit.layoutSubtreeIfNeeded()
        let count = tiles.count
        guard count > 0 else { return }
        let total = sideSplit.bounds.height
        let divider = sideSplit.dividerThickness
        let feed = min(Self.feedHeightWithTiles, total / 3)
        let tileHeight = (total - feed - CGFloat(count) * divider) / CGFloat(count)
        for index in 0..<count {
            sideSplit.setPosition(CGFloat(index + 1) * tileHeight + CGFloat(index) * divider, ofDividerAt: index)
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
