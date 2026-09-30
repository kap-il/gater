import Foundation

/// G8r's Claude Code hooks. They only observe: edits, shell commands, and
/// the session going idle.
///
/// g8r now passes them per session with `--settings` (see
/// `Agent.wiring`); `flagSettings` builds that value. Installing them into
/// a worktree's `.claude/settings.local.json` is how it used to be done,
/// and `uninstall` takes an old install out.
///
/// Each delegate works in its own worktree, and an untracked settings file
/// doesn't follow `git worktree add`, so G8r installs into every pane's
/// directory at spawn. The merge is surgical: only hook entries whose
/// command runs g8r-hook are replaced; the user's own hooks and every
/// other setting are left alone. The file is kept out of git through the
/// repository's `info/exclude`, so it never shows up as a change to commit.
public enum HookInstaller {
    /// Identifies hook entries G8r owns. The second is the binary's name
    /// from before the rename to g8r: entries still carrying it are
    /// replaced too, so an old install doesn't keep calling a missing hook.
    static let markers = ["g8r-hook", "gater-hook"]
    static let settingsPath = ".claude/settings.local.json"

    public struct Config: Equatable {
        /// Absolute path to the g8r-hook binary.
        public var hookBinary: String

        public init(hookBinary: String) {
            self.hookBinary = hookBinary
        }

        var command: String {
            "'" + hookBinary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    /// G8r's hook table, keyed by hook event.
    static func g8rHooks(_ config: Config) -> [String: [JSONValue]] {
        func group(_ matcher: String?) -> JSONValue {
            var fields: [String: JSONValue] = [
                "hooks": .array([.object(["type": .string("command"), "command": .string(config.command)])]),
            ]
            if let matcher { fields["matcher"] = .string(matcher) }
            return .object(fields)
        }
        return [
            "PostToolUse": [group("Edit|Write|MultiEdit"), group("Bash")],
            "Stop": [group(nil)],
        ]
    }

    /// `existing` settings with any previous G8r hooks replaced by the
    /// current ones.
    static func merged(existing: [String: JSONValue], config: Config) -> [String: JSONValue] {
        var settings = existing
        var hooks = withoutG8rHooks(existing["hooks"]?.objectValue ?? [:])
        for (event, groups) in g8rHooks(config) {
            hooks[event] = .array((hooks[event]?.arrayValue ?? []) + groups)
        }
        settings["hooks"] = .object(hooks)
        return settings
    }

    /// `hooks` with every G8r-owned hook command dropped, and the groups
    /// and events left empty dropped with them.
    static func withoutG8rHooks(_ existing: [String: JSONValue]) -> [String: JSONValue] {
        var hooks = existing
        for (event, value) in hooks {
            let groups = (value.arrayValue ?? []).compactMap { group -> JSONValue? in
                guard var fields = group.objectValue else { return group }
                let kept = (fields["hooks"]?.arrayValue ?? []).filter { hook in
                    let command = hook.value(atPath: "command")?.stringValue ?? ""
                    return !markers.contains { command.contains($0) }
                }
                guard !kept.isEmpty else { return nil }
                fields["hooks"] = .array(kept)
                return .object(fields)
            }
            hooks[event] = groups.isEmpty ? nil : .array(groups)
        }
        return hooks
    }

    /// G8r's hooks as settings JSON for Claude Code's `--settings`, which
    /// adds them for one session.
    public static func flagSettings(hookBinary: String) -> String {
        encodeCompact(merged(existing: [:], config: Config(hookBinary: hookBinary)))
    }

    /// A `--settings` value the user gave, with g8r's hooks merged in the
    /// way `install` merges them into a file: their own hooks and settings
    /// are kept. Claude Code reads one `--settings`, so a shim puts this in
    /// place of theirs rather than adding its own.
    ///
    /// - Parameter value: JSON text, or the path of a settings file,
    ///   relative to `directory` unless absolute (as Claude Code reads it).
    /// - Throws: when the value is neither a JSON object nor a readable file
    ///   holding one; the shim then passes the user's value on untouched.
    public static func flagSettings(merging value: String, hookBinary: String, directory: String) throws -> String {
        var text = value
        if (try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)))?.objectValue == nil {
            let url = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: directory, isDirectory: true))
            text = try String(contentsOf: url, encoding: .utf8)
        }
        guard let existing = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?.objectValue else {
            throw HookInstallerError.unreadableSettings(value)
        }
        return encodeCompact(merged(existing: existing, config: Config(hookBinary: hookBinary)))
    }

    private static func encodeCompact(_ settings: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(JSONValue.object(settings))) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Installs (or refreshes) G8r's hooks in `directory`.
    public static func install(into directory: String, config: Config) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(settingsPath)
        var existing: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            // Don't clobber a file we can't understand.
            guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let object = parsed.objectValue else {
                throw HookInstallerError.unreadableSettings(url.path)
            }
            existing = object
        }

        let settings = merged(existing: existing, config: config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(JSONValue.object(settings)).write(to: url, options: .atomic)

        try? excludeFromGit(directory: directory)
    }

    /// Takes G8r's hooks out of `directory`'s settings, leaving the user's
    /// own. A file left with nothing in it is removed.
    public static func uninstall(from directory: String) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(settingsPath)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
              var settings = parsed.objectValue else {
            throw HookInstallerError.unreadableSettings(url.path)
        }
        let hooks = withoutG8rHooks(settings["hooks"]?.objectValue ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        if settings.isEmpty {
            try FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(JSONValue.object(settings)).write(to: url, options: .atomic)
    }

    static func excludeFromGit(directory: String) throws {
        try GitWorktree.exclude(pattern: "/\(settingsPath)", comment: "G8r hooks (per-worktree, local)", in: directory)
    }
}

public enum HookInstallerError: Error, CustomStringConvertible, Equatable {
    case unreadableSettings(String)

    public var description: String {
        switch self {
        case let .unreadableSettings(path):
            return "\(path) isn't a JSON object; not touching it."
        }
    }
}
