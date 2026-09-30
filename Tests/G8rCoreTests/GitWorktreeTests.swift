import XCTest
@testable import G8rCore

final class GitWorktreeTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("g8r-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // realpath, not resolvingSymlinksInPath: Foundation strips /private
        // from /private/var, while git reports the real path.
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        let repoURL = sandbox.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        repo = repoURL.path

        for args in [["init", "-q", "-b", "main"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"]] {
            let result = try GitWorktree.git(args, in: repo)
            XCTAssertEqual(result.status, 0, result.output)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testNamingAndPaths() {
        XCTAssertEqual(GitWorktree.branch(forDelegate: "auth"), "g8r/auth")
        XCTAssertEqual(GitWorktree.path(forDelegate: "auth", repoRoot: "/src/app"), "/src/app-auth")
        XCTAssertEqual(GitWorktree.path(forDelegate: "auth", repoRoot: "/src/app/"), "/src/app-auth")
    }

    func testNameValidation() {
        for good in ["auth", "user-card", "v2.fix", "a_b"] {
            XCTAssertTrue(GitWorktree.isValidName(good), good)
        }
        for bad in ["", "-x", ".hidden", "a..b", "a b", "a/b", "é", "x;rm"] {
            XCTAssertFalse(GitWorktree.isValidName(bad), bad)
        }
    }

    func testRepoRootFromSubdirectory() throws {
        let sub = (repo as NSString).appendingPathComponent("src")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        XCTAssertEqual(GitWorktree.repoRoot(containing: sub), repo)
        XCTAssertNil(GitWorktree.repoRoot(containing: sandbox.path))
    }

    func testEnsureCreatesWorktreeOnG8rBranchAndIsIdempotent() throws {
        let path = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        XCTAssertEqual(path, sandbox.appendingPathComponent("app-auth").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let head = try GitWorktree.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)
        XCTAssertEqual(head.output.trimmingCharacters(in: .whitespacesAndNewlines), "g8r/auth")

        XCTAssertEqual(try GitWorktree.ensure(delegate: "auth", repoRoot: repo), path)
        XCTAssertEqual(try GitWorktree.list(repoRoot: repo).count, 2)
    }

    func testEnsureBranchesFromTheGivenBase() throws {
        let first = try XCTUnwrap(GitWorktree.head(of: repo))
        let second = try GitWorktree.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
                                          "--allow-empty", "-m", "second"], in: repo)
        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertNotEqual(GitWorktree.head(of: repo), first)

        let path = try GitWorktree.ensure(delegate: "old", repoRoot: repo, base: first)
        XCTAssertEqual(GitWorktree.head(of: path), first)
        let fromHead = try GitWorktree.ensure(delegate: "new", repoRoot: repo, base: nil)
        XCTAssertEqual(GitWorktree.head(of: fromHead), GitWorktree.head(of: repo))
        XCTAssertEqual(try GitWorktree.ensure(delegate: "old", repoRoot: repo, base: "main"), path,
                       "an existing worktree is reused whatever the base")
        XCTAssertEqual(GitWorktree.head(of: path), first)
    }

    func testEnsureReusesSurvivingBranch() throws {
        let path = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        XCTAssertEqual(try GitWorktree.git(["worktree", "remove", path], in: repo).status, 0)
        XCTAssertEqual(try GitWorktree.ensure(delegate: "auth", repoRoot: repo), path)
    }

    func testEnsureRejectsBadNameAndOccupiedPath() throws {
        XCTAssertThrowsError(try GitWorktree.ensure(delegate: "a b", repoRoot: repo)) {
            XCTAssertEqual($0 as? GitWorktreeError, .invalidName("a b"))
        }
        let squatter = sandbox.appendingPathComponent("app-taken").path
        try FileManager.default.createDirectory(atPath: squatter, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitWorktree.ensure(delegate: "taken", repoRoot: repo)) {
            XCTAssertEqual($0 as? GitWorktreeError, .pathOccupied(squatter))
        }
    }

    func testEnsureOutsideRepoFails() {
        XCTAssertThrowsError(try GitWorktree.ensure(delegate: "x", repoRoot: sandbox.path)) {
            XCTAssertEqual($0 as? GitWorktreeError, .notARepository(sandbox.path))
        }
    }

    /// Seen live: the user deleted the worktree folders by hand; git kept
    /// them registered as "prunable".
    func testDeletedWorktreeFolderIsRecreatedOnItsBranch() throws {
        let path = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        try "work".write(toFile: path + "/done.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try GitWorktree.git(["add", "done.txt"], in: path).status, 0)
        XCTAssertEqual(try GitWorktree.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "work"], in: path).status, 0)
        try FileManager.default.removeItem(atPath: path)

        XCTAssertEqual(try GitWorktree.ensure(delegate: "auth", repoRoot: repo), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/done.txt"), "back on g8r/auth with its commits")
    }

    /// Seen live: `git init` without a commit gave delegates empty branches.
    func testRefusesARepoWithNoCommits() throws {
        let empty = sandbox.appendingPathComponent("empty").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        XCTAssertEqual(try GitWorktree.git(["init", "-q"], in: empty).status, 0)
        XCTAssertThrowsError(try GitWorktree.ensure(delegate: "auth", repoRoot: empty)) {
            XCTAssertEqual($0 as? GitWorktreeError, .noCommits(empty))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("empty-auth").path))
    }

    func testRemovalKeepsTheBranchAndRefusesDirty() throws {
        let clean = try GitWorktree.ensure(delegate: "clean", repoRoot: repo)
        let dirty = try GitWorktree.ensure(delegate: "dirty", repoRoot: repo)
        try "wip".write(toFile: dirty + "/wip.txt", atomically: true, encoding: .utf8)

        XCTAssertTrue(GitWorktree.remove(worktree: clean, repoRoot: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean))
        XCTAssertEqual(try GitWorktree.git(["rev-parse", "--verify", "--quiet", "refs/heads/g8r/clean"], in: repo).status, 0)

        XCTAssertFalse(GitWorktree.remove(worktree: dirty, repoRoot: repo), "uncommitted work: keep it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty + "/wip.txt"))
    }
}
