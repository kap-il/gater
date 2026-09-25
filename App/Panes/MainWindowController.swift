import AppKit
import GaterCore

/// The one Gater window: terminal panes as tabs on the left, the map
/// (currently the event feed) on the right (spec §4.1 item 6).
final class MainWindowController: NSWindowController, NSTabViewDelegate {
    let paneManager: PaneManager
    let eventFeed = EventFeedView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
    private let tabView = NSTabView()

    init(paneManager: PaneManager) {
        self.paneManager = paneManager

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Gater — \((paneManager.repoRoot as NSString).lastPathComponent)"
        window.setFrameAutosaveName("GaterMainWindow")
        window.minSize = NSSize(width: 600, height: 300)
        super.init(window: window)

        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tabView)
        split.addArrangedSubview(eventFeed)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        window.contentView = split
        split.setPosition(1000, ofDividerAt: 0)
        window.center()

        paneManager.onPaneAdded = { [weak self] pane in self?.addTab(for: pane) }
        paneManager.onPaneRemoved = { [weak self] pane in self?.removeTab(for: pane) }
        paneManager.onPaneTitleChanged = { [weak self] pane in self?.refreshTitle(for: pane) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var selectedPane: Pane? {
        (tabView.selectedTabViewItem?.identifier as? String).flatMap(paneManager.pane(id:))
    }

    private func addTab(for pane: Pane) {
        let item = NSTabViewItem(identifier: pane.id)
        item.label = pane.displayTitle
        item.view = pane.view
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        window?.makeFirstResponder(pane.view)
    }

    private func removeTab(for pane: Pane) {
        let index = tabView.indexOfTabViewItem(withIdentifier: pane.id)
        guard index != NSNotFound else { return }
        tabView.removeTabViewItem(tabView.tabViewItem(at: index))
        if let current = selectedPane { window?.makeFirstResponder(current.view) }
    }

    private func refreshTitle(for pane: Pane) {
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

    func selectTab(at index: Int) {
        guard index < tabView.numberOfTabViewItems else { return }
        tabView.selectTabViewItem(at: index)
    }
}
