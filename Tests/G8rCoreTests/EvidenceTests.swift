import XCTest
@testable import G8rCore

/// A scanner that reads nothing, so test files are attributed by name.
private struct NoScanner: SymbolScanning {
    func scan(source: String, path: String) -> FileScan? { nil }
}

final class EvidenceTests: XCTestCase {
    private var root: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-evidence-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("shop")
        logs = tmp.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let result = try GitWorktree.git(["init", "-q"], in: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        try writeShop()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Ledger has XCTest tests, auth swift-testing ones, pay XCTest tests
    /// again. Lab has code and no tests; later has no code; tools/ is code
    /// no plan mentions, with a test of its own.
    private func writeShop() throws {
        try write("PLAN.md", """
        # Shop

        ## ledger: Ledger

        Keeps the books.

        - Code: `src/ledger/`

        ## auth: Auth

        Checks people.

        - Code: `src/auth/`

        ## pay: Pay

        Takes money.

        - Code: `src/pay/`

        ## lab: Lab

        Tries things.

        - Code: `src/lab/`

        ## later: Later

        Not yet.

        - Code: `src/later/`
        """)
        try write("src/ledger/Ledger.swift", "struct Ledger {}\n")
        try write("src/auth/Auth.swift", "struct Auth {}\n")
        try write("src/pay/Pay.swift", "struct Pay {}\n")
        try write("src/lab/Lab.swift", "struct Lab {}\n")
        try write("tools/Gen.swift", "struct Gen {}\n")
        try write("Tests/LedgerTests.swift", """
        import XCTest
        final class LedgerTests: XCTestCase {
            func testPosts() {}
            func testBalances() {}
        }
        """)
        try write("Tests/AuthTests.swift", """
        import Testing
        @Suite struct AuthTests {
            @Test func logsIn() {}
            @Test("rejects a bad password") func rejects() {}
        }
        """)
        try write("Tests/PayTests.swift", """
        import XCTest
        final class PayTests: XCTestCase {
            func testCharges() {}
        }
        """)
        try write("Tests/GenTests.swift", """
        import XCTest
        final class GenTests: XCTestCase {
            func testGenerates() {}
        }
        """)
    }

    /// Runs a "test command" that prints `output` and exits with `exit`.
    private func runTests(_ output: String, exit: Int32) throws {
        let log = logs.appendingPathComponent("\(UUID().uuidString).log")
        try output.write(to: log, atomically: true, encoding: .utf8)
        _ = TestRunner.run(command: "cat '\(log.path)'; exit \(exit)", codeRoot: root.path, planRoot: root.path,
                           timeout: 60)
    }

    private func map() throws -> LivingMap {
        try LivingMapBuilder.build(planRoot: root.path, codeRoot: root.path, scanner: NoScanner(),
                                   stages: [Evidence()], extractor: nil)
    }

    private func status(_ map: LivingMap) -> [String: NodeStatus] {
        Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0.status) })
    }

    private let allPass = """
    Test Case '-[ShopTests.LedgerTests testPosts]' passed (0.001 seconds).
    Test Case '-[ShopTests.LedgerTests testBalances]' passed (0.001 seconds).
    Test Case '-[ShopTests.PayTests testCharges]' passed (0.001 seconds).
    Test Case '-[ShopTests.GenTests testGenerates]' passed (0.001 seconds).
    ✔ Test logsIn() passed after 0.001 seconds.
    ✔ Test "rejects a bad password" passed after 0.001 seconds.
    ✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
    """

    func testEachStatusFollowsWhatTheLastRunShowed() throws {
        try runTests("""
        Test Case '-[ShopTests.LedgerTests testPosts]' passed (0.001 seconds).
        Test Case '-[ShopTests.LedgerTests testBalances]' passed (0.001 seconds).
        Test Case '-[ShopTests.PayTests testCharges]' failed (0.001 seconds).
        Test Case '-[ShopTests.GenTests testGenerates]' passed (0.001 seconds).
        ✔ Test logsIn() passed after 0.001 seconds.
        ✔ Test "rejects a bad password" passed after 0.001 seconds.
        """, exit: 1)
        let map = try map()
        XCTAssertEqual(status(map), [
            "ledger": .proven, "auth": .proven, "pay": .failing, "lab": .unproven, "later": .planned,
            "unplanned:tools": .unplanned,
        ])
        XCTAssertEqual(map.node("ledger")?.tests, NodeTests(files: ["Tests/LedgerTests.swift"], count: 2,
                                                              passed: 2, failed: 0))
        XCTAssertEqual(map.node("auth")?.tests?.passed, 2)
        XCTAssertEqual(map.node("pay")?.tests?.failed, 1)
        XCTAssertEqual(map.node("unplanned:tools")?.tests?.passed, 1)
        XCTAssertNil(map.node("lab")?.tests)

        let summary = try XCTUnwrap(map.tests)
        XCTAssertEqual(summary.passed, 5)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.exit, 1)
        XCTAssertEqual(summary.command, TestRunner.lastReport(planRoot: root.path)?.command)
    }

    func testWithNoReportEveryBuiltNodeIsUnproven() throws {
        let map = try map()
        XCTAssertNil(map.tests)
        XCTAssertEqual(status(map), [
            "ledger": .unproven, "auth": .unproven, "pay": .unproven, "lab": .unproven, "later": .planned,
            "unplanned:tools": .unplanned,
        ])
        XCTAssertNil(map.node("ledger")?.tests?.passed)
    }

    func testRemovingATestFileTurnsProvenIntoUnproven() throws {
        try runTests(allPass, exit: 0)
        XCTAssertEqual(try map().node("ledger")?.status, .proven)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Tests/LedgerTests.swift"))
        let map = try map()
        XCTAssertEqual(map.node("ledger")?.status, .unproven)
        XCTAssertEqual(map.node("pay")?.status, .proven)
    }

    func testANodeWhoseTestsTheRunDidNotReachIsUnproven() throws {
        try runTests("""
        Test Case '-[ShopTests.LedgerTests testPosts]' passed (0.001 seconds).
        Test Case '-[ShopTests.LedgerTests testBalances]' passed (0.001 seconds).
        """, exit: 0)
        let map = try map()
        XCTAssertEqual(map.node("ledger")?.status, .proven)
        XCTAssertEqual(map.node("auth")?.status, .unproven)
        XCTAssertEqual(map.node("pay")?.status, .unproven)
        XCTAssertEqual(map.node("pay")?.tests?.passed, 0)
    }

    func testASwiftTestingFailureFailsTheFileThatDeclaresIt() throws {
        try runTests(allPass.replacingOccurrences(
            of: #"✔ Test "rejects a bad password" passed"#,
            with: #"✘ Test "rejects a bad password" (aka 'rejects()') failed"#), exit: 1)
        let map = try map()
        XCTAssertEqual(map.node("auth")?.status, .failing)
        XCTAssertEqual(map.node("auth")?.tests?.passed, 1)
        XCTAssertEqual(map.node("auth")?.tests?.failed, 1)
        XCTAssertEqual(map.node("ledger")?.status, .proven)
    }

    func testOutputInNeitherFormatLeavesItToTheExitStatus() throws {
        try runTests("all good\n", exit: 0)
        XCTAssertEqual(status(try map()), [
            "ledger": .proven, "auth": .proven, "pay": .proven, "lab": .unproven, "later": .planned,
            "unplanned:tools": .unplanned,
        ])

        try runTests("something broke\n", exit: 2)
        let map = try map()
        XCTAssertEqual(status(map), [
            "ledger": .failing, "auth": .failing, "pay": .failing, "lab": .unproven, "later": .planned,
            "unplanned:tools": .unplanned,
        ])
        XCTAssertEqual(map.tests?.exit, 2)
    }

    func testANodeBeingBuiltStaysBuilding() throws {
        struct Session: MapStage {
            func apply(to map: inout LivingMap, context: MapContext) throws {
                if let index = map.nodes.firstIndex(where: { $0.id == "ledger" }) {
                    map.nodes[index].building = true
                }
            }
        }
        try runTests(allPass, exit: 0)
        let map = try LivingMapBuilder.build(planRoot: root.path, codeRoot: root.path, scanner: NoScanner(),
                                             stages: [Session(), Evidence()], extractor: nil)
        XCTAssertEqual(map.node("ledger")?.status, .building)
        XCTAssertEqual(map.node("pay")?.status, .proven)
    }
}
