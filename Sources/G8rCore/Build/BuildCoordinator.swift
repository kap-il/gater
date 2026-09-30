import Foundation

/// Everything needed to open one build session's pane.
public struct BuildLaunch: Equatable {
    public var component: String
    /// `build-<id>`, what the pane's hook events carry as `pane`.
    public var pane: String
    public var worktree: String
    public var branch: String
    /// The commit the branch started from.
    public var base: String
    public var prompt: String
    /// What the pane's shell runs.
    public var command: String
    /// Set in the pane's environment: `G8R_PANE_ID` and `G8R_COMPONENT`.
    public var environment: [String: String]
    /// Nothing reports the agent going idle (see `Agent.IdleSignal`). Its
    /// command exiting says so instead, and ends the pane's session, so
    /// there is nothing left to type a failure into.
    public var idleOnExit: Bool
    /// The agent the session runs.
    public var agent: Agent

    public static func pane(for component: String) -> String { "build-\(component)" }

    /// Claude Code's launch: `claude --name build-<id> '<prompt>'`. See
    /// `Agent.launch` for every agent's.
    public static func command(agent: String, pane: String, prompt: String) -> (command: String, idleOnExit: Bool) {
        let launch = Agent.claudeCode.launch(command: agent, name: pane, prompt: prompt, hookBinary: nil)
        return (launch.command, launch.idleOnExit)
    }
}

/// Where build sessions run: the app's panes, or a test's stand-in.
public protocol BuildHost: AnyObject {
    /// Opens a pane in `launch.worktree` running `launch.command` with
    /// `launch.environment`, after trusting the worktree for `launch.agent`
    /// when the user asked for it. The command carries the agent's wiring;
    /// nothing is installed in the worktree.
    func open(_ launch: BuildLaunch) throws
    /// Types `text` into the pane and submits it.
    func tell(_ text: String, pane: String)
    func close(pane: String)
}

/// Runs click-to-build: starts a session for a node, and moves it along
/// as its events arrive, from the first idle to the merge into
/// `g8r/integration`. The decisions are `BuildSession`'s; this does them.
///
/// Called on one thread (the app's main thread). Checks and merges run
/// through `background`, and their results come back through `main`.
public final class BuildCoordinator {
    public enum BuildError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case notPlanned(String, status: NodeStatus)
        case blocked(String, by: [String])
        case alreadyBuilding(String)
        case reserved(String)
        case noCommits(String)
        case setupFailed(String, output: String)
        /// Nobody has started an agent in a pane since the app opened.
        case noAgent

        public var description: String {
            switch self {
            case let .unknown(id): return "There is no component \(id) on the map."
            case let .notPlanned(id, status): return "\(id) is \(status.rawValue); only planned components are built."
            case let .blocked(id, needs):
                return "\(id) can't be built yet: it needs \(needs.joined(separator: ", ")), which isn't built."
            case let .alreadyBuilding(id): return "\(id) already has a build session open."
            case let .reserved(id): return "\(id) is the name of g8r's integration worktree; rename the component."
            case let .noCommits(root): return "\(root) has no commits to branch from."
            case let .setupFailed(id, output): return "worktree_setup failed for \(id):\n\(output)"
            case .noAgent: return WiredAgent.missing
            }
        }
    }

    /// Why `id` can't be built from `map`, or nil when it can.
    public static func refusal(for id: String, in map: LivingMap) -> BuildError? {
        guard let node = map.node(id) else { return .unknown(id) }
        guard node.status == .planned else { return .notPlanned(id, status: node.status) }
        if let blocked = node.blockedBy, !blocked.isEmpty { return .blocked(id, by: blocked) }
        if id == "integration" { return .reserved(id) }
        return nil
    }

    private struct Open {
        var session: BuildSession
        let launch: BuildLaunch
        let name: String
    }

    public let planRoot: String
    /// The agent sessions run: the one last started in a pane
    /// (`WiredAgent`). With none, `build` refuses.
    public var agent: Agent?
    /// What runs it; nil for `agent.command()`, the program or
    /// `G8R_AGENT_COMMAND`.
    public var agentCommand: String?
    private let hookBinary: String?
    private let skills: AgentSkills?
    private weak var host: BuildHost?
    private let record: (G8rEvent) -> Void
    private let scanner: SymbolScanning?
    private let runner: (String) -> CommandRunner
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    private var open: [String: Open] = [:]

    /// - Parameters:
    ///   - agent: which agent `agentCommand` runs, which decides its flags
    ///     and how its going idle is heard. Nil until one is wired.
    ///   - agentCommand: what runs it; nil for `Agent.command(environment:)`.
    ///   - hookBinary: `g8r-hook`'s path, for agents told about it on the
    ///     command line (Codex's notify).
    ///   - skills: the skills each session is given (`AgentSkills`).
    ///   - scanner: reads the signatures of what a node needs; nil leaves
    ///     them out of the prompt.
    ///   - runner: a runner in the given directory.
    ///   - background, main: where checks and merges run, and where their
    ///     results are handled. Both run at once by default.
    public init(planRoot: String, agent: Agent? = nil, agentCommand: String? = nil, hookBinary: String? = nil,
                skills: AgentSkills? = nil, host: BuildHost,
                record: @escaping (G8rEvent) -> Void, scanner: SymbolScanning? = nil,
                runner: @escaping (String) -> CommandRunner = { ProcessRunner.runner(in: $0) },
                background: @escaping (@escaping () -> Void) -> Void = { $0() },
                main: @escaping (@escaping () -> Void) -> Void = { $0() }) {
        self.planRoot = planRoot
        self.agent = agent
        self.agentCommand = agentCommand
        self.hookBinary = hookBinary
        self.skills = skills
        self.host = host
        self.record = record
        self.scanner = scanner
        self.runner = runner
        self.background = background
        self.main = main
    }

    /// Where `component`'s open session is; nil when none is open.
    public func state(of component: String) -> BuildSession.State? {
        open[component]?.session.state
    }

    public var openPanes: [String] { open.values.map(\.launch.pane).sorted() }

    // MARK: - Start

    /// Creates the worktree from `g8r/integration` (or the plan root's
    /// `HEAD` before there is one), runs `worktree_setup` there, and opens
    /// the session's pane with the prompt.
    @discardableResult
    public func build(_ component: String, in map: LivingMap) throws -> BuildLaunch {
        if let refusal = Self.refusal(for: component, in: map) { throw refusal }
        guard let agent else { throw BuildError.noAgent }
        guard open[component] == nil else { throw BuildError.alreadyBuilding(component) }
        guard let base = base() else { throw BuildError.noCommits(planRoot) }

        let worktree = try GitWorktree.ensure(delegate: component, repoRoot: planRoot, base: base)
        let config = G8rConfig.load(repoRoot: planRoot)
        if let setup = config.worktreeSetup, !setup.isEmpty {
            let run = runner(worktree)
            let result: (status: Int32, output: String)
            do {
                result = try run("/usr/bin/env", ["G8R_PLAN_ROOT=\(planRoot)", "/bin/sh", "-c", setup], nil)
            } catch {
                throw BuildError.setupFailed(component, output: "\(error)")
            }
            guard result.status == 0 else { throw BuildError.setupFailed(component, output: result.output) }
        }

        let needs = map.node(component)?.needs ?? []
        let interfaces = scanner.map {
            BuildInterfaces.at(commit: base, repoRoot: planRoot, map: map, needs: needs, scanner: $0)
        } ?? [:]
        let prompt = PromptComposer.prompt(for: component, in: map, interfaces: interfaces, base: base)
        let pane = BuildLaunch.pane(for: component)
        let command = agent.launch(command: agentCommand ?? agent.command(), name: pane, prompt: prompt,
                                   hookBinary: hookBinary, skills: skills)
        let launch = BuildLaunch(component: component, pane: pane, worktree: worktree,
                                 branch: GitWorktree.branch(forDelegate: component), base: base,
                                 prompt: prompt, command: command.command,
                                 environment: ["G8R_PANE_ID": pane, "G8R_COMPONENT": component],
                                 idleOnExit: command.idleOnExit, agent: agent)

        try host?.open(launch)
        open[component] = Open(session: BuildSession(component: component), launch: launch,
                               name: map.node(component)?.name ?? component)
        record(G8rEvent(kind: "build_started", extra: [
            "component": .string(component), "pane": .string(pane), "worktree": .string(worktree),
            "branch": .string(launch.branch), "base": .string(base),
        ]))
        return launch
    }

    /// `g8r/integration` once it exists, the plan root's `HEAD` until then.
    func base() -> String? {
        if let result = try? GitWorktree.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(Integrator.branch)"],
                                             in: planRoot),
           result.status == 0 {
            let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return GitWorktree.head(of: planRoot)
    }

    // MARK: - Events

    /// A `stop` from a build pane (Claude Code's Stop hook, Codex's notify,
    /// or the pane's command exiting) means its session went idle. A closed
    /// build pane ends its session, wherever it was.
    public func handle(_ event: G8rEvent) {
        switch event.kind {
        case "stop":
            guard let component = component(of: event) else { return }
            advance(component, .wentIdle)
        case "pane_closed":
            guard let pane = event.pane, let entry = open.first(where: { $0.value.launch.pane == pane }) else { return }
            open[entry.key] = nil
        default:
            return
        }
    }

    private func component(of event: G8rEvent) -> String? {
        guard let pane = event.pane else { return nil }
        if let component = event["component"]?.stringValue, open[component]?.launch.pane == pane {
            return component
        }
        return open.first { $0.value.launch.pane == pane }?.key
    }

    private func advance(_ component: String, _ input: BuildSession.Input) {
        guard var entry = open[component] else { return }
        let before = entry.session.state
        let action = entry.session.handle(input)
        open[component] = entry
        if case let .needsHuman(reason) = entry.session.state, before != entry.session.state {
            needsHuman(component, reason)
        }
        perform(action, entry)
    }

    private func needsHuman(_ component: String, _ reason: String) {
        record(G8rEvent(kind: "build_needs_human", extra: [
            "component": .string(component), "reason": .string(reason),
        ]))
    }

    private func perform(_ action: BuildSession.Action, _ entry: Open) {
        let component = entry.launch.component
        switch action {
        case let .runChecks(round):
            let worktree = entry.launch.worktree
            let planRoot = planRoot
            let run = runner(worktree)
            background { [weak self, main] in
                let config = G8rConfig.load(repoRoot: planRoot)
                let result = BuildChecks.run(worktree: worktree, config: config, run: run)
                main {
                    self?.record(G8rEvent(kind: "build_checked", extra: [
                        "component": .string(component), "passed": .bool(result.passed),
                        "round": .number(Double(round)), "tail": .string(result.tail),
                    ]))
                    self?.advance(component, .checked(passed: result.passed, tail: result.tail))
                }
            }

        case .merge:
            let integrator = Integrator(repoRoot: planRoot)
            let branch = entry.launch.branch
            let message = "Merge \(component): \(entry.name)"
            background { [weak self, main] in
                let input: BuildSession.Input
                do {
                    switch try integrator.merge(branches: [branch], message: message) {
                    case let .merged(commit): input = .merged(commit: commit)
                    case .upToDate: input = .mergeFailed(reason: "\(branch) has nothing to merge")
                    case let .conflict(files): input = .mergeFailed(reason: "conflicts in " + files.joined(separator: ", "))
                    }
                } catch {
                    input = .mergeFailed(reason: "\(error)")
                }
                main { self?.advance(component, input) }
            }

        case let .tell(text):
            if entry.launch.idleOnExit {
                // The agent has exited; there is no one to tell.
                needsHuman(component, "The agent command exited and the checks failed:\n\(text)")
            } else {
                host?.tell(text, pane: entry.launch.pane)
            }

        case .close:
            guard case let .merged(commit) = entry.session.state else { return }
            open[component] = nil
            record(G8rEvent(kind: "build_merged", extra: [
                "component": .string(component), "commit": .string(commit),
            ]))
            host?.close(pane: entry.launch.pane)
            if !GitWorktree.remove(worktree: entry.launch.worktree, repoRoot: planRoot) {
                record(G8rEvent(kind: "build_cleanup_failed", extra: [
                    "component": .string(component), "worktree": .string(entry.launch.worktree),
                ]))
            }

        case .none:
            return
        }
    }
}
