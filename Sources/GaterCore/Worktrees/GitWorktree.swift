import Foundation

public enum GitWorktreeError: Error, CustomStringConvertible, Equatable {
    case invalidName(String)
    case notARepository(String)
    case pathOccupied(String)
    case noCommits(String)
    case gitFailed(arguments: [String], status: Int32, output: String)

    public var description: String {
        switch self {
        case let .invalidName(name):
            return "Invalid delegate name \"\(name)\": use letters, digits, '.', '_' or '-'."
        case let .notARepository(path):
            return "\(path) is not inside a git repository."
        case let .pathOccupied(path):
            return "\(path) already exists and is not a worktree of this repository."
        case let .noCommits(path):
            return "\(path) has no commits yet. Delegates branch from the current commit, so make one first (git add . && git commit -m init)."
        case let .gitFailed(arguments, status, output):
            return "git \(arguments.joined(separator: " ")) exited \(status): \(output)"
        }
    }
}

/// Creates and locates the per-delegate git worktrees (spec §4.1):
/// `git worktree add ../<repo>-<name> -b gater/<name>`.
public enum GitWorktree {
    public static func branch(forDelegate name: String) -> String {
        "gater/\(name)"
    }

    /// Sibling of the repo root: `<parent>/<repo>-<name>`.
    ///
    /// Plain string path math on purpose: URL/NSString standardizing
    /// rewrites /private/var to /var on macOS, which then disagrees with
    /// the paths git reports.
    public static func path(forDelegate name: String, repoRoot: String) -> String {
        var root = repoRoot
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        let ns = root as NSString
        return (ns.deletingLastPathComponent as NSString)
            .appendingPathComponent("\(ns.lastPathComponent)-\(name)")
    }

    /// Names become branch and directory names, so keep them boring.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-"), !name.hasPrefix("."),
              !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
        }
    }

    /// Top-level directory of the repository containing `path`, or nil.
    public static func repoRoot(containing path: String) -> String? {
        guard let result = try? git(["rev-parse", "--show-toplevel"], in: path), result.status == 0 else {
            return nil
        }
        let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// Paths of every worktree registered with the repository.
    public static func list(repoRoot: String) throws -> [String] {
        let result = try git(["worktree", "list", "--porcelain"], in: repoRoot)
        guard result.status == 0 else {
            throw GitWorktreeError.gitFailed(arguments: ["worktree", "list"], status: result.status, output: result.output)
        }
        return result.output.split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }

    /// Ensures the delegate's worktree exists and returns its path.
    ///
    /// Idempotent: reopening a delegate whose worktree is already registered
    /// reuses it. If the `gater/<name>` branch survives from an earlier
    /// worktree, it's checked out rather than recreated.
    @discardableResult
    public static func ensure(delegate name: String, repoRoot: String) throws -> String {
        guard isValidName(name) else { throw GitWorktreeError.invalidName(name) }
        guard let root = self.repoRoot(containing: repoRoot) else {
            throw GitWorktreeError.notARepository(repoRoot)
        }

        // Delegates branch from HEAD. With no commit yet, recent git quietly
        // makes an *empty* orphan branch, so the delegate starts with none
        // of the repo's files (seen live). Refuse instead.
        guard (try? git(["rev-parse", "--verify", "--quiet", "HEAD"], in: root))?.status == 0 else {
            throw GitWorktreeError.noCommits(root)
        }

        // Forget worktrees whose folders were deleted by hand ("prunable"),
        // or a stale record would hand back a directory that isn't there.
        _ = try? git(["worktree", "prune"], in: root)

        let target = path(forDelegate: name, repoRoot: root)
        let canonicalTarget = canonical(target)
        if try list(repoRoot: root).contains(where: { canonical($0) == canonicalTarget }) {
            return target
        }
        if FileManager.default.fileExists(atPath: target) {
            throw GitWorktreeError.pathOccupied(target)
        }

        let branch = branch(forDelegate: name)
        let branchExists = (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root))?.status == 0
        let args = branchExists
            ? ["worktree", "add", target, branch]
            : ["worktree", "add", target, "-b", branch]
        let result = try git(args, in: root)
        guard result.status == 0 else {
            throw GitWorktreeError.gitFailed(arguments: args, status: result.status, output: result.output)
        }
        return target
    }

    /// The commit `HEAD` points at, or nil (no commits / not a repo).
    public static func head(of worktree: String) -> String? {
        guard let result = try? git(["rev-parse", "--verify", "--quiet", "HEAD"], in: worktree),
              result.status == 0 else { return nil }
        let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Files that changed in `worktree` since commit `since`: committed in
    /// between, plus modified, staged, or untracked now. Paths are relative.
    /// Catches edits made through shell commands, which no Edit/Write hook
    /// reports.
    public static func changedFiles(in worktree: String, since: String) -> [String] {
        var files = Set<String>()
        if let diff = try? git(["diff", "--name-only", since, "HEAD"], in: worktree), diff.status == 0 {
            diff.output.split(separator: "\n").forEach { files.insert(String($0)) }
        }
        if let status = try? git(["status", "--porcelain", "-uall", "--no-renames"], in: worktree), status.status == 0 {
            for line in status.output.split(separator: "\n") where line.count > 3 {
                files.insert(String(line.dropFirst(3)))
            }
        }
        return files.sorted()
    }

    /// Adds `pattern` to the repository's `info/exclude` — ignored in every
    /// worktree, never committed, invisible to the user's .gitignore.
    public static func exclude(pattern: String, comment: String, in directory: String) throws {
        let result = try git(["rev-parse", "--git-common-dir"], in: directory)
        guard result.status == 0 else { return }
        var commonDir = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !commonDir.hasPrefix("/") {
            commonDir = (directory as NSString).appendingPathComponent(commonDir)
        }
        let exclude = URL(fileURLWithPath: commonDir).appendingPathComponent("info/exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(where: { $0 == pattern }) else { return }
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try (current + separator + "# \(comment)\n" + pattern + "\n")
            .write(to: exclude, atomically: true, encoding: .utf8)
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public struct GitResult {
        public var status: Int32
        public var output: String
    }

    public static func git(_ arguments: [String], in directory: String) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
