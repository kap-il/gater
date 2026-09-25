import Foundation
import GaterCore

/// Result of re-parsing one edited file.
public struct SymbolUpdate: Equatable {
    /// Path relative to the file's worktree root.
    public var path: String
    public var worktree: String
    public var symbols: [CodeSymbol]
    public var changes: [SymbolChange]
}

/// Per-worktree symbol snapshots (spec §4.6): on each edit, re-parse the
/// file and diff against the last snapshot of it in that worktree. A file's
/// first edit is diffed against its version at HEAD, so the change that
/// triggered the edit isn't lost. Snapshots persist under
/// `.gater/snapshots/`, one JSON file per worktree.
public final class SymbolEngine {
    private let snapshotDirectory: URL
    /// worktree root → (relative path → symbols)
    private var snapshots: [String: [String: [CodeSymbol]]] = [:]

    public init(snapshotDirectory: URL) {
        self.snapshotDirectory = snapshotDirectory
    }

    public static func defaultSnapshotDirectory(repoRoot: String) -> URL {
        URL(fileURLWithPath: repoRoot).appendingPathComponent(".gater/snapshots")
    }

    /// Handles an edit to `absolutePath`. Returns nil for files the engine
    /// doesn't understand or can't read; otherwise the (possibly empty)
    /// set of changes.
    ///
    /// `baseline` is the git ref a file's first edit is diffed against —
    /// normally the commit the worktree started from, because by the time
    /// Gater looks, an agent may already have committed the change (a Bash
    /// `cat > f && git commit` does both at once), making HEAD useless.
    public func fileEdited(absolutePath: String, baseline: String = "HEAD") -> SymbolUpdate? {
        guard SymbolExtractor.supports(path: absolutePath),
              let source = try? String(contentsOfFile: absolutePath, encoding: .utf8),
              let worktree = GitWorktree.repoRoot(containing: (absolutePath as NSString).deletingLastPathComponent)
        else { return nil }

        let relative = Self.relativePath(absolutePath, to: worktree)
        guard let symbols = try? SymbolExtractor.symbols(source: source, path: relative) else { return nil }

        var files = loadSnapshot(worktree: worktree)
        let previous = files[relative] ?? symbolsAt(ref: baseline, relative: relative, worktree: worktree)
        let changes = SymbolDiff.diff(old: previous, new: symbols)

        files[relative] = symbols
        snapshots[worktree] = files
        saveSnapshot(worktree: worktree, files: files)
        return SymbolUpdate(path: relative, worktree: worktree, symbols: symbols, changes: changes)
    }

    /// The file's symbols at `ref` in its worktree (empty for new files).
    private func symbolsAt(ref: String, relative: String, worktree: String) -> [CodeSymbol] {
        guard let result = try? GitWorktree.git(["show", "\(ref):\(relative)"], in: worktree),
              result.status == 0 else { return [] }
        return (try? SymbolExtractor.symbols(source: result.output, path: relative)) ?? []
    }

    static func relativePath(_ path: String, to root: String) -> String {
        let canonicalPath = realpathOrSelf(path)
        let canonicalRoot = realpathOrSelf(root)
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        return canonicalPath.hasPrefix(prefix) ? String(canonicalPath.dropFirst(prefix.count)) : path
    }

    /// Symlink-resolved path, for comparing worktrees.
    public static func canonical(_ path: String) -> String { realpathOrSelf(path) }

    private static func realpathOrSelf(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Persistence

    private func snapshotFile(worktree: String) -> URL {
        // One file per worktree, named after it (`app-auth.json`), plus a
        // hash so two worktrees with the same basename can't collide.
        let name = (worktree as NSString).lastPathComponent
        return snapshotDirectory.appendingPathComponent("\(name)-\(SymbolExtractor.hash(worktree).prefix(8)).json")
    }

    private func loadSnapshot(worktree: String) -> [String: [CodeSymbol]] {
        if let cached = snapshots[worktree] { return cached }
        guard let data = try? Data(contentsOf: snapshotFile(worktree: worktree)),
              let files = try? JSONDecoder().decode([String: [CodeSymbol]].self, from: data) else { return [:] }
        snapshots[worktree] = files
        return files
    }

    private func saveSnapshot(worktree: String, files: [String: [CodeSymbol]]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(files) else { return }
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try? data.write(to: snapshotFile(worktree: worktree), options: .atomic)
    }
}

extension SymbolUpdate {
    /// The `symbols_changed` event for the log (spec §4.4), or nil when
    /// nothing changed.
    public func event(pane: String?) -> GaterEvent? {
        guard !changes.isEmpty else { return nil }
        var extra: [String: JSONValue] = [
            "path": .string(path),
            "worktree": .string(worktree),
            "public_surface": .bool(changes.contains(where: \.isPublicSurface)),
            "changes": .array(changes.map { change in
                .object([
                    "symbol": .string(change.symbol),
                    "id": .string(change.id),
                    "kind": .string(change.kind.rawValue),
                    "change": .string(change.change.rawValue),
                    "exported": .bool(change.isExported),
                ])
            }),
        ]
        if let pane { extra["pane"] = .string(pane) }
        return GaterEvent(kind: "symbols_changed", extra: extra)
    }
}
