import Foundation

/// The coding agent a session runs: Claude Code or OpenAI's Codex CLI.
///
/// Everything g8r needs to know about an agent is answered here: how to
/// start an interactive session, how g8r hears that it went idle, what to
/// install in a worktree so it reports to g8r, how to trust a worktree,
/// and how to ask it one question with a structured answer. Nothing else
/// in g8r names an agent's executable or its files.
public enum Agent: String, CaseIterable, Equatable, Sendable {
    /// Claude Code, `claude`. Hooks in `.claude/settings.local.json` report
    /// edits, commands and each stop.
    case claudeCode = "claude"
    /// Codex CLI, `codex`. Its `notify` program reports each finished turn;
    /// g8r sets it per launch with `-c`, so nothing is written to the
    /// worktree or to `~/.codex`.
    case codex

    /// The agent g8r uses when nothing chooses one.
    public static let `default` = Agent.claudeCode

    /// The value `g8r.json`'s `agent` key and `G8R_AGENT` take; nil when it
    /// names no agent g8r knows.
    public init?(name: String) {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "claude", "claude-code", "claudecode": self = .claudeCode
        case "codex": self = .codex
        default: return nil
        }
    }

    /// What people call it.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The program on the user's PATH.
    public var program: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// What a session pane runs: `G8R_AGENT_COMMAND` when it is set, so a
    /// test or a person can run something else, otherwise the program.
    public func command(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let command = environment["G8R_AGENT_COMMAND"], !command.isEmpty { return command }
        return program
    }

    // MARK: - Launch

    /// How g8r learns that a session went idle.
    public enum IdleSignal: Equatable, Sendable {
        /// The agent reports it: a `stop` event from `g8r-hook`.
        case stopEvent
        /// Nothing reports it, so the command exiting is the signal. The
        /// pane's shell exits with it.
        case paneExit
    }

    public struct Launch: Equatable, Sendable {
        /// What the pane's shell runs.
        public var command: String
        public var idle: IdleSignal

        public var idleOnExit: Bool { idle == .paneExit }
    }

    /// The interactive command for a session called `name`, with `prompt`
    /// as its first message (nil starts it empty).
    ///
    /// `command` is what `command(environment:)` gave. When its program is
    /// this agent's (by name, wherever it lives), it gets the agent's flags:
    /// `claude --name <name>`, or `codex -c 'notify=[…]'` so each finished
    /// turn runs `g8r-hook codex-notify`. Anything else is run as it is,
    /// with the prompt as its last argument; nothing reports its going idle
    /// but its exit.
    ///
    /// - Parameter hookBinary: the absolute path of `g8r-hook`. Codex needs
    ///   it to report turns; without it, a Codex session is idle on exit.
    public func launch(command: String, name: String, prompt: String?, hookBinary: String?) -> Launch {
        let program = command.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }
        let quotedPrompt = prompt.map { " " + Self.shellQuote($0) } ?? ""
        switch self {
        case .claudeCode where program == self.program:
            return Launch(command: "\(command) --name \(Self.shellQuote(name))\(quotedPrompt)", idle: .stopEvent)
        case .codex where program == self.program:
            // Codex has no flag that names a session at launch; the pane's
            // G8R_PANE_ID says which session a turn belongs to.
            guard let hookBinary else { break }
            let notify = "notify=" + Self.tomlArray([hookBinary, Self.codexNotifyArgument])
            return Launch(command: "\(command) -c \(Self.shellQuote(notify))\(quotedPrompt)", idle: .stopEvent)
        default:
            break
        }
        guard prompt != nil else { return Launch(command: command, idle: .paneExit) }
        // `exit` ends the shell before the terminal's `exec $SHELL` can
        // replace it, so the session ends when the agent does.
        return Launch(command: "\(command)\(quotedPrompt); exit", idle: .paneExit)
    }

    /// The first argument Codex's `notify` gives `g8r-hook`; Codex appends
    /// the payload after it.
    public static let codexNotifyArgument = "codex-notify"

    // MARK: - Reporting to g8r

    /// Writes into `worktree` what makes the agent report to g8r.
    ///
    /// Claude Code: g8r's hooks in `.claude/settings.local.json`. Codex:
    /// nothing, since its `notify` is set on the command line; a project
    /// `.codex/config.toml` would only be read once the worktree is
    /// trusted, and project hooks each need approving in `/hooks`.
    public func install(into worktree: String, hookBinary: String) throws {
        switch self {
        case .claudeCode: try HookInstaller.install(into: worktree, config: .init(hookBinary: hookBinary))
        case .codex: return
        }
    }

    /// Takes out what `install` wrote, leaving everything else as it was.
    public func uninstall(from worktree: String) throws {
        switch self {
        case .claudeCode: try HookInstaller.uninstall(from: worktree)
        case .codex: return
        }
    }

    // MARK: - Trust

    /// Makes `worktree` start without a trust prompt, provided `repoRoot`
    /// is already trusted. Only called when the user turned auto-trust on.
    ///
    /// Claude Code keeps trust per folder in `~/.claude.json`. Codex
    /// resolves a linked git worktree's trust through its main repository,
    /// so a worktree of a trusted repo is trusted already: nothing is
    /// written, and Codex's sandbox and approvals are left as they are.
    ///
    /// - Parameter home: the folder holding the agent's settings; the
    ///   user's home unless a test says otherwise.
    public func trustWorktree(_ worktree: String, createdFrom repoRoot: String,
                              home: String = NSHomeDirectory()) throws {
        switch self {
        case .claudeCode:
            try ClaudeTrust.trustWorktree(worktree, createdFrom: repoRoot,
                                          config: ClaudeTrust.defaultConfigPath(home: home))
        case .codex: return
        }
    }

    // MARK: - Helpers

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A TOML array of basic strings, which `codex -c` parses.
    static func tomlArray(_ items: [String]) -> String {
        "[" + items.map(tomlString).joined(separator: ", ") + "]"
    }

    static func tomlString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
