import XCTest
@testable import GaterCore

final class IntegratorTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gater-integ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        repo = sandbox.appendingPathComponent("app").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try "base\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], repo)
        try git(["add", "."], repo)
        try commit("init", repo)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    private func git(_ args: [String], _ dir: String) throws {
        let r = try GitWorktree.git(args, in: dir)
        XCTAssertEqual(r.status, 0, r.output)
    }

    private func commit(_ message: String, _ dir: String) throws {
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", message], dir)
    }

    /// A delegate worktree with one committed file change.
    private func delegate(_ name: String, file: String, content: String) throws -> String {
        let path = try GitWorktree.ensure(delegate: name, repoRoot: repo)
        try content.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        try git(["add", file], path)
        try commit(name, path)
        return path
    }

    func testMergesDishesIntoIntegrationWithoutTouchingMain() throws {
        _ = try delegate("auth", file: "auth.txt", content: "auth\n")
        _ = try delegate("dash", file: "dash.txt", content: "dash\n")
        let integrator = Integrator(repoRoot: repo)

        guard case .merged = try integrator.merge(branches: ["gater/auth"], message: "Serve d-001") else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(try integrator.merge(branches: ["gater/auth"], message: "again"), .upToDate)
        guard case .merged = try integrator.merge(branches: ["gater/dash"], message: "Serve d-002") else {
            return XCTFail("expected a merge")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrator.worktree + "/auth.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrator.worktree + "/dash.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/auth.txt"), "main untouched")
        XCTAssertEqual(integrator.worktree, sandbox.appendingPathComponent("app-integration").path)
    }

    func testCycleMergesAsOneOctopusCommit() throws {
        _ = try delegate("a", file: "a.txt", content: "a\n")
        _ = try delegate("b", file: "b.txt", content: "b\n")
        let integrator = Integrator(repoRoot: repo)
        guard case let .merged(commit) = try integrator.merge(branches: ["gater/a", "gater/b"], message: "Serve cycle") else {
            return XCTFail("expected a merge")
        }
        let parents = try GitWorktree.git(["rev-list", "--parents", "-n", "1", commit], in: integrator.worktree).output
        XCTAssertEqual(parents.split(separator: " ").count, 4, "commit + 3 parents")
    }

    func testConflictAbortsCleanly() throws {
        _ = try delegate("a", file: "shared.txt", content: "from a\n")
        _ = try delegate("b", file: "shared.txt", content: "from b\n")
        let integrator = Integrator(repoRoot: repo)
        _ = try integrator.merge(branches: ["gater/a"], message: "a")
        XCTAssertEqual(try integrator.merge(branches: ["gater/b"], message: "b"), .conflict(files: ["shared.txt"]))
        let status = try GitWorktree.git(["status", "--porcelain"], in: integrator.worktree).output
        XCTAssertEqual(status, "", "merge aborted, integration clean")
    }

    func testTestsRunInTheIntegrationWorktree() throws {
        let integrator = Integrator(repoRoot: repo)
        try integrator.ensureWorktree()
        XCTAssertNil(integrator.runTests(command: nil))
        let pass = try XCTUnwrap(integrator.runTests(command: "test -f shared.txt && echo ok"))
        XCTAssertTrue(pass.passed)
        XCTAssertEqual(pass.tail, "ok")
        XCTAssertEqual(integrator.runTests(command: "echo boom; exit 3")?.passed, false)
    }

    func testPassDiffAndConfig() throws {
        let path = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        let base = try XCTUnwrap(GitWorktree.head(of: path))
        try "changed\n".write(toFile: path + "/shared.txt", atomically: true, encoding: .utf8)
        try commit("change", path)
        let diff = Integrator.passDiff(worktree: path, base: base)
        XCTAssertTrue(diff.stat.contains("shared.txt"))
        XCTAssertTrue(diff.diff.contains("+changed"))
        XCTAssertFalse(diff.truncated)

        try FileManager.default.createDirectory(atPath: repo + "/.gater", withIntermediateDirectories: true)
        try #"{"test_command": "npm test"}"#.write(toFile: repo + "/.gater/config.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(GaterConfig.load(repoRoot: repo, environment: [:]).testCommand, "npm test")
        XCTAssertEqual(GaterConfig.load(repoRoot: repo, environment: ["GATER_TEST_COMMAND": "make check"]).testCommand, "make check")
    }
}
