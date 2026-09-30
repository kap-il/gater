import XCTest
import G8rCore
@testable import G8rSymbols

final class StandardMapTests: XCTestCase {
    private var parent: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-standard-\(UUID().uuidString)")
        repo = parent.appendingPathComponent("shop")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: parent) }

    private func git(_ arguments: String..., in directory: URL? = nil) throws {
        let result = try GitWorktree.git(["-c", "user.name=t", "-c", "user.email=t@t"] + arguments,
                                         in: (directory ?? repo).path)
        XCTAssertEqual(result.status, 0, result.output)
    }

    private func write(_ path: String, _ text: String, in directory: URL? = nil) throws {
        let file = (directory ?? repo).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testScannerReadsTopLevelNamesAndUses() throws {
        let scan = try XCTUnwrap(TreeSitterScanner().scan(source: """
        public struct Ledger {
            func add(_ amount: Int) { total(amount) }
        }
        func total(_ x: Int) -> Int { Ledger().hashValue + x }
        """, path: "Sources/Shop/Ledger.swift"))

        let top = scan.declarations.filter(\.topLevel)
        XCTAssertEqual(Set(top.map(\.name)), ["Ledger", "total"])
        XCTAssertTrue(scan.declarations.contains { $0.name == "Ledger.add" && !$0.topLevel })
        XCTAssertTrue(top.first { $0.name == "Ledger" }?.exported == true)
        XCTAssertGreaterThan(scan.uses["Ledger"] ?? 0, 0)
        XCTAssertNil(TreeSitterScanner().scan(source: "hello", path: "notes.txt"))
    }

    func testMainSwiftVariablesAreNotDeclarations() throws {
        let scan = try XCTUnwrap(TreeSitterScanner().scan(source: "let path = \"x\"\nfunc usage() {}\n",
                                                          path: "Sources/tool/main.swift"))
        XCTAssertEqual(scan.declarations.map(\.name), ["usage"])
    }

    func testMeasuresThePlanRootUntilThereIsAnIntegrationWorktree() throws {
        try write("PLAN.md", "## ledger: Ledger\n\nKeeps count.\n\n- Code: `Sources/`\n")
        try write("Sources/Ledger.swift", "struct Ledger {}\n")
        try git("add", "-A")
        try git("commit", "-qm", "start")

        var map = try StandardMap.build(planRoot: repo.path)
        XCTAssertEqual(map.node("ledger")?.files.map(\.path), ["Sources/Ledger.swift"])
        XCTAssertEqual(map.repo, "shop")

        let integration = try Integrator(repoRoot: repo.path).ensureWorktree()
        try write("Sources/Merged.swift", "struct Merged {}\n", in: URL(fileURLWithPath: integration))
        map = try StandardMap.build(planRoot: repo.path)
        XCTAssertEqual(map.node("ledger")?.files.map(\.path), ["Sources/Ledger.swift", "Sources/Merged.swift"])

        map = try StandardMap.build(planRoot: repo.path, codeRoot: repo.path)
        XCTAssertEqual(map.node("ledger")?.files.map(\.path), ["Sources/Ledger.swift"])
    }

    func testAFreeFormDocIsOnlyReadFromTheCacheUnlessAsked() throws {
        try write("PLAN.md", "# Notes\n\nWe should have a ledger someday.\n")
        let map = try StandardMap.build(planRoot: repo.path)
        XCTAssertEqual(map.nodes, [])
        XCTAssertEqual(map.problems.count, 1)
        XCTAssertTrue(map.problems[0].contains("hasn't been read by a model"), map.problems[0])
    }
}
