import XCTest
@testable import G8rCore

final class ProjectRootTests: XCTestCase {
    private var sandbox: String!
    /// Stands in for the home folder, so the walk up stops inside the sandbox.
    private var home: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = ProjectRoot.canonical(tmp.path)
        home = try folder("home")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: sandbox)
    }

    @discardableResult
    private func folder(_ relative: String) throws -> String {
        let path = (sandbox as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func touch(_ relative: String) throws {
        let path = (sandbox as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("# Plan\n".utf8).write(to: URL(fileURLWithPath: path))
    }

    private func gitInit(_ path: String) throws {
        let result = try GitWorktree.git(["init", "-q", "-b", "main"], in: path)
        XCTAssertEqual(result.status, 0, result.output)
    }

    private func resolve(_ path: String) -> String { ProjectRoot.resolve(path, home: home) }

    // MARK: - Resolution

    func testGitTopLevel() throws {
        let repo = try folder("home/code/app")
        try gitInit(repo)
        XCTAssertEqual(resolve(repo), repo)
    }

    func testSubfolderOfTheSameRepoKeepsTheRoot() throws {
        let repo = try folder("home/code/app")
        try gitInit(repo)
        // A plan doc deeper in the repo doesn't make a root of its own.
        try touch("home/code/app/src/lib/PLAN.md")
        XCTAssertEqual(resolve(try folder("home/code/app/src/lib")), repo)
        XCTAssertEqual(resolve(try folder("home/code/app/src/lib/deep")), repo)
    }

    func testPlanInAnAncestor() throws {
        try touch("home/notes/PLAN.md")
        XCTAssertEqual(resolve(try folder("home/notes/drafts/week1")), (sandbox as NSString).appendingPathComponent("home/notes"))
    }

    func testEveryMarkerCounts() throws {
        for (name, marker) in [("a", "plans/x.md"), ("b", "docs/plans/x.md"), ("c", "g8r.json"), ("d", "PLAN.md")] {
            try touch("home/\(name)/\(marker)")
            let root = (sandbox as NSString).appendingPathComponent("home/\(name)")
            XCTAssertEqual(resolve(try folder("home/\(name)/sub")), root, marker)
        }
    }

    func testNearestMarkerWins() throws {
        try touch("home/outer/PLAN.md")
        try touch("home/outer/inner/g8r.json")
        XCTAssertEqual(resolve(try folder("home/outer/inner/x")), (sandbox as NSString).appendingPathComponent("home/outer/inner"))
    }

    func testBareFolderIsItsOwnRoot() throws {
        let bare = try folder("home/scratch/stuff")
        XCTAssertEqual(resolve(bare), bare)
    }

    func testStopsAtHome() throws {
        // A plan in the home folder, or above it, isn't picked for a folder below.
        try touch("home/PLAN.md")
        try touch("PLAN.md")
        let bare = try folder("home/scratch")
        XCTAssertEqual(resolve(bare), bare)
        // Home itself is its own root.
        XCTAssertEqual(resolve(home), home)
    }

    func testHomeAsAGitRepoDoesNotSwallowEverything() throws {
        try gitInit(home)
        let bare = try folder("home/scratch")
        XCTAssertEqual(resolve(bare), bare)
    }

    func testSymlinkedFolderResolvesToTheRealPath() throws {
        let real = try folder("home/real")
        let link = (sandbox as NSString).appendingPathComponent("home/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertEqual(resolve(link), real)
        XCTAssertEqual(resolve(real + "/"), real)
    }

    // MARK: - Following

    func testFollowMovesTheRootAndRecordsIt() {
        let roots = ["/w/app/src": "/w/app", "/w/app": "/w/app", "/w/other": "/w/other"]
        let project = ProjectRoot(path: "/w/app") { roots[$0] ?? $0 }
        var seen: [G8rEvent] = []
        project.onChange = { seen.append($0) }

        XCTAssertNil(project.follow(folder: "/w/app/src", pane: "shell-1"), "a subfolder keeps the root")
        XCTAssertNil(project.follow(folder: "/w/app", pane: "shell-1"))
        XCTAssertEqual(project.path, "/w/app")
        XCTAssertTrue(seen.isEmpty)

        let event = project.follow(folder: "/w/other", pane: "shell-2")
        XCTAssertEqual(event?.kind, "root_changed")
        XCTAssertEqual(event?["from"]?.stringValue, "/w/app")
        XCTAssertEqual(event?["to"]?.stringValue, "/w/other")
        XCTAssertEqual(event?.pane, "shell-2")
        XCTAssertEqual(project.path, "/w/other")
        XCTAssertEqual(seen, [event!])

        // Back again: one more change, then nothing while it stays.
        XCTAssertEqual(project.follow(folder: "/w/app/src", pane: "shell-1")?["to"]?.stringValue, "/w/app")
        XCTAssertNil(project.follow(folder: "/w/app/src", pane: "shell-1"))
        XCTAssertEqual(seen.count, 2)
    }

    func testAnUnchangedFolderIsNotResolvedAgain() {
        var calls = 0
        let project = ProjectRoot(path: "/w/app") { calls += 1; return $0 == "/w/x" ? "/w/x" : "/w/app" }
        for _ in 0..<5 { project.follow(folder: "/w/app/src", pane: "shell-1") }
        XCTAssertEqual(calls, 1)
        project.follow(folder: "/w/x", pane: "shell-1")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(project.path, "/w/x")
    }
}
