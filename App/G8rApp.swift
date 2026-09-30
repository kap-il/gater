import AppKit
import G8rCore

@main
enum G8rMain {
    // NSApplication holds its delegate weakly.
    private static let delegate = AppDelegate()

    static func main() {
        BundledFonts.register()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// Wires the pieces together: pick the target repo, open its event log,
/// listen for hook events, and open the window with the first pane.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventLog: EventLog?
    private var eventBus: EventBus?
    private var paneManager: PaneManager!
    private var windowController: MainWindowController!
    private var mapController: MapViewController!
    private var buildLauncher: BuildLauncher?
    private var testsRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()

        guard let repoRoot = resolveRepoRoot() else {
            NSApp.terminate(nil)
            return
        }

        let logPath = URL(fileURLWithPath: repoRoot).appendingPathComponent(".g8r/events.jsonl")
        // Runtime state is local, never committed.
        try? GitWorktree.exclude(pattern: "/.g8r/", comment: "G8r runtime state", in: repoRoot)
        do {
            eventLog = try EventLog(path: logPath)
        } catch {
            showError("Couldn't open \(logPath.path)", error)
        }

        paneManager = PaneManager(repoRoot: repoRoot) { [weak self] event in self?.record(event) }
        paneManager.trustWorktrees = autoTrustWorktrees
        windowController = MainWindowController(paneManager: paneManager)
        mapController = MapViewController(planRoot: repoRoot)
        buildLauncher = BuildLauncher(paneManager: paneManager, planRoot: repoRoot) { [weak self] event in
            self?.record(event)
        }
        mapController.onBuild = { [weak self] component in self?.build(component) }
        mapController.onRunTests = { [weak self] in self?.runTests() }
        windowController.addMap(mapController)
        windowController.showWindow(nil)

        startEventBus()

        // A plain shell in the repo. No agent starts on its own: sessions
        // begin from the map's Build button or from New Delegate.
        do {
            try paneManager.spawnShell(banner: true)
        } catch {
            showError("Couldn't start a shell", error)
        }
        windowController.showMap()
        // G8R_DEBUG_DELEGATES=a,b opens those delegates at launch, for
        // exercising the tiled layout (with G8R_SNAPSHOT) without clicks.
        for name in debugList("G8R_DEBUG_DELEGATES") {
            _ = try? paneManager.spawnDelegate(name: name)
        }
        for name in debugList("G8R_DEBUG_COLLAPSED") {
            windowController.setCollapsed(true, paneId: "delegate-\(name)")
        }
        // G8R_DEBUG_TOGGLE=a,b: collapse those at 0.7s and expand them
        // again at 1.4s, to exercise the round trip on laid-out panes.
        let toggle = debugList("G8R_DEBUG_TOGGLE")
        for (delay, collapsed) in [(0.7, true), (1.4, false)] where !toggle.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                for name in toggle { self?.windowController.setCollapsed(collapsed, paneId: "delegate-\(name)") }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        scheduleDebugBuild()
        scheduleDebugSnapshot()
        scheduleMapSnapshot()
    }

    private func debugList(_ variable: String) -> [String] {
        (ProcessInfo.processInfo.environment[variable] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// G8R_DEBUG_BUILD=<id>: build that node once the map is first
    /// measured, as its Build button would, to exercise click-to-build
    /// without clicks.
    private func scheduleDebugBuild() {
        guard let id = ProcessInfo.processInfo.environment["G8R_DEBUG_BUILD"], !id.isEmpty else { return }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard self.mapController.map != nil else { return }
            timer.invalidate()
            self.build(id)
        }
    }

    /// G8R_SNAPSHOT=<file.png>: render the window to a PNG after 2s.
    /// Lets UI changes be checked headlessly (no screen-recording
    /// permission needed, unlike screencapture).
    private func scheduleDebugSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["G8R_SNAPSHOT"] else { return }
        // A fixed size, so snapshots don't depend on the saved window frame.
        windowController.window?.setContentSize(NSSize(width: 1500, height: 950))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let view = self?.windowController.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// G8R_SNAPSHOT_MAP=<file.png>: write a picture of the map view two
    /// seconds after launch (or once the map is first drawn, if later).
    private func scheduleMapSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["G8R_SNAPSHOT_MAP"] else { return }
        windowController.window?.setContentSize(NSSize(width: 1500, height: 950))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.mapController.snapshot(to: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        buildLauncher?.closeAll()
        paneManager?.closeAll()
        eventBus?.stop()
        eventLog?.close()
    }

    // MARK: - Events

    /// Events G8r itself produces (pane lifecycle, human input).
    private func record(_ event: G8rEvent) {
        let stored = (try? eventLog?.append(event)) ?? event
        windowController?.eventFeed.append(stored)
        buildLauncher?.handle(stored)
        // A build starting, ending or needing a person changes the map.
        if stored.kind?.hasPrefix("build_") == true { mapController?.noteEvent(stored) }
    }

    private func startEventBus() {
        let socketPath = ProcessInfo.processInfo.environment["G8R_COLLECTOR"] ?? EventBus.defaultSocketPath()
        // The bus appends hook events to the log itself; the callback only
        // feeds the live view.
        let bus = EventBus(socketPath: socketPath, eventLog: eventLog, onEvent: { [weak self] event in
            DispatchQueue.main.async {
                self?.windowController?.eventFeed.append(event)
                self?.mapController?.noteEvent(event)
                self?.buildLauncher?.handle(event)
            }
        })
        do {
            try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try bus.start()
            eventBus = bus
        } catch {
            windowController.eventFeed.append(G8rEvent(kind: "bus_error", extra: [
                "text": .string("couldn't listen on \(socketPath): \(error)"),
            ]))
        }
    }

    // MARK: - The map's buttons

    /// "Build this": a session of its own for the node, in a worktree
    /// branched from `g8r/integration`.
    private func build(_ component: String) {
        guard let map = mapController.map, let buildLauncher else {
            mapController.setBusy("The map isn't measured yet.")
            return
        }
        do {
            try buildLauncher.build(component, in: map)
            mapController.setBusy(nil)
        } catch {
            mapController.setBusy("Couldn't build \(component): \(error)")
        }
    }

    /// "Run tests": the configured test_command in the code root, where
    /// built components land; the map is measured again after.
    private func runTests() {
        guard !testsRunning else { return }
        let root = paneManager.repoRoot
        guard let command = G8rConfig.load(repoRoot: root).testCommand, !command.isEmpty else {
            mapController.setBusy("No test_command is set in g8r.json.")
            return
        }
        testsRunning = true
        mapController.setBusy("Running \(command)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = TestRunner.run(command: command, codeRoot: MapViewer.codeRoot(planRoot: root), planRoot: root,
                               timeout: 1800)
            DispatchQueue.main.async {
                self?.testsRunning = false
                self?.mapController.setBusy(nil)
                self?.mapController.refresh()
            }
        }
    }

    // MARK: - Worktree trust

    static let autoTrustKey = "G8rAutoTrustWorktrees"

    /// Off by default: G8r only marks its own worktrees trusted in
    /// ~/.claude.json when the user turned this on.
    private var autoTrustWorktrees: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoTrustKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoTrustKey) }
    }

    @objc private func toggleAutoTrust(_ sender: NSMenuItem) {
        autoTrustWorktrees.toggle()
        paneManager?.trustWorktrees = autoTrustWorktrees
        sender.state = autoTrustWorktrees ? .on : .off
    }

    // MARK: - Repo selection

    /// The repo to work on: first CLI argument, else the current
    /// directory, else ask. Must be a git repository (delegates need
    /// worktrees).
    private func resolveRepoRoot() -> String? {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let candidate = args.first ?? FileManager.default.currentDirectoryPath
        if let root = GitWorktree.repoRoot(containing: candidate) { return root }

        let panel = NSOpenPanel()
        panel.message = "Choose the git repository G8r should open"
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
                                message: "Creates ../\((paneManager.repoRoot as NSString).lastPathComponent)-<name> on branch g8r/<name> and starts \(paneManager.agentCommand) there.",
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
        let autoTrust = NSMenuItem(title: "Auto-trust Delegate Worktrees", action: #selector(toggleAutoTrust(_:)), keyEquivalent: "")
        autoTrust.target = self
        autoTrust.state = UserDefaults.standard.bool(forKey: Self.autoTrustKey) ? .on : .off
        autoTrust.toolTip = "When a delegate opens, mark G8r's new worktree trusted in Claude Code (only if you already trust this repo), so it starts without the trust prompt."
        appMenu.addItem(autoTrust)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide G8r", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit G8r", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let paneItem = NSMenuItem()
        let paneMenu = NSMenu(title: "Pane")
        paneMenu.addItem(item("New Delegate…", #selector(newDelegate(_:)), "d", [.command, .shift]))
        paneMenu.addItem(item("New Shell", #selector(newShell(_:)), "t"))
        paneMenu.addItem(item("Close Pane", #selector(closePane(_:)), "w"))
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
