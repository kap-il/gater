import Foundation

/// Replays git history as the map's growth: for each commit, how many lines
/// each component had after it. Also gives each node its commit count and
/// its first and last commit.
///
/// Only the code files on the map today count, with the owners codemap gave
/// them, so test files, ignored paths and deleted components never appear.
/// Renames are read as a removal and an addition.
///
/// The timeline follows `HEAD`'s first parents, with each merge diffed
/// against its first parent, so every point is the line count of that
/// commit's tree. Commit counts come from every commit that isn't a merge.
/// Both come from one `git log` pass.
public struct Timeline: MapStage {
    public init() {}

    public func apply(to map: inout LivingMap, context: MapContext) throws {
        var owners: [String: String] = [:]
        for node in map.nodes {
            for file in node.files where CodeFiles.isCode(file.path) && !CodeFiles.isTest(file.path) {
                owners[file.path] = node.id
            }
        }

        let commits = try Self.log(in: context.codeRoot)
        let replay = Self.replay(commits, owners: owners)
        map.timeline = replay.timeline
        for index in map.nodes.indices {
            map.nodes[index].git = replay.git[map.nodes[index].id] ?? NodeGit(commits: 0, first: nil, last: nil)
        }
    }

    /// One commit as `git log --numstat` tells it.
    struct Commit {
        var sha: String
        var parents: [String]
        var t: Int
        var subject: String
        /// Lines added and removed in each file, against the first parent.
        var changes: [(path: String, added: Int, removed: Int)]
    }

    private static let header: Character = "\u{1E}"
    private static let field = "\u{1F}"

    /// Every commit reachable from `HEAD`, oldest first. None when the repo
    /// has no commits yet.
    static func log(in codeRoot: String) throws -> [Commit] {
        let result = try GitWorktree.git(
            ["log", "--reverse", "--no-renames", "--numstat", "-z", "--diff-merges=first-parent",
             "--format=\(header)%H %P\(field)%at\(field)%s"],
            in: codeRoot)
        guard result.status == 0 else { return [] }
        return parse(result.output)
    }

    /// Reads `git log -z --numstat` with the header format `log` asks for.
    /// Binary files, whose counts are `-`, are skipped.
    static func parse(_ output: String) -> [Commit] {
        var commits: [Commit] = []
        for token in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if token.first == header {
                let fields = token.dropFirst().components(separatedBy: field)
                guard fields.count >= 3 else { continue }
                let hashes = fields[0].split(separator: " ").map(String.init)
                guard let sha = hashes.first else { continue }
                commits.append(Commit(sha: sha, parents: Array(hashes.dropFirst()), t: Int(fields[1]) ?? 0,
                                      subject: fields[2...].joined(separator: field), changes: []))
                continue
            }
            let line = token.drop { $0 == "\n" }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let added = Int(parts[0]), let removed = Int(parts[1]), !commits.isEmpty
            else { continue }
            commits[commits.count - 1].changes.append((String(parts[2]), added, removed))
        }
        return commits
    }

    /// The timeline along `HEAD`'s first parents, and each node's commits.
    static func replay(_ commits: [Commit], owners: [String: String])
        -> (timeline: [TimelinePoint], git: [String: NodeGit]) {
        let bySha = Dictionary(commits.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [Commit] = []
        // `git log` starts from `HEAD`, so with `--reverse` it comes last.
        var next = commits.last?.sha
        var seen: Set<String> = []
        while let sha = next, let commit = bySha[sha], seen.insert(sha).inserted {
            chain.append(commit)
            next = commit.parents.first
        }
        chain.reverse()

        var lines: [String: Int] = [:]
        var timeline: [TimelinePoint] = []
        for commit in chain {
            for change in commit.changes where owners[change.path] != nil {
                lines[change.path, default: 0] += change.added - change.removed
            }
            var loc: [String: Int] = [:]
            for (path, count) in lines where count > 0 {
                loc[owners[path]!, default: 0] += count
            }
            timeline.append(TimelinePoint(sha: short(commit.sha), t: commit.t, subject: commit.subject, loc: loc))
        }

        var git: [String: NodeGit] = [:]
        for commit in commits where commit.parents.count < 2 {
            let ref = CommitRef(sha: short(commit.sha), t: commit.t, subject: commit.subject)
            for id in Set(commit.changes.compactMap { owners[$0.path] }) {
                var node = git[id] ?? NodeGit(commits: 0, first: ref, last: ref)
                node.commits += 1
                if let first = node.first, ref.t < first.t { node.first = ref }
                if let last = node.last, ref.t >= last.t { node.last = ref }
                git[id] = node
            }
        }
        return (timeline, git)
    }

    private static func short(_ sha: String) -> String {
        String(sha.prefix(7))
    }
}
