import XCTest
@testable import G8rCore

private struct NoScanner: SymbolScanning {
    func scan(source: String, path: String) -> FileScan? { nil }
}

final class TimelineTests: XCTestCase {
    private var root: URL!
    private var clock = 1_790_000_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func git(_ arguments: String...) throws {
        let result = try GitWorktree.git(["-c", "user.name=t", "-c", "user.email=t@t"] + arguments, in: root.path)
        XCTAssertEqual(result.status, 0, result.output)
    }

    /// Commits everything, one minute after the commit before.
    private func commit(_ subject: String) throws {
        clock += 60
        setenv("GIT_AUTHOR_DATE", "@\(clock) +0000", 1)
        setenv("GIT_COMMITTER_DATE", "@\(clock) +0000", 1)
        defer {
            unsetenv("GIT_AUTHOR_DATE")
            unsetenv("GIT_COMMITTER_DATE")
        }
        try git("add", "-A")
        try git("commit", "-qm", subject)
    }

    private func write(_ path: String, lines: Int) throws {
        try write(path, (0..<lines).map { "let x\($0) = \($0)\n" }.joined())
    }

    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    private func build() throws -> LivingMap {
        try LivingMapBuilder.build(planRoot: root.path, codeRoot: root.path, scanner: NoScanner(),
                                   stages: [Timeline()], extractor: nil)
    }

    private func writePlan() throws {
        try write("PLAN.md", """
        # Plan

        ## alpha: Alpha

        The first.

        - Code: `alpha/`

        ## beta: Beta

        The second.

        - Code: `beta/`

        ## gamma: Gamma

        Not built.

        - Code: `gamma/`
        """)
        try write("g8r.json", #"{"ignore": ["gen/**"]}"#)
    }

    /// Three commits: alpha with a file that the second commit deletes;
    /// then beta, a test and an ignored file; then an edit and a rename.
    private func writeThreeCommits() throws {
        try writePlan()
        try write("alpha/A.swift", lines: 3)
        try write("alpha/Old.swift", lines: 50)
        try commit("alpha")

        try remove("alpha/Old.swift")
        try write("beta/B.swift", lines: 4)
        try write("Tests/BetaTests.swift", lines: 20)
        try write("gen/Made.swift", lines: 30)
        try commit("beta")

        try write("alpha/A.swift", lines: 5)
        try remove("beta/B.swift")
        try write("beta/Renamed.swift", lines: 4)
        try commit("grow")
    }

    func testThreeCommitsReplayTheMapsGrowth() throws {
        try writeThreeCommits()
        let map = try build()

        XCTAssertEqual(map.timeline.map(\.subject), ["alpha", "beta", "grow"])
        XCTAssertEqual(map.timeline.map(\.t), [1_790_000_060, 1_790_000_120, 1_790_000_180])
        XCTAssertEqual(map.timeline.last?.sha, map.head)

        // Only alpha, and not the file the second commit deleted.
        XCTAssertEqual(map.timeline[0].loc, ["alpha": 3])
        // Neither the test file nor the ignored file counts.
        XCTAssertEqual(map.timeline[1].loc, ["alpha": 3])
        // The renamed file is on the map only under its new name.
        XCTAssertEqual(map.timeline[2].loc, ["alpha": 5, "beta": 4])

        let last = try XCTUnwrap(map.timeline.last)
        for node in map.nodes where node.loc > 0 {
            XCTAssertEqual(last.loc[node.id], node.loc, node.id)
        }
        XCTAssertNil(last.loc["gamma"])
    }

    func testEachNodeGetsItsCommitsAndItsFirstAndLast() throws {
        try writeThreeCommits()
        let map = try build()

        let alpha = try XCTUnwrap(map.node("alpha")?.git)
        XCTAssertEqual(alpha.commits, 2)
        XCTAssertEqual(alpha.first?.subject, "alpha")
        XCTAssertEqual(alpha.last?.subject, "grow")
        XCTAssertEqual(alpha.last?.sha, map.head)
        XCTAssertEqual(alpha.first?.t, 1_790_000_060)

        // beta/B.swift is gone; only the commit that added Renamed.swift counts.
        let beta = try XCTUnwrap(map.node("beta")?.git)
        XCTAssertEqual(beta.commits, 1)
        XCTAssertEqual(beta.first?.subject, "grow")

        XCTAssertEqual(map.node("gamma")?.git, NodeGit(commits: 0, first: nil, last: nil))
    }

    func testMergesFollowTheFirstParentAndAreNotCountedAsCommits() throws {
        try writePlan()
        try write("alpha/A.swift", lines: 2)
        try commit("start")

        try git("checkout", "-qb", "side")
        try write("beta/B.swift", lines: 6)
        try commit("side beta")
        try write("beta/B.swift", lines: 7)
        try commit("side more")

        try git("checkout", "-q", "main")
        try write("alpha/A.swift", lines: 4)
        try commit("main alpha")
        clock += 60
        setenv("GIT_COMMITTER_DATE", "@\(clock) +0000", 1)
        setenv("GIT_AUTHOR_DATE", "@\(clock) +0000", 1)
        defer {
            unsetenv("GIT_AUTHOR_DATE")
            unsetenv("GIT_COMMITTER_DATE")
        }
        try git("merge", "-q", "--no-ff", "side", "-m", "merge side")

        let map = try build()
        XCTAssertEqual(map.timeline.map(\.subject), ["start", "main alpha", "merge side"])
        XCTAssertEqual(map.timeline.map(\.loc), [["alpha": 2], ["alpha": 4], ["alpha": 4, "beta": 7]])

        let beta = try XCTUnwrap(map.node("beta")?.git)
        XCTAssertEqual(beta.commits, 2)
        XCTAssertEqual(beta.first?.subject, "side beta")
        XCTAssertEqual(beta.last?.subject, "side more")
        XCTAssertEqual(map.node("alpha")?.git?.commits, 2)
    }

    func testARepoWithNoCommitsHasAnEmptyTimeline() throws {
        try writePlan()
        try write("alpha/A.swift", lines: 3)
        let map = try build()

        XCTAssertEqual(map.timeline, [])
        XCTAssertEqual(map.node("alpha")?.loc, 3)
        XCTAssertEqual(map.node("alpha")?.git, NodeGit(commits: 0, first: nil, last: nil))
    }

    func testParsesPathsWithSpacesAndTabsAndSkipsBinaryFiles() {
        let output = "\u{1E}aaa \u{1F}100\u{1F}first | second\0\n2\t0\tx y.swift\0-\t-\tlogo.png\0"
            + "\u{1E}bbb aaa\u{1F}160\u{1F}tab\0\n1\t1\ttab\tname.swift\0"
            + "\u{1E}ccc bbb\u{1F}220\u{1F}empty\0"
        let commits = Timeline.parse(output)
        XCTAssertEqual(commits.map(\.sha), ["aaa", "bbb", "ccc"])
        XCTAssertEqual(commits.map(\.parents), [[], ["aaa"], ["bbb"]])
        XCTAssertEqual(commits[0].subject, "first | second")
        XCTAssertEqual(commits[0].changes.map(\.path), ["x y.swift"])
        XCTAssertEqual(commits[1].changes.map(\.path), ["tab\tname.swift"])
        XCTAssertEqual(commits[1].changes.first?.removed, 1)
        XCTAssertTrue(commits[2].changes.isEmpty)
    }
}
