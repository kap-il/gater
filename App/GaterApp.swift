import AppKit
import GaterCore

@main
enum GaterMain {
    // NSApplication holds its delegate weakly.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// Wires the pieces together: pick the target repo, open its event log,
/// listen for hook events, and open the window with the orchestrator pane.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventLog: EventLog?
    private var eventBus: EventBus?
    private var planStore: PlanStore?
    private var paneManager: PaneManager!
    private var windowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()

        guard let repoRoot = resolveRepoRoot() else {
            NSApp.terminate(nil)
            return
        }

        let logPath = URL(fileURLWithPath: repoRoot).appendingPathComponent(".gater/events.jsonl")
        // Runtime state (event log, plan, snapshots) is local, never committed.
        try? GitWorktree.exclude(pattern: "/.gater/", comment: "Gater runtime state", in: repoRoot)
        do {
            eventLog = try EventLog(path: logPath)
        } catch {
            showError("Couldn't open \(logPath.path)", error)
        }

        // The plan is derived state: always rebuilt from the log, never
        // trusted from disk (spec §4.5).
        let store = PlanStore(path: PlanStore.defaultPath(repoRoot: repoRoot))
        do {
            try store.rebuild(from: (try? EventLog.replay(path: logPath)) ?? [])
        } catch {
            showError("Couldn't write \(store.path.path)", error)
        }
        planStore = store

        paneManager = PaneManager(repoRoot: repoRoot) { [weak self] event in self?.record(event) }
        windowController = MainWindowController(paneManager: paneManager)
        windowController.showWindow(nil)

        startEventBus()
        paneManager.installRepoIntegrations()

        do {
            try paneManager.spawnOrchestrator()
        } catch {
            showError("Couldn't start the orchestrator pane", error)
        }
        // GATER_DEBUG_DELEGATES=a,b opens those delegates at launch, for
        // exercising the tiled layout (with GATER_SNAPSHOT) without clicks.
        for name in (ProcessInfo.processInfo.environment["GATER_DEBUG_DELEGATES"] ?? "")
            .split(separator: ",").map(String.init) where !name.isEmpty {
            _ = try? paneManager.spawnDelegate(name: name)
        }
        for name in (ProcessInfo.processInfo.environment["GATER_DEBUG_COLLAPSED"] ?? "")
            .split(separator: ",").map(String.init) where !name.isEmpty {
            windowController.setCollapsed(true, paneId: "delegate-\(name)")
        }
        // GATER_DEBUG_TOGGLE=a,b: collapse those at 0.7s and expand them
        // again at 1.4s, to exercise the round trip on laid-out panes.
        let toggle = (ProcessInfo.processInfo.environment["GATER_DEBUG_TOGGLE"] ?? "")
            .split(separator: ",").map(String.init)
        for (delay, collapsed) in [(0.7, true), (1.4, false)] where !toggle.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                for name in toggle { self?.windowController.setCollapsed(collapsed, paneId: "delegate-\(name)") }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        scheduleDebugSnapshot()
    }

    /// GATER_SNAPSHOT=<file.png>: render the window to a PNG after 2s.
    /// Lets UI changes be checked headlessly (no screen-recording
    /// permission needed, unlike screencapture).
    private func scheduleDebugSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["GATER_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let view = self?.windowController.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        paneManager?.closeAll()
        eventBus?.stop()
        eventLog?.close()
    }

    // MARK: - Events

    /// Events Gater itself produces (pane lifecycle, human input).
    private func record(_ event: GaterEvent) {
        let stored = (try? eventLog?.append(event)) ?? event
        planStore?.apply(stored)
        windowController?.eventFeed.append(stored)
    }

    private func startEventBus() {
        let socketPath = ProcessInfo.processInfo.environment["GATER_COLLECTOR"] ?? EventBus.defaultSocketPath()
        // The bus appends hook events to the log itself; the callback only
        // feeds the live view.
        let bus = EventBus(socketPath: socketPath, eventLog: eventLog) { [weak self] event in
            self?.planStore?.apply(event)
            DispatchQueue.main.async { self?.windowController?.eventFeed.append(event) }
        }
        do {
            try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try bus.start()
            eventBus = bus
        } catch {
            windowController.eventFeed.append(GaterEvent(kind: "bus_error", extra: [
                "text": .string("couldn't listen on \(socketPath): \(error)"),
            ]))
        }
    }

    // MARK: - Repo selection

    /// The repo to orchestrate: first CLI argument, else the current
    /// directory, else ask. Must be a git repository (delegates need
    /// worktrees).
    private func resolveRepoRoot() -> String? {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let candidate = args.first ?? FileManager.default.currentDirectoryPath
        if let root = GitWorktree.repoRoot(containing: candidate) { return root }

        let panel = NSOpenPanel()
        panel.message = "Choose the git repository Gater should orchestrate"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        while panel.runModal() == .OK, let url = panel.url {
            if let root = GitWorktree.repoRoot(containing: url.path) { return root }
            let alert = NSAlert()
            alert.messageText = "\(url.lastPathComponent) isn't inside a git repository."
            alert.runModal()
        }
        return nil
    }

    // MARK: - Actions

    @objc private func newDelegate(_ sender: Any?) {
        guard let name = prompt(title: "New delegate",
                                message: "Creates ../\((paneManager.repoRoot as NSString).lastPathComponent)-<name> on branch gater/<name> and starts \(paneManager.agentCommand) there.",
                                placeholder: "e.g. auth") else { return }
        do {
            try paneManager.spawnDelegate(name: name)
        } catch {
            showError("Couldn't create delegate \"\(name)\"", error)
        }
    }

    @objc private func newShell(_ sender: Any?) {
        do {
            try paneManager.spawnShell(in: windowController.selectedPane?.worktree)
        } catch {
            showError("Couldn't start a shell", error)
        }
    }

    @objc private func closePane(_ sender: Any?) {
        guard let pane = windowController.selectedPane else { return }
        paneManager.close(pane)
    }

    /// Manual check for `inject(text:)` until the overlap detector drives it.
    @objc private func injectIntoOrchestrator(_ sender: Any?) {
        guard let orchestrator = paneManager.orchestrator else { return }
        guard let text = prompt(title: "Inject into orchestrator",
                                message: "Typed into the orchestrator pane and submitted, as Gater's wake messages will be.",
                                placeholder: "[GATER] test") else { return }
        orchestrator.inject(text: text)
    }

    @objc private func selectPaneTab(_ sender: NSMenuItem) {
        windowController.selectPane(at: sender.tag)
    }

    // MARK: - UI helpers

    private func prompt(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Gater", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Gater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let paneItem = NSMenuItem()
        let paneMenu = NSMenu(title: "Pane")
        paneMenu.addItem(item("New Delegate…", #selector(newDelegate(_:)), "d", [.command, .shift]))
        paneMenu.addItem(item("New Shell", #selector(newShell(_:)), "t"))
        paneMenu.addItem(item("Close Pane", #selector(closePane(_:)), "w"))
        paneMenu.addItem(.separator())
        paneMenu.addItem(item("Inject into Orchestrator…", #selector(injectIntoOrchestrator(_:)), "i", [.command, .shift]))
        paneMenu.addItem(.separator())
        for index in 0..<9 {
            let select = item("Select Pane \(index + 1)", #selector(selectPaneTab(_:)), "\(index + 1)")
            select.tag = index
            paneMenu.addItem(select)
        }
        paneItem.submenu = paneMenu
        main.addItem(paneItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // nil target → first responder, i.e. the focused TerminalView.
        editMenu.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }
}
