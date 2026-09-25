import XCTest
@testable import GaterCore

final class GitWorktreeTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gater-worktree-\(UUID().uuidString)")
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
        XCTAssertEqual(GitWorktree.branch(forDelegate: "auth"), "gater/auth")
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

    func testEnsureCreatesWorktreeOnGaterBranchAndIsIdempotent() throws {
        let path = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        XCTAssertEqual(path, sandbox.appendingPathComponent("app-auth").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let head = try GitWorktree.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)
        XCTAssertEqual(head.output.trimmingCharacters(in: .whitespacesAndNewlines), "gater/auth")

        XCTAssertEqual(try GitWorktree.ensure(delegate: "auth", repoRoot: repo), path)
        XCTAssertEqual(try GitWorktree.list(repoRoot: repo).count, 2)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/done.txt"), "back on gater/auth with its commits")
    }
}
