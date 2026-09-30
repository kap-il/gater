import Foundation

/// The folder g8r is working on: where the map measures, Build and Run
/// tests act, and the event log lives. It follows the active shell: when
/// that shell's working folder resolves to another root, the root moves and
/// a `root_changed` event says so.
///
/// Called on one thread (the app's main thread).
public final class ProjectRoot {
    /// The current root, as `resolve` returns it.
    public private(set) var path: String
    /// Called after the root moved, with the `root_changed` event.
    public var onChange: ((_ event: G8rEvent) -> Void)?

    private let resolver: (String) -> String
    private let now: () -> Date
    /// The folder last followed and when it was resolved. An unchanged
    /// folder is resolved again only every `recheck` seconds (resolving
    /// runs git), so a `git init` in place still moves the root.
    private var lastFolder: String?
    private var lastResolved = Date.distantPast
    public static let recheck: TimeInterval = 3

    /// - Parameters:
    ///   - path: the root at launch, already resolved.
    ///   - resolve: folder to root; `ProjectRoot.resolve` unless a test
    ///     stands in for it.
    public init(path: String, now: @escaping () -> Date = Date.init,
                resolve: @escaping (String) -> String = { ProjectRoot.resolve($0) }) {
        self.path = path
        self.now = now
        self.resolver = resolve
    }

    /// The active shell in `pane` is in `folder`. Moves the root when that
    /// folder resolves to a different one, and returns the `root_changed`
    /// event (after calling `onChange`); nil when the root stays.
    @discardableResult
    public func follow(folder: String, pane: String?) -> G8rEvent? {
        let time = now()
        guard folder != lastFolder || time.timeIntervalSince(lastResolved) >= Self.recheck else { return nil }
        lastFolder = folder
        lastResolved = time
        let root = resolver(folder)
        guard root != path else { return nil }
        let from = path
        path = root
        var extra: [String: JSONValue] = ["from": .string(from), "to": .string(root)]
        if let pane { extra["pane"] = .string(pane) }
        let event = G8rEvent(kind: "root_changed", extra: extra)
        onChange?(event)
        return event
    }

    // MARK: - Resolution

    /// Files or folders that make a folder outside git a project.
    public static let markers = ["PLAN.md", "plans", "docs/plans", "g8r.json"]

    /// The project root for a working folder:
    ///
    /// 1. inside a git repository, its top level (unless that is the home
    ///    folder or `/`, which a dotfiles repository can make it). A g8r
    ///    worktree (`../<repo>-<name>` on a `g8r/` branch) counts as the
    ///    main repository it belongs to;
    /// 2. otherwise the nearest folder, from `folder` up, holding a plan
    ///    doc (`PLAN.md`, `plans/`, `docs/plans/`) or `g8r.json`, stopping
    ///    below the home folder (home and `/` are never picked this way);
    /// 3. otherwise `folder` itself.
    ///
    /// Paths are real paths (symlinks resolved, as git and the kernel
    /// report them), so the same folder always gives the same root.
    ///
    /// - Parameters:
    ///   - home: the home folder, where the walk up stops.
    ///   - gitTopLevel: the top level of the repository holding a folder,
    ///     or nil; `GitWorktree.repoRoot(containing:)` by default.
    ///   - exists: whether a path exists; the file system by default.
    ///   - mainRepository: for a g8r worktree's top level, the main
    ///     repository it was made from; nil for anything else.
    public static func resolve(_ folder: String, home: String = NSHomeDirectory(),
                               gitTopLevel: (String) -> String? = { GitWorktree.repoRoot(containing: $0) },
                               mainRepository: (String) -> String? = { GitWorktree.mainRepository(ofG8rWorktree: $0) },
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let start = canonical(folder)
        let home = canonical(home)
        if let top = gitTopLevel(start).map(canonical), top != home, top != "/" {
            return mainRepository(top).map(canonical) ?? top
        }

        var current = start
        while current != home, current != "/", !current.isEmpty {
            let base = current
            if markers.contains(where: { exists((base as NSString).appendingPathComponent($0)) }) { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return start
    }

    /// `path` with symlinks resolved and no trailing slash; as given when
    /// it doesn't exist.
    public static func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}
