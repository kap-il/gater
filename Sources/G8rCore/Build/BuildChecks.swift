import Foundation

/// What g8r checks when a build session goes idle, in order: nothing is
/// left uncommitted, `build_command` succeeds, `test_command` succeeds.
/// The first that fails is the answer; a command that isn't configured
/// passes.
public enum BuildChecks {
    public struct Result: Equatable {
        public var passed: Bool
        /// What to show for it: the failing check and the last lines it
        /// printed, or what passed.
        public var tail: String

        public init(passed: Bool, tail: String) {
            self.passed = passed
            self.tail = tail
        }
    }

    /// Lines of a failing command's output kept in the tail.
    static let tailLines = 30

    /// - Parameter run: runs in `worktree`, as `ProcessRunner.runner(in:)` does.
    public static func run(worktree: String, config: G8rConfig, run: CommandRunner) -> Result {
        var passed: [String] = []

        switch attempt(run, "git", ["status", "--porcelain", "--untracked-files=all"]) {
        case let .failure(output):
            return Result(passed: false, tail: "Couldn't read git status in \(worktree):\n" + tail(of: output))
        case let .success(output):
            let dirty = output.split(separator: "\n").map(String.init)
            if !dirty.isEmpty {
                return Result(passed: false, tail: "Uncommitted changes:\n" + dirty.prefix(tailLines).joined(separator: "\n"))
            }
            passed.append("nothing uncommitted")
        }

        for (name, command) in [("build_command", config.buildCommand), ("test_command", config.testCommand)] {
            guard let command, !command.isEmpty else { continue }
            if case let .failure(output) = attempt(run, "/bin/sh", ["-c", command]) {
                return Result(passed: false, tail: "\(name) `\(command)` failed:\n" + tail(of: output))
            }
            passed.append("`\(command)` passed")
        }
        return Result(passed: true, tail: passed.joined(separator: ", "))
    }

    private enum Outcome {
        case success(String)
        case failure(String)
    }

    private static func attempt(_ run: CommandRunner, _ executable: String, _ arguments: [String]) -> Outcome {
        do {
            let result = try run(executable, arguments, nil)
            return result.status == 0 ? .success(result.output) : .failure(result.output + "\n(exit \(result.status))")
        } catch {
            return .failure("\(error)")
        }
    }

    static func tail(of output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(tailLines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
