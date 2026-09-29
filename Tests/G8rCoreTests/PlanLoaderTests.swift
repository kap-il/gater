import XCTest
@testable import G8rCore

final class PlanLoaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-plans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func load(plans: [String] = G8rConfig.defaultPlans, extractor: PlanDocExtractor? = nil) -> PlanGraph {
        PlanLoader.load(planRoot: root.path, config: G8rConfig(plans: plans), extractor: extractor)
    }

    private func extractor(_ claude: StubClaude) -> PlanDocExtractor {
        PlanDocExtractor(cacheDirectory: PlanDocExtractor.cacheDirectory(planRoot: root.path), run: claude.run)
    }

    // MARK: - Finding the docs

    func testLoadsTheDocsThePlanNames() throws {
        try write("PLAN.md", "# The shop\n\n## till: Till\n\nTakes money.\n\n- Needs: stock\n")
        try write("plans/b.md", "# B\n\n## stock: Stock\n\nCounts things.\n\n## Retired\n\n### Ledger\n\nOn paper.\n")
        try write("plans/a.md", "## door: Door\n\nOpens.\n")
        try write("plans/notes.txt", "## txt: Not markdown\n")
        try write("plans/deep/c.md", "## deep: Too deep for plans/*.md\n")
        try write("elsewhere.md", "## elsewhere: Not named\n")

        let graph = load(plans: ["PLAN.md", "plans/*.md", "plans/a.md"])

        XCTAssertEqual(graph.docs, [
            PlanDocInfo(path: "PLAN.md", title: "The shop"),
            PlanDocInfo(path: "plans/a.md", title: "plans/a.md"),
            PlanDocInfo(path: "plans/b.md", title: "B"),
        ])
        XCTAssertEqual(graph.components.map(\.id), ["till", "door", "stock"])
        XCTAssertEqual(graph.components.map(\.doc), ["PLAN.md", "plans/a.md", "plans/b.md"])
        XCTAssertEqual(graph.retired, [RetiredComponent(name: "Ledger", why: "On paper.", doc: "plans/b.md", line: 9)])
        XCTAssertEqual(graph.problems, [])

        XCTAssertEqual(graph.component("stock")?.name, "Stock")
        XCTAssertNil(graph.component("ledger"))
    }

    func testLooksInTheUsualPlacesWhenNothingIsNamed() throws {
        try write("docs/plans/till.md", "## till: Till\n\nTakes money.\n")
        try write("plans/stock.md", "## stock: Stock\n\nCounts things.\n")
        try write("docs/other.md", "## other: Not a plan\n")

        let graph = load()

        XCTAssertEqual(graph.docs.map(\.path), ["plans/stock.md", "docs/plans/till.md"])
        XCTAssertEqual(graph.problems, [], "no PLAN.md is not a problem")
    }

    func testARepoWithNoPlanGivesAnEmptyGraph() {
        XCTAssertEqual(load(), PlanGraph(docs: [], components: [], retired: [], problems: []))
    }

    func testANamedDocThatIsMissingIsAProblem() throws {
        try write("PLAN.md", "## till: Till\n\nTakes money.\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.md"),
                                                withIntermediateDirectories: true)

        let graph = load(plans: ["PLAN.md", "PLANS.md", "specs/*.md", "folder.md"])

        XCTAssertEqual(graph.docs.map(\.path), ["PLAN.md"])
        XCTAssertEqual(graph.problems, ["no plan doc at PLANS.md", "no plan doc at specs/*.md",
                                        "no plan doc at folder.md"])
    }

    func testADoubleStarReachesEveryLevelButNotHiddenFolders() throws {
        try write("docs/a.md", "## a: A\n\nText.\n")
        try write("docs/x/y/b.md", "## b: B\n\nText.\n")
        try write("docs/.drafts/c.md", "## c: C\n\nText.\n")
        try write("d.md", "## d: D\n\nText.\n")

        XCTAssertEqual(load(plans: ["docs/**/*.md"]).components.map(\.id), ["a", "b"])
        XCTAssertEqual(load(plans: ["**/*.md"]).components.map(\.id), ["d", "a", "b"])
        XCTAssertEqual(load(plans: ["docs/.drafts/c.md"]).components.map(\.id), ["c"], "unless it is named")
    }

    // MARK: - Free-form docs

    func testAFreeFormDocGoesToTheExtractorOnce() throws {
        try write("PLAN.md", "## store: Store\n\nKeeps records.\n")
        try write("plans/importer.md", PlanDocExtractorTests.doc)
        let claude = StubClaude(output: StubClaude.realOutput)

        let first = load(plans: ["PLAN.md", "plans/*.md"], extractor: extractor(claude))

        XCTAssertEqual(claude.calls.count, 1, "the doc with component sections needs no model")
        XCTAssertEqual(claude.calls.first?.stdin, PlanDocExtractorTests.doc)
        XCTAssertEqual(first.components.map(\.id), ["store", "csv-reader", "loader"])
        XCTAssertEqual(first.component("loader")?.doc, "plans/importer.md")
        XCTAssertEqual(first.component("loader")?.needs, ["csv-reader"])
        XCTAssertEqual(first.docs.map(\.title), ["PLAN.md", "Notes on the importer"])
        XCTAssertEqual(first.problems, [])
        let cache = root.appendingPathComponent(".g8r/plans/\(PlanDocExtractorTests.docHash).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        let second = load(plans: ["PLAN.md", "plans/*.md"], extractor: extractor(claude))

        XCTAssertEqual(claude.calls.count, 1, "a second load of the same text runs no command")
        XCTAssertEqual(second, first)

        try write("plans/importer.md", PlanDocExtractorTests.doc + "\nAnd a report at the end.\n")
        _ = load(plans: ["PLAN.md", "plans/*.md"], extractor: extractor(claude))
        XCTAssertEqual(claude.calls.count, 2, "a changed doc is read again")
    }

    func testWithNoExtractorAFreeFormDocIsSkipped() throws {
        try write("PLAN.md", "## store: Store\n\nKeeps records.\n")
        try write("plans/importer.md", PlanDocExtractorTests.doc)

        let graph = load(plans: ["PLAN.md", "plans/*.md"])

        XCTAssertEqual(graph.components.map(\.id), ["store"])
        XCTAssertEqual(graph.docs.map(\.path), ["PLAN.md", "plans/importer.md"])
        XCTAssertEqual(graph.problems, [
            "plans/importer.md has no component sections and nothing to extract them with, so it was skipped",
        ])
    }

    func testAFailedExtractionIsAProblem() throws {
        try write("PLAN.md", "## store: Store\n\nKeeps records.\n")
        try write("plans/importer.md", PlanDocExtractorTests.doc)
        let claude = StubClaude(output: "Not logged in\n")
        claude.status = 1

        let graph = load(plans: ["PLAN.md", "plans/*.md"], extractor: extractor(claude))

        XCTAssertEqual(graph.components.map(\.id), ["store"], "the rest of the plan still loads")
        XCTAssertEqual(graph.problems, ["couldn't extract components from plans/importer.md: Not logged in"])
    }

    func testAnEmptyDocAsksNothing() throws {
        try write("PLAN.md", "\n  \n")
        let claude = StubClaude(output: StubClaude.realOutput)

        let graph = load(extractor: extractor(claude))

        XCTAssertEqual(claude.calls.count, 0)
        XCTAssertEqual(graph.components, [])
        XCTAssertEqual(graph.problems, [])
    }

    // MARK: - Problems

    func testADuplicateIdIsAProblemAndTheFirstIsKept() throws {
        try write("PLAN.md", "## till: Till\n\nThe first.\n\n## stock: Stock\n\nText.\n\n## till: Till again\n\nThe second.\n")
        try write("plans/more.md", "## stock: Stock, elsewhere\n\nText.\n")

        let graph = load(plans: ["PLAN.md", "plans/*.md"])

        XCTAssertEqual(graph.components.map(\.name), ["Till", "Stock"])
        XCTAssertEqual(graph.component("till")?.summary, "The first.")
        XCTAssertEqual(graph.problems, [
            "till is defined twice: at PLAN.md:1 and PLAN.md:9",
            "stock is defined twice: at PLAN.md:5 and plans/more.md:1",
        ])
    }

    func testANeedOrChangeThatNamesNothingIsAProblem() throws {
        try write("PLAN.md", """
            ## till: Till

            Takes money.

            - Needs: stock, bank
            - Changes: door, stock

            ## stock: Stock

            Counts things.
            """)

        let graph = load()

        XCTAssertEqual(graph.problems, ["till needs an unknown component: bank",
                                        "till changes an unknown component: door"])
        XCTAssertEqual(graph.component("till")?.needs, ["stock", "bank"], "the plan is kept as written")
    }

    func testACycleInNeedsIsAProblem() throws {
        try write("PLAN.md", """
            ## a: A
            - Needs: b

            ## b: B
            - Needs: c

            ## c: C
            - Needs: a, d

            ## d: D
            - Needs: e

            ## e: E
            - Changes: d

            ## selfish: Selfish
            - Needs: selfish
            """)

        let graph = load()

        XCTAssertEqual(graph.components.count, 6)
        XCTAssertEqual(graph.problems, ["these need each other, so none can be built first: a, b, c",
                                        "selfish needs itself"])
    }

    func testThisReposPlanHasNoProblems() {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let graph = PlanLoader.load(planRoot: repo.path, config: G8rConfig(plans: ["PLAN.md"]), extractor: nil)

        XCTAssertEqual(graph.docs, [PlanDocInfo(path: "PLAN.md", title: "g8r: the living map")])
        XCTAssertEqual(graph.problems, [])
        XCTAssertEqual(graph.component("codemap")?.needs, ["plandoc", "symbols", "swiftsymbols", "globs", "worktrees"])
        XCTAssertEqual(Set(graph.components.map(\.id)).count, graph.components.count)
    }
}
