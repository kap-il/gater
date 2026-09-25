import AppKit
import GaterCore
import GaterTerminal

/// Creates panes with the right command, cwd, and GATER_* environment, and
/// logs what humans type into delegate panes.
final class PaneManager {
    let repoRoot: String
    /// Appends to the event log (and the live feed); owned by the app.
    private let record: (GaterEvent) -> Void
    private(set) var panes: [Pane] = []
    private var shellCount = 0
    /// Per-pane text typed since the last Enter, for human_intervention.
    private var lineBuffers: [String: String] = [:]

    var onPaneAdded: ((Pane) -> Void)?
    var onPaneRemoved: ((Pane) -> Void)?
    var onPaneTitleChanged: ((Pane) -> Void)?

    /// Claude Code's cross-session send tool, as it appears in hook
    /// payloads' `tool_name`. Overridable while the name is being verified.
    var delegationTool = ProcessInfo.processInfo.environment["GATER_DELEGATION_TOOL_NAME"] ?? PaneManager.defaultDelegationTool
    static let defaultDelegationTool = "SendMessage"

    /// The command the orchestrator and delegates run. Overridable so the
    /// terminal can be exercised without claude installed.
    var agentCommand = ProcessInfo.processInfo.environment["GATER_AGENT_COMMAND"] ?? "claude"

    init(repoRoot: String, record: @escaping (GaterEvent) -> Void) {
        self.repoRoot = repoRoot
        self.record = record
    }

    var orchestrator: Pane? { panes.first { $0.role == .orchestrator } }

    func pane(id: String) -> Pane? { panes.first { $0.id == id } }

    // MARK: - Spawning

    /// `claude --name <pane id>`: the session's display name matches the
    /// pane id, so the orchestrator can address a delegate predictably
    /// (SendMessage `to`) and it lines up with "pane" in the event log.
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

    /// "New delegate": creates `../<repo>-<name>` on `gater/<name>` and
    /// launches the agent in it.
    @discardableResult
    func spawnDelegate(name: String) throws -> Pane {
        let id = "delegate-\(name)"
        if let existing = pane(id: id) { return existing }
        let worktree = try GitWorktree.ensure(delegate: name, repoRoot: repoRoot)
        return try spawn(id: id, role: .delegate, name: name, worktree: worktree, command: agentCommand(named: id))
    }

    @discardableResult
    func spawnShell(in directory: String? = nil) throws -> Pane {
        shellCount += 1
        return try spawn(id: "shell-\(shellCount)", role: .shell, name: "shell \(shellCount)",
                         worktree: directory ?? repoRoot, command: nil)
    }

    private func spawn(id: String, role: PaneRole, name: String, worktree: String, command: String?) throws -> Pane {
        var env: [String: String] = [
            "GATER_PANE_ID": id,
            "GATER_ROLE": role.rawValue,
            "GATER_WORKTREE": worktree,
            // Where gater-hook finds .gater/plan.json (delegates run in
            // sibling worktrees, not the repo itself).
            "GATER_REPO": repoRoot,
        ]
        if let path = pathWithHookDirectory() { env["PATH"] = path }
        env["GATER_DELEGATION_TOOL_NAME"] = delegationTool
        if role != .shell { installHooks(in: worktree) }
        if role == .shell {
            // Shell panes aren't tracked; don't let their hooks claim a pane.
            env["GATER_PANE_ID"] = nil
            env["GATER_ROLE"] = nil
        }

        let config = LaunchConfig.loginShell(command: command, workingDirectory: worktree,
                                             extraEnvironment: env)
        let session = try TerminalSession(config: config, size: TerminalView.initialPTYSize(for: CGSize(width: 800, height: 600)))
        let pane = Pane(id: id, role: role, name: name, worktree: worktree, session: session)

        session.onTitleChanged = { [weak self, weak pane] _ in
            guard let self, let pane else { return }
            self.onPaneTitleChanged?(pane)
        }
        if role == .delegate {
            pane.view.onHumanInput = { [weak self] input in self?.recordHumanInput(input, pane: id) }
        }

        panes.append(pane)
        log(GaterEvent(kind: "pane_opened", extra: [
            "pane": .string(id), "role": .string(role.rawValue), "worktree": .string(worktree),
        ]))
        onPaneAdded?(pane)
        return pane
    }

    func close(_ pane: Pane) {
        pane.session.terminate()
        panes.removeAll { $0 === pane }
        lineBuffers[pane.id] = nil
        log(GaterEvent(kind: "pane_closed", extra: ["pane": .string(pane.id)]))
        onPaneRemoved?(pane)
    }

    func closeAll() {
        for pane in panes { pane.session.terminate() }
    }

    // MARK: - Injection

    /// Injects into a pane by id; returns false if there's no such pane.
    @discardableResult
    func inject(text: String, into paneId: String, submit: Bool = true) -> Bool {
        guard let pane = pane(id: paneId) else { return false }
        pane.inject(text: text, submit: submit)
        return true
    }

    // MARK: - human_intervention (spec §8 decision 3)

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
            log(GaterEvent(kind: "human_intervention", extra: ["pane": .string(pane), "text": .string(text)]))
        }
    }

    private func log(_ event: GaterEvent) {
        record(event)
    }

    /// Writes Gater's hooks into the pane's worktree so its `claude` reports
    /// to the event bus. Best-effort: a pane without hooks still works as a
    /// terminal, so failures are logged rather than blocking the spawn.
    private func installHooks(in worktree: String) {
        guard let hook = hookBinaryPath() else {
            log(GaterEvent(kind: "hooks_error", extra: ["text": .string("gater-hook binary not found next to Gater")]))
            return
        }
        do {
            try HookInstaller.install(into: worktree, config: .init(hookBinary: hook, delegationTool: delegationTool))
        } catch {
            log(GaterEvent(kind: "hooks_error", extra: ["text": .string("\(worktree): \(error)")]))
        }
    }

    private func hookBinaryPath() -> String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let path = exe.deletingLastPathComponent().appendingPathComponent("gater-hook").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Prepends the directory holding `gater-hook` (built next to the app
    /// binary) so the hook commands in .claude/settings.json resolve.
    private func pathWithHookDirectory() -> String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let dir = exe.deletingLastPathComponent().path
        guard FileManager.default.isExecutableFile(atPath: (dir as NSString).appendingPathComponent("gater-hook")) else {
            return nil
        }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return "\(dir):\(current)"
    }
}
