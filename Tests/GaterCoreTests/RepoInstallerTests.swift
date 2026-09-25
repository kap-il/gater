import XCTest
@testable import GaterCore

final class TemplatesTests: XCTestCase {
    /// Root of this checkout, from this file's path.
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEmbeddedSkillMatchesRepoCopy() throws {
        let file = try String(contentsOf: root.appendingPathComponent("claude/skills/gater-delegate/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(Templates.delegationSkill, file, "regenerate Templates.swift from claude/")
    }

    func testEmbeddedGitHookMatchesRepoCopy() throws {
        let file = try String(contentsOf: root.appendingPathComponent("claude/git-hooks/prepare-commit-msg"), encoding: .utf8)
        XCTAssertEqual(Templates.prepareCommitMsg, file, "regenerate Templates.swift from claude/")
    }

    func testSkillTriggerIsDelegationOnly() {
        XCTAssertTrue(Templates.delegationSkill.contains("description: Use when sending work to another Claude session."))
    }
}

final class RepoInstallerTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!
    private var hookBinary: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gater-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        repo = sandbox.appendingPathComponent("app").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"]] {
            XCTAssertEqual(try GitWorktree.git(args, in: repo).status, 0)
        }
        hookBinary = try builtGaterHook()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// The gater-hook built alongside this test bundle.
    private func builtGaterHook() throws -> String {
        let bundle = Bundle(for: RepoInstallerTests.self).bundleURL
        let candidate = bundle.deletingLastPathComponent().appendingPathComponent("gater-hook").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: candidate), "gater-hook not built")
        return candidate
    }

    func testSkillInstalledAndInvisibleToGit() throws {
        try RepoInstaller.installSkill(repoRoot: repo)
        let installed = try String(contentsOfFile: (repo as NSString).appendingPathComponent(".claude/skills/gater-delegate/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(installed, Templates.delegationSkill)
        XCTAssertEqual(try GitWorktree.git(["status", "--porcelain"], in: repo).output, "")
    }

    func testForeignCommitHookIsNotReplaced() throws {
        let path = (repo as NSString).appendingPathComponent(".git/hooks/prepare-commit-msg")
        try "#!/bin/sh\necho mine\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try RepoInstaller.installCommitHook(repoRoot: repo, hookBinary: hookBinary),
                       .skippedForeignHook(path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "#!/bin/sh\necho mine\n")
    }

    /// A real commit in a delegate worktree, from a "pane": the hook reads
    /// the plan and appends the dish's trailers.
    func testCommitInDelegateWorktreeGetsTrailers() throws {
        XCTAssertEqual(try RepoInstaller.installCommitHook(repoRoot: repo, hookBinary: hookBinary), .installed)
        XCTAssertEqual(try RepoInstaller.installCommitHook(repoRoot: repo, hookBinary: hookBinary), .installed,
                       "reinstalling over our own hook is fine")

        let plan = PlanReducer.replay([GaterEvent(fields: [
            "kind": .string("delegation"), "ts": .string("2026-09-25T20:00:00Z"), "to": .string("delegate-auth"),
            "gater": .object(["type": .string("delegate"), "id": .string("d-007"), "feature": .string("Auth"),
                              "directive": .string("expiry"), "scope": .array([])]),
        ])])
        let store = PlanStore(path: PlanStore.defaultPath(repoRoot: repo))
        try store.rebuild(from: [])
        try JSONEncoder().encode(plan).write(to: store.path)

        let worktree = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        try "x".write(toFile: (worktree as NSString).appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        func commit(env: [String: String], message: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@t",
                           "commit", "-q", "--allow-empty", "-m", message]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "GATER_PANE_ID")
            for (k, v) in env { environment[k] = v }
            p.environment = environment
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            return try GitWorktree.git(["log", "-1", "--format=%B"], in: worktree).output
        }

        _ = try GitWorktree.git(["add", "f.txt"], in: worktree)
        let inPane = try commit(env: ["GATER_PANE_ID": "delegate-auth", "GATER_REPO": repo], message: "Add expiry")
        XCTAssertTrue(inPane.contains("Gater-Dish: d-007"), inPane)
        XCTAssertTrue(inPane.contains("Gater-Feature: Auth"), inPane)
        XCTAssertTrue(inPane.contains("Gater-Agent: delegate-auth"), inPane)

        let outside = try commit(env: [:], message: "Outside Gater")
        XCTAssertFalse(outside.contains("Gater-"), "commits outside Gater panes are untouched")
    }

    func testTrailersWithoutADish() {
        let trailers = CommitTrailers.trailers(plan: Plan(), pane: "orch")
        XCTAssertEqual(trailers.map(\.key), ["Gater-Agent"])
    }
}
