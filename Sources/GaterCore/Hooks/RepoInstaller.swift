import Foundation

/// Installs the orchestrator's delegation skill and the commit-trailer git
/// hook into a target repository — without ever overwriting something that
/// isn't Gater's, and without showing up in `git status`.
public enum RepoInstaller {
    static let skillPath = ".claude/skills/gater-delegate/SKILL.md"

    /// Writes the gater-delegate skill where the orchestrator's claude
    /// (running in the repo root) discovers it. The skill's description
    /// makes it load only once Claude has decided to delegate (spec §4.3).
    public static func installSkill(repoRoot: String) throws {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(skillPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Templates.delegationSkill.write(to: url, atomically: true, encoding: .utf8)
        try GitWorktree.exclude(pattern: "/.claude/skills/gater-delegate/", comment: "Gater delegation skill",
                                in: repoRoot)
    }

    public enum GitHookResult: Equatable {
        case installed
        /// A prepare-commit-msg hook that isn't Gater's already exists.
        case skippedForeignHook(String)
    }

    /// Installs prepare-commit-msg (shared by every worktree of the repo;
    /// respects core.hooksPath). An existing hook Gater didn't write is
    /// left alone rather than replaced.
    @discardableResult
    public static func installCommitHook(repoRoot: String, hookBinary: String) throws -> GitHookResult {
        let result = try GitWorktree.git(["rev-parse", "--git-path", "hooks/prepare-commit-msg"], in: repoRoot)
        guard result.status == 0 else {
            throw GitWorktreeError.gitFailed(arguments: ["rev-parse", "--git-path"], status: result.status, output: result.output)
        }
        var path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.hasPrefix("/") { path = (repoRoot as NSString).appendingPathComponent(path) }

        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           !existing.contains(Templates.gitHookMarker) {
            return .skippedForeignHook(path)
        }
        let quoted = hookBinary.replacingOccurrences(of: "'", with: "'\\''")
        let script = Templates.prepareCommitMsg.replacingOccurrences(of: Templates.hookPlaceholder, with: quoted)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return .installed
    }
}

/// The accountability trailers for a commit made in `pane` (spec §4.3).
public enum CommitTrailers {
    public static func trailers(plan: Plan?, pane: String) -> [(key: String, value: String)] {
        var trailers: [(key: String, value: String)] = []
        if let dish = plan?.currentDish(forPane: pane) {
            trailers.append(("Gater-Dish", dish.id))
            trailers.append(("Gater-Feature", dish.feature))
        }
        trailers.append(("Gater-Agent", pane))
        return trailers
    }

    /// Appends the trailers to a commit message file via
    /// `git interpret-trailers`, which handles blank lines and existing
    /// trailer blocks correctly.
    public static func append(to messageFile: String, plan: Plan?, pane: String) throws {
        var args = ["interpret-trailers", "--in-place", "--if-exists", "addIfDifferent"]
        for trailer in trailers(plan: plan, pane: pane) {
            args += ["--trailer", "\(trailer.key): \(trailer.value)"]
        }
        // git hands hooks a path relative to the worktree root, which is
        // also the hook's working directory.
        let result = try GitWorktree.git(args + [messageFile], in: FileManager.default.currentDirectoryPath)
        guard result.status == 0 else {
            throw GitWorktreeError.gitFailed(arguments: ["interpret-trailers"], status: result.status, output: result.output)
        }
    }
}
