import AppKit
import G8rCore
import G8rTerminal

/// Creates panes with the right command, cwd, and G8R_* environment, and
/// logs what humans type into delegate panes.
final class PaneManager {
    let repoRoot: String
    /// Appends to the event log (and the live feed); owned by the app.
    private let record: (G8rEvent) -> Void
    private(set) var panes: [Pane] = []
    private var shellCount = 0
    /// Per-pane text typed since the last Enter, for human_intervention.
    private var lineBuffers: [String: String] = [:]

    var onPaneAdded: ((Pane) -> Void)?
    var onPaneRemoved: ((Pane) -> Void)?
    var onPaneTitleChanged: ((Pane) -> Void)?

    /// Mark worktrees G8r creates as trusted in Claude Code before a
    /// session starts there (only if the repo itself is trusted). Off
    /// unless the user turned it on.
    var trustWorktrees = false

    /// The command the orchestrator and delegates run. Overridable so the
    /// terminal can be exercised without claude installed.
    var agentCommand = ProcessInfo.processInfo.environment["G8R_AGENT_COMMAND"] ?? "claude"

    init(repoRoot: String, record: @escaping (G8rEvent) -> Void) {
        self.repoRoot = repoRoot
        self.record = record
    }

    var orchestrator: Pane? { panes.first { $0.role == .orchestrator } }

    func pane(id: String) -> Pane? { panes.first { $0.id == id } }

    // MARK: - Spawning

    /// `claude --name <pane id>`: the session's display name matches the
    /// pane id, so it lines up with "pane" in the event log.
    /// Custom agent commands that aren't claude are run as-is.
    private func agentCommand(named id: String) -> String {
        let program = agentCommand.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }
        guard program == "claude" else { return agentCommand }
        return "\(agentCommand) --name \(LaunchConfig.shellQuote(id))"
    }

    @discardableResult
    func spawnOrchestrator() throws -> Pane {
        if let existing = orchestrator { return existing }
        return try spawn(id: "orch", role: .orchestrator, name: "orchestrator",
                         worktree: repoRoot, command: agentCommand(named: "orch"))
    }

    /// "New delegate": creates `../<repo>-<name>` on `g8r/<name>` and
    /// launches the agent in it.
    @discardableResult
    func spawnDelegate(name: String) throws -> Pane {
        let id = "delegate-\(name)"
        if let existing = pane(id: id) { return existing }
        let worktree = try GitWorktree.ensure(delegate: name, repoRoot: repoRoot)
        // Must happen before claude starts, or it shows the trust prompt.
        if trustWorktrees { try? ClaudeTrust.trustWorktree(worktree, createdFrom: repoRoot) }
        return try spawn(id: id, role: .delegate, name: name, worktree: worktree, command: agentCommand(named: id))
    }

    /// A build session from the map: its worktree is already made and
    /// set up; this trusts it if asked, installs the hooks, and starts the
    /// launch's command there.
    @discardableResult
    func spawnBuild(_ launch: BuildLaunch) throws -> Pane {
        if let existing = pane(id: launch.pane) { return existing }
        if trustWorktrees { try? ClaudeTrust.trustWorktree(launch.worktree, createdFrom: repoRoot) }
        return try spawn(id: launch.pane, role: .build, name: launch.component, worktree: launch.worktree,
                         command: launch.command, environment: launch.environment)
    }

    @discardableResult
    func spawnShell(in directory: String? = nil) throws -> Pane {
        shellCount += 1
        return try spawn(id: "shell-\(shellCount)", role: .shell, name: "shell \(shellCount)",
                         worktree: directory ?? repoRoot, command: nil)
    }

    private func spawn(id: String, role: PaneRole, name: String, worktree: String, command: String?,
                       environment: [String: String] = [:]) throws -> Pane {
        var env = environment
        if let path = pathWithHookDirectory() { env["PATH"] = path }
        if role != .shell {
            // Shell panes aren't tracked: without a pane id, g8r-hook
            // stays silent for anything run in them.
            env["G8R_PANE_ID"] = id
            installHooks(in: worktree)
        }

        let config = LaunchConfig.loginShell(command: command, workingDirectory: worktree,
                                             extraEnvironment: env)
        let session = try TerminalSession(config: config, size: TerminalView.initialPTYSize(for: CGSize(width: 800, height: 600)))
        let pane = Pane(id: id, role: role, name: name, worktree: worktree, session: session)

        session.onTitleChanged = { [weak self, weak pane] _ in
            guard let self, let pane else { return }
            self.onPaneTitleChanged?(pane)
        }
        if role == .delegate || role == .build {
            pane.view.onHumanInput = { [weak self] input in self?.recordHumanInput(input, pane: id) }
        }

        panes.append(pane)
        log(G8rEvent(kind: "pane_opened", extra: [
            "pane": .string(id), "role": .string(role.rawValue), "worktree": .string(worktree),
        ]))
        onPaneAdded?(pane)
        return pane
    }

    func close(_ pane: Pane) {
        pane.session.terminate()
        panes.removeAll { $0 === pane }
        lineBuffers[pane.id] = nil
        log(G8rEvent(kind: "pane_closed", extra: ["pane": .string(pane.id)]))
        onPaneRemoved?(pane)
    }

    func closeAll() {
        for pane in panes { pane.session.terminate() }
    }

    // MARK: - human_intervention

    /// Reconstructs the line a human typed into a delegate pane and logs it
    /// on Enter. It's a best-effort line (cursor movement inside the line
    /// isn't tracked) — enough for traceback to show *that* and roughly
    /// *what* a human said.
    private func recordHumanInput(_ input: TerminalView.HumanInput, pane: String) {
        switch input {
        case let .typed(text):
            lineBuffers[pane, default: ""] += text
        case .backspace:
            if !(lineBuffers[pane]?.isEmpty ?? true) { lineBuffers[pane]?.removeLast() }
        case let .pasted(text):
            lineBuffers[pane, default: ""] += text
        case .submitted:
            let text = lineBuffers[pane] ?? ""
            lineBuffers[pane] = ""
            log(G8rEvent(kind: "human_intervention", extra: ["pane": .string(pane), "text": .string(text)]))
        }
    }

    private func log(_ event: G8rEvent) {
        record(event)
    }

    /// Writes G8r's hooks into the pane's worktree so its `claude` reports
    /// to the event bus. Best-effort: a pane without hooks still works as a
    /// terminal, so failures are logged rather than blocking the spawn.
    private func installHooks(in worktree: String) {
        guard let hook = hookBinaryPath() else {
            log(G8rEvent(kind: "hooks_error", extra: ["text": .string("g8r-hook binary not found next to G8r")]))
            return
        }
        do {
            try HookInstaller.install(into: worktree, config: .init(hookBinary: hook))
        } catch {
            log(G8rEvent(kind: "hooks_error", extra: ["text": .string("\(worktree): \(error)")]))
        }
    }

    private func hookBinaryPath() -> String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let path = exe.deletingLastPathComponent().appendingPathComponent("g8r-hook").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Prepends the directory holding `g8r-hook` (built next to the app
    /// binary) so the hook commands in .claude/settings.json resolve.
    private func pathWithHookDirectory() -> String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let dir = exe.deletingLastPathComponent().path
        guard FileManager.default.isExecutableFile(atPath: (dir as NSString).appendingPathComponent("g8r-hook")) else {
            return nil
        }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return "\(dir):\(current)"
    }
}
