import XCTest
@testable import G8rCore

final class PromptComposerTests: XCTestCase {
    private var shop: BuildFixture!

    override func setUpWithError() throws { shop = try BuildFixture() }
    override func tearDownWithError() throws { shop.remove() }

    func testThePromptHasTheSectionDoneWhenSignaturesAndSixRules() throws {
        let map = try shop.map(stages: [])
        let interfaces = BuildInterfaces.at(commit: "HEAD", repoRoot: shop.repo, map: map, needs: ["store"],
                                            scanner: BuildStubScanner())
        let prompt = PromptComposer.prompt(for: "cart", in: map, interfaces: interfaces, base: "abc1234")

        let section = try XCTUnwrap(map.node("cart")?.section)
        XCTAssertTrue(prompt.contains(section.text), "the section, verbatim")
        XCTAssertTrue(prompt.contains("cart: Cart"))
        XCTAssertTrue(prompt.contains("`src/cart/`"), "where its code goes")
        XCTAssertTrue(prompt.contains("## Done when\n\na cart can be saved to the store."))
        XCTAssertTrue(prompt.contains("### store: Store"))
        XCTAssertTrue(prompt.contains("public func save(_ key: String, value: String) -> Bool"))
        XCTAssertTrue(prompt.contains("public struct Store {"))
        XCTAssertFalse(prompt.contains("secret"), "only what it exports")
        XCTAssertTrue(prompt.contains("`store` (Store): used by cart, unplanned:src/checkout"), prompt)
        XCTAssertTrue(prompt.contains("abc1234"))

        let rules = PromptComposer.rules(for: "cart")
        XCTAssertEqual(rules.count, 6)
        for (index, rule) in rules.enumerated() {
            XCTAssertTrue(prompt.contains("\(index + 1). \(rule)"), rule)
        }
        let all = rules.joined(separator: "\n")
        for phrase in ["Stay in this worktree", "Commit to this branch, `g8r/cart`", "`G8r-Component: cart`",
                       "starting `Assumed:`", "Stop when the done-when holds"] {
            XCTAssertTrue(all.contains(phrase), phrase)
        }
    }

    func testANodeWithoutNeedsOrChangesSaysSo() throws {
        let map = LivingMap(repo: "r", head: nil, generated: "", docs: [], nodes: [
            MapNode(id: "solo", name: "Solo", summary: "Alone.", status: .planned),
        ], edges: [], retired: [], problems: [])
        let prompt = PromptComposer.prompt(for: "solo", in: map, interfaces: [:], base: "b")
        XCTAssertTrue(prompt.contains("Nothing: it stands on its own."))
        XCTAssertTrue(prompt.contains("Nothing that exists: it only adds code."))
        XCTAssertTrue(prompt.contains("The plan gives no done-when"))
        XCTAssertEqual(PromptComposer.prompt(for: "missing", in: map, interfaces: [:], base: "b"), "")
    }

    func testANeedWithNoSignaturesSaysSo() throws {
        let map = try shop.map(stages: [])
        let prompt = PromptComposer.prompt(for: "cart", in: map, interfaces: [:], base: "b")
        XCTAssertTrue(prompt.contains("No exported signatures were found"))
    }
}

final class BuildChecksTests: XCTestCase {

    private func runner(_ answers: [String: (Int32, String)], calls: UnsafeMutablePointer<[String]>) -> CommandRunner {
        { executable, arguments, _ in
            let line = ([executable] + arguments).joined(separator: " ")
            calls.pointee.append(line)
            return answers.first { line.hasSuffix($0.key) }?.value ?? (0, "")
        }
    }

    private func check(_ answers: [String: (Int32, String)], config: G8rConfig) -> (BuildChecks.Result, [String]) {
        var calls: [String] = []
        let result = withUnsafeMutablePointer(to: &calls) {
            BuildChecks.run(worktree: "/w", config: config, run: runner(answers, calls: $0))
        }
        return (result, calls)
    }

    private let both = G8rConfig(buildCommand: "swift build", testCommand: "swift test")

    func testAllPass() {
        let (result, calls) = check([:], config: both)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(calls, ["git status --porcelain --untracked-files=all",
                               "/bin/sh -c swift build", "/bin/sh -c swift test"])
        XCTAssertTrue(result.tail.contains("nothing uncommitted"))
    }

    func testUncommittedWorkFailsBeforeAnythingRuns() {
        let (result, calls) = check(["--untracked-files=all": (0, "?? Sources/New.swift\n M PLAN.md\n")], config: both)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.tail.hasPrefix("Uncommitted changes:"))
        XCTAssertTrue(result.tail.contains("?? Sources/New.swift"))
        XCTAssertEqual(calls.count, 1)
    }

    func testAFailingBuildSkipsTheTests() {
        let (result, calls) = check(["swift build": (1, "compiling\nerror: nope")], config: both)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.tail.hasPrefix("build_command `swift build` failed:"))
        XCTAssertTrue(result.tail.contains("error: nope"))
        XCTAssertEqual(calls.count, 2)
    }

    func testFailingTestsKeepOnlyTheTail() {
        let output = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let (result, _) = check(["swift test": (1, output)], config: both)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.tail.contains("line 100"))
        XCTAssertFalse(result.tail.contains("line 50\n"))
    }

    func testUnconfiguredCommandsPass() {
        let (result, calls) = check([:], config: G8rConfig())
        XCTAssertTrue(result.passed)
        XCTAssertEqual(calls.count, 1)
    }

    func testARunnerThatThrowsFails() {
        let result = BuildChecks.run(worktree: "/w", config: both) { _, _, _ in
            throw ProcessRunner.RunnerError.couldNotStart("no git")
        }
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.tail.contains("no git"))
    }
}

final class BuildNotesTests: XCTestCase {
    private var shop: BuildFixture!

    override func setUpWithError() throws { shop = try BuildFixture() }
    override func tearDownWithError() throws { shop.remove() }

    func testParsesTrailersAndAssumptions() {
        let parsed = BuildNotes.parse(message: """
        Build cart

        Assumed: prices are in cents.
        Assumed: one cart per person.
        Not an assumption.

        g8r-component: cart
        """)
        XCTAssertEqual(parsed.components, ["cart"])
        XCTAssertEqual(parsed.assumed, ["Assumed: prices are in cents.", "Assumed: one cart per person."])
    }

    func testOpenSessionsEndOnMergeOrPaneClosed() {
        func event(_ kind: String, _ fields: [String: String]) -> G8rEvent {
            G8rEvent(kind: kind, extra: fields.mapValues { .string($0) })
        }
        let events = [
            event("build_started", ["component": "a", "pane": "build-a"]),
            event("build_started", ["component": "b", "pane": "build-b"]),
            event("build_started", ["component": "c", "pane": "build-c"]),
            event("build_needs_human", ["component": "a", "reason": "x"]),
            event("build_merged", ["component": "b", "commit": "abc"]),
            event("pane_closed", ["pane": "build-c"]),
        ]
        XCTAssertEqual(BuildNotes.openSessions(in: events), ["a": "build-a"])
    }

    func testSetsPromptsNotesAndBuilding() throws {
        // A session for pay that assumed something, on its own branch.
        let worktree = try GitWorktree.ensure(delegate: "pay", repoRoot: shop.repo)
        try shop.write("src/pay/Pay.swift", "struct Pay {}\n", in: worktree)
        try shop.git("add", ".", in: worktree)
        try shop.git("commit", "-qm", "Pay", "-m", "Assumed: cards only.\nAssumed: cards only.", "-m",
                     "G8r-Component: pay", in: worktree)
        try shop.write(".g8r/events.jsonl", """
        {"kind":"build_started","component":"cart","pane":"build-cart"}

        """)

        let map = try shop.map(stages: [BuildNotes(), Evidence()])
        let cart = try XCTUnwrap(map.node("cart"))
        XCTAssertEqual(cart.building, true)
        XCTAssertEqual(cart.status, .building, "evidence keeps it")
        XCTAssertTrue(cart.prompt?.contains("public func save") == true, "signatures from the map's scans")
        XCTAssertTrue(cart.prompt?.contains(GitWorktree.head(of: shop.repo) ?? "-") == true)

        let pay = try XCTUnwrap(map.node("pay"))
        XCTAssertEqual(pay.notes, ["Assumed: cards only."], "read from g8r/* branches, each once")
        XCTAssertNil(pay.building)
        XCTAssertNotNil(pay.prompt)

        let store = try XCTUnwrap(map.node("store"))
        XCTAssertNil(store.prompt, "only planned nodes get one")
        XCTAssertNil(store.notes)
    }
}
