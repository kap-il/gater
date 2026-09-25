import Foundation

/// Installs Gater's Claude Code hooks (spec §4.2) into a worktree's
/// `.claude/settings.local.json`.
///
/// Each delegate works in its own worktree, and an untracked settings file
/// doesn't follow `git worktree add`, so Gater installs into every pane's
/// directory at spawn. The merge is surgical: only hook entries whose
/// command runs gater-hook are replaced; the user's own hooks and every
/// other setting are left alone. The file is kept out of git through the
/// repository's `info/exclude`, so it never shows up as a change to commit.
public enum HookInstaller {
    /// Identifies hook entries Gater owns.
    static let marker = "gater-hook"
    static let settingsPath = ".claude/settings.local.json"

    public struct Config: Equatable {
        /// Absolute path to the gater-hook binary.
        public var hookBinary: String
        /// Tool name of Claude Code's cross-session send tool.
        public var delegationTool: String

        public init(hookBinary: String, delegationTool: String) {
            self.hookBinary = hookBinary
            self.delegationTool = delegationTool
        }

        var command: String {
            "'" + hookBinary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    /// Gater's hook table, keyed by hook event.
    static func gaterHooks(_ config: Config) -> [String: [JSONValue]] {
        func group(_ matcher: String?) -> JSONValue {
            var fields: [String: JSONValue] = [
                "hooks": .array([.object(["type": .string("command"), "command": .string(config.command)])]),
            ]
            if let matcher { fields["matcher"] = .string(matcher) }
            return .object(fields)
        }
        return [
            "PreToolUse": [group(config.delegationTool)],
            "PostToolUse": [group(config.delegationTool), group("Edit|Write|MultiEdit"), group("Bash")],
            "Stop": [group(nil)],
        ]
    }

    /// `existing` settings with any previous Gater hooks replaced by the
    /// current ones.
    static func merged(existing: [String: JSONValue], config: Config) -> [String: JSONValue] {
        var settings = existing
        var hooks = existing["hooks"]?.objectValue ?? [:]

        // Drop Gater-owned hook commands everywhere; drop groups left empty.
        for (event, value) in hooks {
            let groups = (value.arrayValue ?? []).compactMap { group -> JSONValue? in
                guard var fields = group.objectValue else { return group }
                let kept = (fields["hooks"]?.arrayValue ?? []).filter {
                    !($0.value(atPath: "command")?.stringValue?.contains(marker) ?? false)
                }
                guard !kept.isEmpty else { return nil }
                fields["hooks"] = .array(kept)
                return .object(fields)
            }
            hooks[event] = groups.isEmpty ? nil : .array(groups)
        }

        for (event, groups) in gaterHooks(config) {
            hooks[event] = .array((hooks[event]?.arrayValue ?? []) + groups)
        }
        settings["hooks"] = .object(hooks)
        return settings
    }

    /// Installs (or refreshes) Gater's hooks in `directory`.
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

    static func excludeFromGit(directory: String) throws {
        try GitWorktree.exclude(pattern: "/\(settingsPath)", comment: "Gater hooks (per-worktree, local)", in: directory)
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
