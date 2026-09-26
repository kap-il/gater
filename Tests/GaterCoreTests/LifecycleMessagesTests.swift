import XCTest
@testable import GaterCore

final class LifecycleMessagesTests: XCTestCase {
    private let dish = Dish(id: "d-001", feature: "Auth", directive: "add session expiry", scope: [], pane: "delegate-auth",
                            state: .pass, instructions: [], mergedInto: nil, createdAt: "t", updatedAt: "t")

    func testPassReport() {
        let text = LifecycleMessages.pass(dish: dish, did: "added expiry", assumed: "ms timestamps", worktree: "/w/app-auth",
                                          base: "abc", stat: " src/users.ts | 2 +-", diff: "-a\n+b", truncated: true)
        XCTAssertTrue(text.hasPrefix("[GATER] d-001 at the pass (Auth · delegate-auth)"))
        XCTAssertTrue(text.contains("did: added expiry"))
        XCTAssertTrue(text.contains("+b"))
        XCTAssertTrue(text.contains("git -C /w/app-auth diff abc"))
        XCTAssertTrue(text.hasSuffix("Finish with GATER/1 type: finish for d-001, or instruct/rescope it."))
    }

    func testServedReportCarriesTheTestResult() {
        let passed = LifecycleMessages.served(dishes: ["d-001"], commit: "abcdef123", integrationWorktree: "/w/app-integration",
                                              tests: .init(passed: true, tail: "ok"))
        XCTAssertTrue(passed.contains("served d-001 into gater/integration (merge abcdef1)"))
        XCTAssertTrue(passed.contains("tests: passed"))
        let failed = LifecycleMessages.served(dishes: ["d-001", "d-002"], commit: "abc", integrationWorktree: "/w",
                                              tests: .init(passed: false, tail: "1 failing"))
        XCTAssertTrue(failed.contains("d-001 + d-002"))
        XCTAssertTrue(failed.contains("tests: FAILED"))
        XCTAssertTrue(failed.contains("1 failing"))
        XCTAssertTrue(LifecycleMessages.served(dishes: ["d-1"], commit: "a", integrationWorktree: "/w", tests: nil)
            .contains("not configured"))
    }

    func testWorktreeRemovalKeepsTheBranchAndRefusesDirty() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gater-rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = String(cString: realpath(tmp.path, nil))
        let repo = root + "/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i"]] {
            _ = try GitWorktree.git(args, in: repo)
        }
        let clean = try GitWorktree.ensure(delegate: "clean", repoRoot: repo)
        let dirty = try GitWorktree.ensure(delegate: "dirty", repoRoot: repo)
        try "wip".write(toFile: dirty + "/wip.txt", atomically: true, encoding: .utf8)

        XCTAssertTrue(GitWorktree.remove(worktree: clean, repoRoot: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean))
        XCTAssertEqual(try GitWorktree.git(["rev-parse", "--verify", "--quiet", "refs/heads/gater/clean"], in: repo).status, 0)

        XCTAssertFalse(GitWorktree.remove(worktree: dirty, repoRoot: repo), "uncommitted work: keep it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty + "/wip.txt"))
    }
}
