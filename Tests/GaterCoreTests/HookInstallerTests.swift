import XCTest
@testable import GaterCore

final class HookInstallerTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!
    private let config = HookInstaller.Config(hookBinary: "/opt/gater bin/gater-hook", delegationTool: "SendMessage")

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gater-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        repo = sandbox.appendingPathComponent("app").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"]] {
            XCTAssertEqual(try GitWorktree.git(args, in: repo).status, 0)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func settings(in dir: String) throws -> JSONValue {
        let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(".claude/settings.local.json"))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func commands(_ settings: JSONValue, event: String) -> [(matcher: String?, command: String)] {
        (settings.value(atPath: "hooks.\(event)")?.arrayValue ?? []).flatMap { group in
            (group.value(atPath: "hooks")?.arrayValue ?? []).compactMap { hook in
                hook.value(atPath: "command")?.stringValue.map { (group.value(atPath: "matcher")?.stringValue, $0) }
            }
        }
    }

    func testFreshInstallWritesSpecHookTable() throws {
        try HookInstaller.install(into: repo, config: config)
        let s = try settings(in: repo)
        let quoted = "'/opt/gater bin/gater-hook'"
        XCTAssertEqual(commands(s, event: "PreToolUse").map(\.matcher), ["SendMessage"])
        XCTAssertEqual(commands(s, event: "PostToolUse").map(\.matcher), ["SendMessage", "Edit|Write|MultiEdit", "Bash"])
        XCTAssertEqual(commands(s, event: "Stop").map(\.matcher), [nil])
        XCTAssertTrue(commands(s, event: "PreToolUse").allSatisfy { $0.command == quoted })
    }

    func testMergeKeepsUserHooksAndSettingsAndIsIdempotent() throws {
        let dir = (repo as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = """
        {"permissions":{"allow":["Bash(ls)"]},
         "hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"prettier --write"}]}]}}
        """
        try existing.write(toFile: (dir as NSString).appendingPathComponent("settings.local.json"), atomically: true, encoding: .utf8)

        try HookInstaller.install(into: repo, config: config)
        try HookInstaller.install(into: repo, config: config) // second run must not duplicate

        let s = try settings(in: repo)
        XCTAssertEqual(s.value(atPath: "permissions.allow")?.arrayValue?.first?.stringValue, "Bash(ls)")
        let post = commands(s, event: "PostToolUse")
        XCTAssertEqual(post.filter { $0.command == "prettier --write" }.count, 1)
        XCTAssertEqual(post.filter { $0.command.contains("gater-hook") }.count, 3)
        XCTAssertEqual(commands(s, event: "PreToolUse").count, 1)
    }

    func testReinstallWithNewToolNameReplacesOldMatcher() throws {
        try HookInstaller.install(into: repo, config: HookInstaller.Config(hookBinary: "/x/gater-hook", delegationTool: "OldName"))
        try HookInstaller.install(into: repo, config: config)
        let s = try settings(in: repo)
        XCTAssertEqual(commands(s, event: "PreToolUse").map(\.matcher), ["SendMessage"])
        XCTAssertFalse(commands(s, event: "PostToolUse").contains { $0.matcher == "OldName" })
    }

    func testRefusesToOverwriteUnparseableSettings() throws {
        let dir = (repo as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("settings.local.json")
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.install(into: repo, config: config))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{ not json")
    }

    func testSettingsFileIsGitExcludedIncludingInWorktrees() throws {
        let worktree = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        try HookInstaller.install(into: worktree, config: config)
        try HookInstaller.install(into: repo, config: config)

        for dir in [repo!, worktree] {
            let status = try GitWorktree.git(["status", "--porcelain"], in: dir)
            XCTAssertEqual(status.output, "", "settings file should be invisible to git in \(dir)")
        }
        let exclude = try String(contentsOfFile: (repo as NSString).appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertEqual(exclude.components(separatedBy: "/.claude/settings.local.json").count - 1, 1, "added once")
    }
}
