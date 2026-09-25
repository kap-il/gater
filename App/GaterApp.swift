import AppKit
import GaterCore
import GaterSymbols

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
    private var symbolEngine: SymbolEngine?
    /// Parsing is off the main thread and serialized (the engine keeps
    /// snapshot state).
    private let symbolQueue = DispatchQueue(label: "gater.symbols")
    /// Jev ownership (spec §4.7); nil without JEV_API_KEY in ~/.gater/.env.
    private var classifier: OwnershipClassifier?
    /// Latest decision per symbol id, rebuilt from the log's ownership
    /// events at launch. Only touched on symbolQueue.
    private var ownership: [String: (feature: String, status: String)] = [:]
    /// One TypeScript 7 server per agent worktree (spec §4.8). symbolQueue only.
    private let references = ReferenceEngine()
    /// Agent pane id → worktree, mirrored from PaneManager. symbolQueue only.
    private var agentWorktrees: [String: String] = [:]
    /// Canonical worktree → the commit it started from (symbol baseline)
    /// and the HEAD last scanned after a shell command. symbolQueue only.
    private var worktreeBase: [String: String] = [:]
    private var worktreeScanned: [String: String] = [:]
    /// Public-surface changes still in play: symbol id → the pane that
    /// changed it and how. symbolQueue only.
    private var surfaceChanges: [String: (pane: String?, change: String)] = [:]
    /// Overlap detection (spec §4.9). symbolQueue only.
    private var overlaps = OverlapDetector()
    private var reviewer: ConflictReviewer?
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
        symbolEngine = SymbolEngine(snapshotDirectory: SymbolEngine.defaultSnapshotDirectory(repoRoot: repoRoot))
        if let config = JevClient.Config.from(environment: DotEnv.load()) {
            classifier = OwnershipClassifier(client: JevClient(config: config))
            reviewer = ConflictReviewer(client: JevClient(config: config))
        }
        // Rebuild occupancy and remember what was already reported.
        let history = (try? EventLog.replay(path: logPath)) ?? []
        overlaps.replay(history, plan: store.current)
        for event in history where event.kind == "symbols_changed" {
            for change in event.fields["changes"]?.arrayValue ?? [] {
                guard let id = change.value(atPath: "id")?.stringValue,
                      let kind = change.value(atPath: "change")?.stringValue,
                      ["signature", "removed"].contains(kind),
                      change.value(atPath: "exported") == .bool(true) else { continue }
                surfaceChanges[id] = (event.pane, kind)
            }
        }
        for event in (try? EventLog.replay(path: logPath)) ?? [] where event.kind == "ownership" {
            if let id = event["symbol"]?.stringValue, let feature = event["feature"]?.stringValue {
                ownership[id] = (feature, event["status"]?.stringValue ?? "assigned")
            }
        }

        paneManager = PaneManager(repoRoot: repoRoot) { [weak self] event in self?.record(event) }
        windowController = MainWindowController(paneManager: paneManager)
        trackAgentWorktrees()
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
        symbolQueue.sync { references.stopAll() }
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
        symbolQueue.async { [weak self] in self?.detectOverlaps(stored) }
    }

    /// Mirrors agent panes into symbolQueue state, wrapping the window
    /// controller's pane callbacks, and stops a pane's language server when
    /// the pane closes.
    private func trackAgentWorktrees() {
        let added = paneManager.onPaneAdded
        let removed = paneManager.onPaneRemoved
        paneManager.onPaneAdded = { [weak self] pane in
            added?(pane)
            guard pane.role != .shell else { return }
            self?.symbolQueue.async {
                guard let self else { return }
                self.agentWorktrees[pane.id] = pane.worktree
                let key = SymbolEngine.canonical(pane.worktree)
                if self.worktreeBase[key] == nil, let head = GitWorktree.head(of: pane.worktree) {
                    self.worktreeBase[key] = head
                    self.worktreeScanned[key] = head
                }
            }
        }
        paneManager.onPaneRemoved = { [weak self] pane in
            removed?(pane)
            self?.symbolQueue.async {
                guard let self, let worktree = self.agentWorktrees.removeValue(forKey: pane.id) else { return }
                if !self.agentWorktrees.values.contains(worktree) { self.references.stop(worktree: worktree) }
            }
        }
    }

    /// Edit → re-parse the file → `symbols_changed` (spec §4.6) → ownership
    /// (§4.7) → for public-surface changes, references in every other
    /// agent's worktree (§4.8).
    private func analyzeSymbols(for event: GaterEvent) {
        if event.kind == "delegation" { warmLanguageServer(for: event) }
        if event.kind == "command", let pane = event.pane {
            symbolQueue.async { [weak self] in self?.scanAfterCommand(pane: pane) }
            return
        }
        guard event.kind == "edit", let path = event["path"]?.stringValue, path.hasPrefix("/") else { return }
        symbolQueue.async { [weak self] in self?.fileChanged(absolutePath: path, pane: event.pane) }
    }

    /// Shell commands edit files too (`cat > f`, sed, codegen) and no
    /// Edit/Write hook reports them — seen live, where both delegates wrote
    /// their code with heredocs and committed in the same command. After
    /// each agent command, ask git what changed in its worktree since the
    /// last scan (commits in between + uncommitted/untracked files).
    /// Runs on symbolQueue.
    private func scanAfterCommand(pane: String) {
        guard let worktree = agentWorktrees[pane] else { return }
        let key = SymbolEngine.canonical(worktree)
        guard let since = worktreeScanned[key] ?? worktreeBase[key] else { return }
        let files = GitWorktree.changedFiles(in: worktree, since: since)
        if let head = GitWorktree.head(of: worktree) { worktreeScanned[key] = head }
        for file in files where SymbolExtractor.supports(path: file) {
            fileChanged(absolutePath: (worktree as NSString).appendingPathComponent(file), pane: pane)
        }
    }

    /// One changed file → symbols → ownership / references / new uses.
    /// Runs on symbolQueue.
    private func fileChanged(absolutePath path: String, pane: String?) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let root = GitWorktree.repoRoot(containing: (path as NSString).deletingLastPathComponent).map(SymbolEngine.canonical)
        let baseline = root.flatMap { worktreeBase[$0] } ?? "HEAD"
        guard let update = symbolEngine?.fileEdited(absolutePath: path, baseline: baseline) else { return }
        references.filesChanged(in: update.worktree, relativePaths: [update.path])
        if let changed = update.event(pane: pane) {
            DispatchQueue.main.async { [weak self] in self?.record(changed) }
        }
        classifyOwnership(update, absolutePath: path)
        findReferences(for: update, from: pane)
        checkNewUses(in: update, absolutePath: path, by: pane)
    }

    // MARK: - Overlaps (spec §4.9)

    /// Runs on symbolQueue: feed the detector, and for each new overlap
    /// review it with Jev, log it, and wake the orchestrator when the
    /// changes conflict or Jev isn't sure.
    private func detectOverlaps(_ event: GaterEvent) {
        guard ["ownership", "symbols_changed", "references"].contains(event.kind ?? ""),
              let plan = planStore?.current else { return }
        for overlap in overlaps.apply(event, plan: plan) {
            let input = reviewInput(for: overlap, plan: plan)
            var verdict: ReviewVerdict?
            var reviewError: String?
            if let reviewer {
                do { verdict = try reviewer.reviewBlocking(input) } catch { reviewError = "\(error)" }
            }
            // No verdict (no Jev key, or Jev failed) → wake: a human-grade
            // decision beats a silent miss.
            let wake = verdict?.shouldWake() ?? true
            let text = WakeMessage.render(input, verdict: verdict)

            var events = [overlap.event]
            if let verdict { events.append(verdict.event(overlap: overlap)) }
            if let reviewError { events.append(GaterEvent(kind: "review_error", extra: ["text": .string(reviewError)])) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                events.forEach { self.record($0) }
                guard wake, let orchestrator = self.paneManager.orchestrator else { return }
                orchestrator.inject(text: text)
                self.record(GaterEvent(kind: "wake", extra: [
                    "pane": .string(orchestrator.id), "overlap": .string(overlap.key), "text": .string(text),
                ]))
            }
        }
    }

    /// Gathers what the review and the wake message need from the plan and
    /// the involved worktrees. Runs on symbolQueue.
    private func reviewInput(for overlap: Overlap, plan: Plan) -> ReviewInput {
        let parties = overlap.panes.map { pane -> OverlapParty in
            let dish = plan.currentDish(forPane: pane)
            return OverlapParty(pane: pane, dish: dish?.id, directive: dish?.directive)
        }
        var input = ReviewInput(overlap: overlap, parties: parties)

        func read(_ pane: String?, _ path: String) -> String? {
            guard let pane, let worktree = agentWorktrees[pane] else { return nil }
            return try? String(contentsOfFile: (worktree as NSString).appendingPathComponent(path), encoding: .utf8)
        }

        switch overlap.kind {
        case .publicSurface:
            guard let symbol = overlap.symbol, let hash = symbol.lastIndex(of: "#") else { break }
            let path = String(symbol[..<hash])
            if let source = read(overlap.fromPane, path),
               let after = SymbolExtractor.describe(symbolId: symbol, source: source, path: path) {
                input.newSignature = after.signature
                input.newCode = after.code
            }
            if let source = read(overlap.inPane, path),
               let before = SymbolExtractor.describe(symbolId: symbol, source: source, path: path) {
                input.oldSignature = before.signature
            }
            // Parser facts: does each use still fit the new arity?
            let name = String(symbol[symbol.index(after: hash)...]).split(separator: ".").last.map(String.init) ?? ""
            let newArity = read(overlap.fromPane, path)
                .flatMap { CallCompatibility.arity(symbolId: symbol, source: $0, path: path) }
            if let newArity {
                for site in overlap.sites {
                    let parts = site.split(separator: ":")
                    guard parts.count >= 2, let line = Int(parts.last!) else { continue }
                    let file = parts.dropLast().joined(separator: ":")
                    guard let source = read(overlap.inPane, file) else { continue }
                    for count in CallCompatibility.argumentCounts(calling: name, source: source, path: file, line: line) {
                        let plural = count == 1 ? "argument" : "arguments"
                        let fits = newArity.accepts(count)
                        input.callChecks.append("\(site): passes \(count) \(plural); the new signature \(newArity.description)\(fits ? " — OK" : "")")
                        if !fits { input.breaksCalls = true }
                    }
                }
            }
            input.siteLines = overlap.sites.map { site in
                let parts = site.split(separator: ":")
                guard parts.count >= 2, let line = Int(parts.last!),
                      let text = read(overlap.inPane, parts.dropLast().joined(separator: ":")) else { return site }
                let lines = text.components(separatedBy: "\n")
                return line - 1 < lines.count ? "\(site): \(lines[line - 1].trimmingCharacters(in: .whitespaces))" : site
            }
        case .sharedFeature:
            for pane in overlap.panes {
                input.changesByPane[pane] = overlaps.symbols(changedBy: pane, in: overlap.feature).compactMap { id in
                    guard let hash = id.lastIndex(of: "#") else { return nil }
                    let path = String(id[..<hash])
                    return read(pane, path).flatMap { SymbolExtractor.describe(symbolId: id, source: $0, path: path)?.code }
                }
            }
        }
        return input
    }

    /// Spec §4.8: a worktree's server starts when a delegation begins there,
    /// so the first overlap query doesn't pay the startup cost.
    private func warmLanguageServer(for event: GaterEvent) {
        guard event.fields["gater"]?.value(atPath: "type")?.stringValue == "delegate",
              let pane = event["to_pane"]?.stringValue ?? event["to"]?.stringValue else { return }
        symbolQueue.async { [weak self] in
            guard let self, let worktree = self.agentWorktrees[pane] else { return }
            _ = try? self.references.server(for: worktree)
        }
    }

    /// The other direction: B edits code *after* A changed a symbol's
    /// public surface. If B's file mentions a changed symbol, query B's
    /// worktree for uses so the overlap isn't missed because of ordering.
    /// Runs on symbolQueue.
    private func checkNewUses(in update: SymbolUpdate, absolutePath: String, by pane: String?) {
        guard let pane, let worktree = agentWorktrees[pane],
              let text = try? String(contentsOfFile: absolutePath, encoding: .utf8) else { return }
        for (symbol, origin) in surfaceChanges.sorted(by: { $0.key < $1.key }) where origin.pane != pane {
            // Cheap textual prefilter before asking the language server.
            let name = symbol.split(separator: "#").last?.split(separator: ".").last.map(String.init) ?? ""
            guard !name.isEmpty, text.contains(name) else { continue }
            guard let sites = try? references.references(to: symbol, in: worktree), !sites.isEmpty else { continue }
            let event = GaterEvent(kind: "references", extra: [
                "symbol": .string(symbol),
                "change": .string(origin.change),
                "from_pane": origin.pane.map { .string($0) } ?? .null,
                "in_pane": .string(pane),
                "in_worktree": .string(worktree),
                "sites": .array(sites.map { .string($0.description) }),
                "trigger": .string("new_use"),
            ])
            DispatchQueue.main.async { [weak self] in self?.record(event) }
        }
    }

    /// For each public-surface change, asks every *other* agent worktree's
    /// server who uses the symbol there. Runs on symbolQueue.
    private func findReferences(for update: SymbolUpdate, from pane: String?) {
        let surface = update.changes.filter(\.isPublicSurface)
        guard !surface.isEmpty else { return }
        for change in surface where change.change != .added {
            surfaceChanges[change.id] = (pane, change.change.rawValue)
        }
        let editor = SymbolEngine.canonical(update.worktree)
        for change in surface where change.change != .added { // nobody uses a brand-new symbol yet
            for (otherPane, worktree) in agentWorktrees.sorted(by: { $0.key < $1.key })
            where SymbolEngine.canonical(worktree) != editor {
                do {
                    guard let sites = try references.references(to: change.id, in: worktree), !sites.isEmpty else { continue }
                    let event = GaterEvent(kind: "references", extra: [
                        "symbol": .string(change.id),
                        "change": .string(change.change.rawValue),
                        "from_pane": pane.map { .string($0) } ?? .null,
                        "in_pane": .string(otherPane),
                        "in_worktree": .string(worktree),
                        "sites": .array(sites.map { .string($0.description) }),
                    ])
                    DispatchQueue.main.async { [weak self] in self?.record(event) }
                } catch {
                    let event = GaterEvent(kind: "references_error", extra: ["text": .string("\(otherPane): \(error)")])
                    DispatchQueue.main.async { [weak self] in self?.record(event) }
                }
            }
        }
    }

    /// Sends the symbols whose ownership may have changed to Jev: new ones,
    /// signature changes, anything never classified, and uncertain ones
    /// whose body changed (more code, maybe a clearer answer). Runs on
    /// symbolQueue.
    private func classifyOwnership(_ update: SymbolUpdate, absolutePath: String) {
        guard let classifier, let plan = planStore?.current else { return }
        let changed = Dictionary(update.changes.map { ($0.id, $0.change) }, uniquingKeysWith: { a, _ in a })
        let lines = ((try? String(contentsOfFile: absolutePath, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")

        let candidates = update.symbols.filter { symbol in
            guard let current = ownership[symbol.id] else { return true }
            switch changed[symbol.id] {
            case .added?, .signature?: return true
            case .body?: return current.status == OwnershipDecision.Status.uncertain.rawValue
            default: return false
            }
        }.map { symbol in
            OwnershipCandidate(id: symbol.id, path: update.path, name: symbol.qualifiedName, kind: symbol.kind.rawValue,
                               code: lines[max(symbol.startLine - 1, 0)..<min(symbol.endLine, lines.count)].joined(separator: "\n"))
        }
        guard !candidates.isEmpty else { return }

        do {
            let result = try classifier.classifyBlocking(candidates, plan: plan)
            for decision in result.decisions {
                ownership[decision.symbolId] = (decision.feature, decision.status.rawValue)
            }
            let events = result.decisions.map { $0.event(model: result.model) }
            DispatchQueue.main.async { [weak self] in events.forEach { self?.record($0) } }
        } catch {
            let event = GaterEvent(kind: "ownership_error", extra: ["text": .string("\(error)")])
            DispatchQueue.main.async { [weak self] in self?.record(event) }
        }
    }

    private func startEventBus() {
        let socketPath = ProcessInfo.processInfo.environment["GATER_COLLECTOR"] ?? EventBus.defaultSocketPath()
        // The bus appends hook events to the log itself; the callback only
        // feeds the live view.
        let bus = EventBus(socketPath: socketPath, eventLog: eventLog) { [weak self] event in
            self?.planStore?.apply(event)
            self?.analyzeSymbols(for: event)
            self?.symbolQueue.async { self?.detectOverlaps(event) }
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
