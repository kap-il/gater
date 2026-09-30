import Foundation

/// Wrapper scripts named after each agent's program, put first on PATH in
/// every pane g8r opens, so an agent a person starts by hand (`claude`,
/// `codex`, with any arguments) reports to g8r like a build session does.
///
/// Each shim finds the real program (the next one on PATH that isn't a
/// shim) and runs it with `Agent.wiring` before the person's own
/// arguments, after telling g8r it started (`g8r-hook agent-started`).
/// Outside a g8r pane (no `G8R_PANE_ID`) it runs the real program
/// untouched. There is one shim per `Agent` case.
///
/// A login shell's startup files can put other directories ahead of the
/// shims (macOS's `path_helper` does, and so does a `.zshrc` that prepends
/// `~/.local/bin`). For zsh, the pane's `ZDOTDIR` points at a `.zshenv`
/// that reads the user's own and puts the shims first again at the first
/// prompt. Other shells get the shims first in the inherited PATH only.
public enum AgentShims {
    public struct Installed: Equatable, Sendable {
        /// The directory holding the shims, which goes first on PATH.
        public var bin: String
        /// The `ZDOTDIR` a zsh pane starts with.
        public var zdotdir: String
        /// The skills each agent is given, beside the shims.
        public var skills: AgentSkills
    }

    /// Where every g8r's shims live, one directory per `g8r-hook`, so a
    /// development build and the packaged app don't overwrite each other's.
    public static func root(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".g8r/shims")
    }

    public static func directory(hookBinary: String, home: String = NSHomeDirectory()) -> String {
        (root(home: home) as NSString).appendingPathComponent(String(TextHash.sha256(hookBinary).prefix(12)))
    }

    /// Writes the shims and the zsh startup file for `hookBinary`.
    @discardableResult
    public static func install(hookBinary: String, home: String = NSHomeDirectory()) throws -> Installed {
        let dir = directory(hookBinary: hookBinary, home: home) as NSString
        let skills = try AgentSkills.install(into: dir as String)
        let installed = Installed(bin: dir.appendingPathComponent("bin"), zdotdir: dir.appendingPathComponent("zsh"),
                                  skills: skills)
        let files = FileManager.default
        try files.createDirectory(atPath: installed.bin, withIntermediateDirectories: true)
        try files.createDirectory(atPath: installed.zdotdir, withIntermediateDirectories: true)
        for agent in Agent.allCases {
            let path = (installed.bin as NSString).appendingPathComponent(agent.program)
            try write(script(for: agent, bin: installed.bin, hookBinary: hookBinary, skills: skills, home: home),
                      to: path, mode: 0o755)
        }
        try write(zshenv, to: (installed.zdotdir as NSString).appendingPathComponent(".zshenv"), mode: 0o644)
        return installed
    }

    /// What a pane's environment needs so its shell finds the shims first:
    /// `PATH` with `bin` in front of `path`, and for zsh the `ZDOTDIR` that
    /// keeps them in front after the startup files.
    ///
    /// - Parameter base: the environment the pane inherits, for the user's
    ///   own `ZDOTDIR`, which the startup file puts back.
    public static func environment(_ installed: Installed, path: String,
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = ["PATH": installed.bin + ":" + path, "G8R_SHIMS": installed.bin, "ZDOTDIR": installed.zdotdir]
        if let own = base["ZDOTDIR"], own != installed.zdotdir { env["G8R_USER_ZDOTDIR"] = own }
        return env
    }

    // MARK: - Scripts

    /// The shim for `agent`: plain `/bin/sh`.
    public static func script(for agent: Agent, bin: String, hookBinary: String, skills: AgentSkills? = nil,
                              home: String = NSHomeDirectory()) -> String {
        let program = agent.program
        let q = Agent.shellQuote
        return #"""
        #!/bin/sh
        # g8r's shim for `\#(program)` (\#(agent.displayName)), written by g8r at launch.
        # In a g8r pane (G8R_PANE_ID set) it starts the real \#(program) wired to
        # report to g8r, before your own arguments. Anywhere else it starts the
        # real one untouched.
        g8r_shims=\#(q(bin))
        g8r_root=\#(q(root(home: home)))
        g8r_hook=\#(q(hookBinary))

        # The real \#(program): the first on PATH that isn't one of g8r's shims,
        # however often and by whatever path their directory is on PATH.
        g8r_real=
        g8r_ifs=$IFS
        IFS=:
        set -f
        for g8r_dir in $PATH; do
          case $g8r_dir in ?*/) g8r_dir=${g8r_dir%/} ;; esac
          [ -n "$g8r_dir" ] || g8r_dir=.
          case $g8r_dir/ in "$g8r_root"/*) continue ;; esac
          [ -f "$g8r_dir/\#(program)" ] && [ -x "$g8r_dir/\#(program)" ] || continue
          [ "$g8r_dir/\#(program)" -ef "$g8r_shims/\#(program)" ] && continue
          g8r_real=$g8r_dir/\#(program)
          break
        done
        set +f
        IFS=$g8r_ifs
        if [ -z "$g8r_real" ]; then
          echo "g8r: \#(program) isn't on your PATH (only g8r's shim is). Install \#(agent.displayName), or add its directory to PATH." >&2
          exit 127
        fi

        [ -n "$G8R_PANE_ID" ] || exec "$g8r_real" "$@"

        # Tell g8r, without waiting. A build session has build_started instead.
        if [ -z "$G8R_COMPONENT" ]; then
          "$g8r_hook" \#(Agent.startedArgument) \#(agent.rawValue) </dev/null >/dev/null 2>&1 &
        fi

        \#(wiring(for: agent, hookBinary: hookBinary, skills: skills))
        """# + "\n"
    }

    /// The end of a shim: running the real program with the wiring.
    private static func wiring(for agent: Agent, hookBinary: String, skills: AgentSkills?) -> String {
        let wiring = agent.wiring(hookBinary: hookBinary, skills: skills)
        let args = wiring.map(Agent.shellWord).joined(separator: " ")
        switch agent {
        case .claudeCode:
            // Claude Code reads one --settings. When the person gave their
            // own, g8r's hooks are merged into it (by g8r-hook, which reads
            // a file or JSON as Claude Code does) instead of added beside it.
            // What follows --settings in the wiring (the plugin) is added
            // unless it is there already, as in a build session's command.
            let settings = Array(wiring.prefix(2)).map(Agent.shellWord).joined(separator: " ")
            let rest = wiring.dropFirst(2).map(Agent.shellWord).joined(separator: " ")
            let plugin = skills.map { Agent.shellQuote($0.claudePlugin) } ?? "''"
            return #"""
            g8r_plugin=\#(plugin)
            g8r_merge() { "$g8r_hook" claude-settings "$1" 2>/dev/null || printf '%s\n' "$1"; }
            g8r_n=$#
            g8r_merged=
            g8r_plugged=
            g8r_rest=
            while [ "$g8r_n" -gt 0 ]; do
              g8r_arg=$1
              shift
              g8r_n=$((g8r_n - 1))
              if [ -z "$g8r_rest" ]; then
                case $g8r_arg in
                  --) g8r_rest=1 ;;
                  --settings)
                    if [ "$g8r_n" -gt 0 ]; then
                      set -- "$@" "$g8r_arg"
                      g8r_arg=$(g8r_merge "$1")
                      shift
                      g8r_n=$((g8r_n - 1))
                      g8r_merged=1
                    fi ;;
                  --settings=*)
                    g8r_arg=--settings=$(g8r_merge "${g8r_arg#--settings=}")
                    g8r_merged=1 ;;
                  --plugin-dir)
                    [ "$g8r_n" -gt 0 ] && [ -n "$g8r_plugin" ] && [ "$1" = "$g8r_plugin" ] && g8r_plugged=1 ;;
                  --plugin-dir=*)
                    [ -n "$g8r_plugin" ] && [ "${g8r_arg#--plugin-dir=}" = "$g8r_plugin" ] && g8r_plugged=1 ;;
                esac
              fi
              set -- "$@" "$g8r_arg"
            done
            [ -n "$g8r_plugged" ] || [ -z "$g8r_plugin" ] || set -- \#(rest) "$@"
            [ -n "$g8r_merged" ] || set -- \#(settings) "$@"
            exec "$g8r_real" "$@"
            """#
        case .codex:
            return #"exec "$g8r_real" \#(args) "$@""#
        }
    }

    /// The `.zshenv` a zsh pane starts with. It puts the user's `ZDOTDIR`
    /// back at once, so their `.zprofile`, `.zshrc` and `.zlogin` (and
    /// their history file) are read from where they always are, reads their
    /// `.zshenv`, and in an interactive shell puts the shims first again
    /// just before the first prompt, after every startup file has run.
    public static let zshenv = #"""
    # Written by g8r. A g8r pane's zsh starts here: it reads your own startup
    # files as usual, then puts g8r's agent shims first on PATH.
    if [ -n "${G8R_USER_ZDOTDIR+x}" ]; then
      ZDOTDIR=$G8R_USER_ZDOTDIR
      unset G8R_USER_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    [ -f "${ZDOTDIR:-$HOME}/.zshenv" ] && . "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive && -n $G8R_SHIMS ]]; then
      _g8r_shims_first() {
        path=("$G8R_SHIMS" ${path:#${(b)G8R_SHIMS}})
        precmd_functions=(${precmd_functions:#_g8r_shims_first})
        unfunction _g8r_shims_first
      }
      precmd_functions+=(_g8r_shims_first)
    fi
    """# + "\n"

    private static func write(_ text: String, to path: String, mode: Int) throws {
        if (try? String(contentsOfFile: path, encoding: .utf8)) != text {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}
