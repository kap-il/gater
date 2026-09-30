import AppKit
import G8rCore
import G8rTerminal

/// Creates panes with the right command, cwd, and G8R_* environment, and
/// logs what humans type into delegate panes.
final class PaneManager {
    /// The project root: where New Shell and New Delegate start, and whose
    /// config says which agent to run. The app moves it with the active
    /// shell; panes already open stay where they are.
    var repoRoot: String
    /// Appends to the event log (and the live feed); owned by the app.
    private let record: (G8rEvent) -> Void
    private(set) var panes: [Pane] = []
    private var shellCount = 0
    /// Per-pane text typed since the last Enter, for human_intervention.
    private var lineBuffers: [String: String] = [:]

    var onPaneAdded: ((Pane) -> Void)?
    var onPaneRemoved: ((Pane) -> Void)?
    var onPaneTitleChanged: ((Pane) -> Void)?

    /// Mark worktrees G8r creates as trusted by the agent before a
    /// session starts there (only if the repo itself is trusted). Off
    /// unless the user turned it on.
    var trustWorktrees = false

    /// The agent last started in a pane of this run, through a shim; the
    /// app sets it from `agent_started` events. Builds need one.
    var wiredAgent: Agent?

    /// The agent New Delegate starts: the wired one, else `agent` in
    /// g8r.json or .g8r/config.json, or `G8R_AGENT`.
    var agent: Agent { wiredAgent ?? G8rConfig.load(repoRoot: repoRoot).agent }

    /// The command delegates run. `G8R_AGENT_COMMAND` overrides it, so the
    /// terminal can be exercised without the agent installed.
    var agentCommand: String { agent.command() }

    /// g8r's agent shims, written at launch; nil when they couldn't be.
    private(set) var shims: AgentShims.Installed?

    init(repoRoot: String, record: @escaping (G8rEvent) -> Void) {
        self.repoRoot = repoRoot
        self.record = record
        installShims()
    }

    func pane(id: String) -> Pane? { panes.first { $0.id == id } }

    // MARK: - Spawning

    /// The agent's interactive command for a pane, with no prompt:
    /// `claude --name <pane id>`, so the session's name lines up with
    /// "pane" in the event log, or `codex -c notify=…`. Custom commands
    /// are run as-is.
    private func agentCommand(named id: String) -> String {
        agent.launch(command: agentCommand, name: id, prompt: nil, hookBinary: hookBinaryPath(),
                     skills: shims?.skills).command
    }

    /// "New delegate": creates `../<repo>-<name>` on `g8r/<name>` and
    /// launches the agent in it.
    @discardableResult
    func spawnDelegate(name: String) throws -> Pane {
        let id = "delegate-\(name)"
        if let existing = pane(id: id) { return existing }
        let worktree = try GitWorktree.ensure(delegate: name, repoRoot: repoRoot)
        // Must happen before the agent starts, or it shows the trust prompt.
        if trustWorktrees { try? agent.trustWorktree(worktree, createdFrom: repoRoot) }
        return try spawn(id: id, role: .delegate, name: name, worktree: worktree, command: agentCommand(named: id))
    }

    /// A build session from the map: its worktree is already made and
    /// set up; this trusts it if asked and starts the launch's command
    /// there, which carries the agent's wiring.
    @discardableResult
    func spawnBuild(_ launch: BuildLaunch) throws -> Pane {
        if let existing = pane(id: launch.pane) { return existing }
        if trustWorktrees { try? launch.agent.trustWorktree(launch.worktree, createdFrom: repoRoot) }
        return try spawn(id: launch.pane, role: .build, name: launch.component, worktree: launch.worktree,
                         command: launch.command, environment: launch.environment)
    }

    /// A plain shell. With `banner`, it plays the startup banner first
    /// (unless G8R_NO_BANNER is set), then becomes the interactive shell.
    @discardableResult
    func spawnShell(in directory: String? = nil, banner: Bool = false) throws -> Pane {
        shellCount += 1
        let skip = !(ProcessInfo.processInfo.environment["G8R_NO_BANNER"] ?? "").isEmpty
        return try spawn(id: "shell-\(shellCount)", role: .shell, name: "shell \(shellCount)",
                         worktree: directory ?? repoRoot, command: banner && !skip ? StartupBanner.command : nil)
    }

    private func spawn(id: String, role: PaneRole, name: String, worktree: String, command: String?,
                       environment: [String: String] = [:]) throws -> Pane {
        var env = environment
        let path = pathWithHookDirectory()
        if let shims {
            env.merge(AgentShims.environment(shims, path: path)) { _, shim in shim }
        } else {
            env["PATH"] = path
        }
        // Every pane is tracked, shells too, so an agent someone starts by
        // hand reports as this pane. Only build sessions set G8R_COMPONENT.
        env["G8R_PANE_ID"] = id
        if role != .shell { removeOldHooks(from: worktree) }

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

    /// Writes the `claude` and `codex` shims every pane finds first on
    /// PATH. Best-effort: without them, panes still work as terminals, and
    /// agents started by hand just don't report.
    private func installShims() {
        guard let hook = hookBinaryPath() else {
            log(G8rEvent(kind: "hooks_error", extra: ["text": .string("g8r-hook binary not found next to G8r")]))
            return
        }
        do {
            shims = try AgentShims.install(hookBinary: hook)
        } catch {
            log(G8rEvent(kind: "hooks_error", extra: ["text": .string("couldn't write the agent shims: \(error)")]))
        }
    }

    /// Sessions get their hooks on the command line now; hooks an older
    /// g8r wrote into the worktree would report every event twice.
    private func removeOldHooks(from worktree: String) {
        for agent in Agent.allCases { try? agent.uninstall(from: worktree) }
    }

    func hookBinaryPath() -> String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let path = exe.deletingLastPathComponent().appendingPathComponent("g8r-hook").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The inherited PATH, with the directory holding `g8r-hook` (built
    /// next to the app binary) in front so hook commands that name it
    /// resolve.
    private func pathWithHookDirectory() -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        guard let hook = hookBinaryPath() else { return current }
        return "\((hook as NSString).deletingLastPathComponent):\(current)"
    }
}
