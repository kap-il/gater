import Foundation

/// The git side of finishing (spec §4.10): one long-lived
/// `gater/integration` branch, checked out in its own worktree
/// (`../<repo>-integration`) so merges never touch the user's checkout or
/// a delegate's. Merging it into main stays the human's call.
public struct Integrator {
    public static let branch = "gater/integration"

    public let repoRoot: String

    public init(repoRoot: String) {
        self.repoRoot = repoRoot
    }

    public var worktree: String {
        GitWorktree.path(forDelegate: "integration", repoRoot: repoRoot)
    }

    public enum IntegratorError: Error, Equatable, CustomStringConvertible {
        case git(String)

        public var description: String {
            switch self { case let .git(output): return output }
        }
    }

    /// Creates the integration branch (from the repo's current HEAD) and
    /// its worktree if needed; returns the worktree path.
    @discardableResult
    public func ensureWorktree() throws -> String {
        _ = try? GitWorktree.git(["worktree", "prune"], in: repoRoot)
        let path = worktree
        if (try? GitWorktree.list(repoRoot: repoRoot))?.contains(where: { Self.same($0, path) }) == true { return path }
        let exists = (try? GitWorktree.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(Self.branch)"], in: repoRoot))?.status == 0
        let args = exists ? ["worktree", "add", path, Self.branch] : ["worktree", "add", path, "-b", Self.branch]
        let result = try GitWorktree.git(args, in: repoRoot)
        guard result.status == 0 else { throw IntegratorError.git(result.output) }
        return path
    }

    public enum MergeResult: Equatable {
        case merged(commit: String)
        /// Nothing to merge (branch already contained).
        case upToDate
        /// Aborted cleanly; integration is unchanged.
        case conflict(files: [String])
    }

    /// Merges the dishes' branches as one merge commit (a cycle is a unit
    /// of several branches: an octopus merge).
    public func merge(branches: [String], message: String) throws -> MergeResult {
        let path = try ensureWorktree()
        let before = GitWorktree.head(of: path)
        let result = try GitWorktree.git(["-c", "user.name=Gater", "-c", "user.email=gater@localhost",
                                          "merge", "--no-ff", "-m", message] + branches, in: path)
        if result.status == 0 {
            let after = GitWorktree.head(of: path)
            return after == before ? .upToDate : .merged(commit: after ?? "")
        }
        let conflicted = (try? GitWorktree.git(["diff", "--name-only", "--diff-filter=U"], in: path))?.output
            .split(separator: "\n").map(String.init) ?? []
        _ = try? GitWorktree.git(["merge", "--abort"], in: path)
        if conflicted.isEmpty { throw IntegratorError.git(result.output) }
        return .conflict(files: conflicted)
    }

    public struct TestRun: Equatable {
        public var passed: Bool
        /// Last lines of output, for the report.
        public var tail: String
    }

    /// Runs the project's tests on the integration worktree; nil when no
    /// test command is configured.
    public func runTests(command: String?, timeout: TimeInterval = 600) -> TestRun? {
        guard let command, !command.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return TestRun(passed: false, tail: "couldn't run \(command): \(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        let reader = pipe.fileHandleForReading
        while process.isRunning && Date() < deadline {
            output.append(reader.availableData)
        }
        if process.isRunning { process.terminate() }
        output.append(reader.readDataToEndOfFile())
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(15).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return TestRun(passed: process.terminationStatus == 0 && Date() < deadline, tail: tail)
    }

    /// Diffstat + diff of a dish's work since its base, capped, for the
    /// pass report (spec: the orchestrator gets the dish's diff + note).
    public static func passDiff(worktree: String, base: String, maxLines: Int = 120) -> (stat: String, diff: String, truncated: Bool) {
        let stat = (try? GitWorktree.git(["diff", "--stat", base], in: worktree))?.output ?? ""
        let full = (try? GitWorktree.git(["diff", base], in: worktree))?.output ?? ""
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        return (stat.trimmingCharacters(in: .whitespacesAndNewlines),
                lines.prefix(maxLines).joined(separator: "\n"), lines.count > maxLines)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        func canonical(_ p: String) -> String {
            guard let r = realpath(p, nil) else { return p }
            defer { free(r) }
            return String(cString: r)
        }
        return canonical(a) == canonical(b)
    }
}

/// Per-repo settings in `<repo>/.gater/config.json` (e.g.
/// `{"test_command": "npm test"}`); GATER_TEST_COMMAND overrides.
public struct GaterConfig: Equatable {
    public var testCommand: String?

    public static func load(repoRoot: String, environment: [String: String] = DotEnv.load()) -> GaterConfig {
        let path = URL(fileURLWithPath: repoRoot).appendingPathComponent(".gater/config.json")
        let json = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let fromFile = json?.value(atPath: "test_command")?.stringValue
        return GaterConfig(testCommand: environment["GATER_TEST_COMMAND"] ?? fromFile)
    }
}
