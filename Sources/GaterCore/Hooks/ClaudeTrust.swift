import Foundation

/// Claude Code's "trust this folder" state, kept in `~/.claude.json` under
/// `projects["<path>"].hasTrustDialogAccepted`. A folder counts as trusted
/// if it or any parent folder is.
///
/// Gater only ever *writes* trust for worktrees it created itself, from a
/// repository the user already trusted, and only when the user turned the
/// auto-trust setting on (off by default).
public enum ClaudeTrust {
    public static func defaultConfigPath(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
    }

    public static func isTrusted(_ path: String, config: URL = defaultConfigPath()) -> Bool {
        guard let projects = load(config)?.value(atPath: "projects")?.objectValue else { return false }
        var current = standardized(path)
        while true {
            if projects[current]?.value(atPath: "hasTrustDialogAccepted") == .bool(true) { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    public enum TrustError: Error, Equatable {
        case repositoryNotTrusted(String)
        case unreadableConfig(String)
    }

    /// Marks `worktree` trusted, provided `repoRoot` already is. Everything
    /// else in the file is preserved; the write is atomic.
    public static func trustWorktree(_ worktree: String, createdFrom repoRoot: String,
                                     config: URL = defaultConfigPath()) throws {
        guard isTrusted(repoRoot, config: config) else { throw TrustError.repositoryNotTrusted(repoRoot) }
        if isTrusted(worktree, config: config) { return }
        guard var root = load(config)?.objectValue else { throw TrustError.unreadableConfig(config.path) }
        var projects = root["projects"]?.objectValue ?? [:]
        var entry = projects[standardized(worktree)]?.objectValue ?? [:]
        entry["hasTrustDialogAccepted"] = .bool(true)
        projects[standardized(worktree)] = .object(entry)
        root["projects"] = .object(projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(JSONValue.object(root)).write(to: config, options: .atomic)
    }

    private static func load(_ config: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: config) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func standardized(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
