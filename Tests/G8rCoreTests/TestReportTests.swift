import XCTest
@testable import G8rCore

final class TestReportTests: XCTestCase {
    private let ranAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ output: String, exit: Int32 = 0) -> TestReport {
        TestReport.parse(output: output, command: "swift test", exit: exit, ranAt: ranAt)
    }

    /// An excerpt of this repo's own `swift test` log: XCTest cases, then
    /// swift-testing runs that found nothing to run.
    private let swiftTestLog = #"""
    Test Suite 'G8rTerminalTests.xctest' passed at 2026-09-29 15:45:55.386.
    	 Executed 27 tests, with 0 failures (0 unexpected) in 0.535 (0.536) seconds
    Test Suite 'All tests' passed at 2026-09-29 15:45:55.386.
    	 Executed 27 tests, with 0 failures (0 unexpected) in 0.535 (0.537) seconds
    Test Suite 'All tests' started at 2026-09-29 15:45:55.472.
    Test Suite 'G8rSymbolsTests.xctest' started at 2026-09-29 15:45:55.473.
    Test Suite 'ReferenceEngineTests' started at 2026-09-29 15:45:55.473.
    Test Case '-[G8rSymbolsTests.ReferenceEngineTests testFileCreatedAfterServerStartIsSeen]' started.
    Test Case '-[G8rSymbolsTests.ReferenceEngineTests testFileCreatedAfterServerStartIsSeen]' passed (2.928 seconds).
    Test Case '-[G8rSymbolsTests.ReferenceEngineTests testFindsCallersInTheOtherDelegatesWorktree]' started.
    Test Case '-[G8rSymbolsTests.ReferenceEngineTests testFindsCallersInTheOtherDelegatesWorktree]' passed (5.445 seconds).
    Test Case '-[G8rSymbolsTests.ReferenceEngineTests testMissingSymbolOrFile]' started.
    Test Case '-[G8rSymbolsTests.ReferenceEngineTests testMissingSymbolOrFile]' passed (0.272 seconds).
    Test Case '-[G8rCoreTests.JSONValueTests testDottedPathLookup]' started.
    Test Case '-[G8rCoreTests.JSONValueTests testDottedPathLookup]' passed (0.000 seconds).
    Test Case '-[G8rCoreTests.JSONValueTests testG8rEventRoundTrip]' started.
    Test Case '-[G8rCoreTests.JSONValueTests testG8rEventRoundTrip]' passed (0.000 seconds).
    Test Suite 'JSONValueTests' passed at 2026-09-29 15:46:31.330.
    	 Executed 3 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
    Test Suite 'G8rCoreTests.xctest' passed at 2026-09-29 15:46:31.330.
    	 Executed 44 tests, with 0 failures (0 unexpected) in 20.427 (20.433) seconds
    Test Suite 'All tests' passed at 2026-09-29 15:46:31.330.
    	 Executed 44 tests, with 0 failures (0 unexpected) in 20.427 (20.434) seconds
    ◇ Test run started.
    ↳ Testing Library Version: 2084
    ↳ Target Platform: arm64e-apple-macos14.0
    ✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
    ◇ Test run started.
    ↳ Testing Library Version: 2084
    ↳ Target Platform: arm64e-apple-macos14.0
    ✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
    """#

    /// `swift test` on a package with an XCTest case that fails and
    /// swift-testing tests in two suites, one of which fails.
    private let mixedLog = #"""
    Test Suite 'All tests' started at 2026-09-30 13:58:32.841.
    Test Suite 'LibTests.xctest' started at 2026-09-30 13:58:32.841.
    Test Suite 'OldTests' started at 2026-09-30 13:58:32.841.
    Test Case '-[LibTests.OldTests testBad]' started.
    /tmp/stsample/Tests/LibTests/MathTests.swift:14: error: -[LibTests.OldTests testBad] : XCTAssertEqual failed: ("1") is not equal to ("2")
    Test Case '-[LibTests.OldTests testBad]' failed (0.056 seconds).
    Test Case '-[LibTests.OldTests testOk]' started.
    Test Case '-[LibTests.OldTests testOk]' passed (0.000 seconds).
    Test Suite 'OldTests' failed at 2026-09-30 13:58:32.898.
    	 Executed 2 tests, with 1 failure (0 unexpected) in 0.057 (0.057) seconds
    Test Suite 'LibTests.xctest' failed at 2026-09-30 13:58:32.898.
    	 Executed 2 tests, with 1 failure (0 unexpected) in 0.057 (0.057) seconds
    Test Suite 'All tests' failed at 2026-09-30 13:58:32.898.
    	 Executed 2 tests, with 1 failure (0 unexpected) in 0.057 (0.057) seconds
    ◇ Test run started.
    ↳ Testing Library Version: 2084
    ↳ Target Platform: arm64e-apple-macos14.0
    ◇ Suite MathTests started.
    ◇ Test freeFunction() started.
    ◇ Suite OtherTests started.
    ◇ Test addsUp() started.
    ◇ Test other() started.
    ◇ Test "breaks on purpose" started.
    ✔ Test other() passed after 0.001 seconds.
    ✔ Test freeFunction() passed after 0.001 seconds.
    ✔ Suite OtherTests passed after 0.001 seconds.
    ✔ Test addsUp() passed after 0.001 seconds.
    ✘ Test "breaks on purpose" recorded an issue at MathTests.swift:6:48: Expectation failed: one() == 2
    ↳ one() == 2 → false
    ↳   one() → 1
    ✘ Test "breaks on purpose" failed after 0.001 seconds with 1 issue.
    ✘ Suite MathTests failed after 0.001 seconds with 1 issue.
    ✘ Test run with 4 tests in 2 suites failed after 0.001 seconds with 1 issue.
    Note: Some test targets reported failures:
      - LibTests (XCTest)
      - LibTests (Swift Testing)
    """#

    func testReadsXCTestFromThisReposLog() {
        let report = parse(swiftTestLog)
        XCTAssertEqual(report.cases.count, 5)
        XCTAssertEqual(report.passed, 5)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.cases.first,
                       TestCaseResult(suite: "ReferenceEngineTests", name: "testFileCreatedAfterServerStartIsSeen",
                                      passed: true))
        XCTAssertEqual(Set(report.cases.map(\.suite)), ["ReferenceEngineTests", "JSONValueTests"])
        XCTAssertEqual(report.command, "swift test")
        XCTAssertEqual(report.exit, 0)
        XCTAssertEqual(report.ranAt, "2026-09-21T14:13:20Z")
    }

    func testReadsXCTestAndSwiftTestingTogether() {
        let report = parse(mixedLog, exit: 1)
        XCTAssertEqual(report.cases, [
            TestCaseResult(suite: "OldTests", name: "testBad", passed: false),
            TestCaseResult(suite: "OldTests", name: "testOk", passed: true),
            TestCaseResult(suite: "", name: "other()", passed: true),
            TestCaseResult(suite: "", name: "freeFunction()", passed: true),
            TestCaseResult(suite: "", name: "addsUp()", passed: true),
            TestCaseResult(suite: "", name: #""breaks on purpose""#, passed: false),
        ])
    }

    func testReadsVerboseAndParameterizedSwiftTesting() {
        let report = parse("""
        ◇ Test "breaks on purpose" (aka 'breaks()') started.
        ✘ Test "breaks on purpose" (aka 'breaks()') recorded an issue at MathTests.swift:6:48: Expectation failed
        ✘ Test "breaks on purpose" (aka 'breaks()') failed after 0.001 seconds with 1 issue.
        ◇ Test sums(of:) started.
        ✔ Test sums(of:) with 3 test cases passed after 0.002 seconds.
        ➜ Test later() skipped.
        ✔ Test run with 2 tests in 1 suite passed after 0.003 seconds.
        """)
        XCTAssertEqual(report.cases, [
            TestCaseResult(suite: "", name: #""breaks on purpose" (aka 'breaks()')"#, passed: false),
            TestCaseResult(suite: "", name: "sums(of:)", passed: true),
        ])
    }

    func testReadsXCTestAsPrintedOffApplePlatforms() {
        let report = parse("""
        Test Case 'GlobTests.testPatterns' started at 2026-09-30 10:00:00.000
        Test Case 'GlobTests.testPatterns' passed (0.001 seconds)
        Test Case 'Mod.GlobTests.testEdges' failed (0.001 seconds)
        """)
        XCTAssertEqual(report.cases, [
            TestCaseResult(suite: "GlobTests", name: "testPatterns", passed: true),
            TestCaseResult(suite: "GlobTests", name: "testEdges", passed: false),
        ])
    }

    func testACaseThatStartedAndNeverFinishedFailed() {
        let report = parse("""
        Test Case '-[M.CrashTests testFine]' started.
        Test Case '-[M.CrashTests testFine]' passed (0.001 seconds).
        Test Case '-[M.CrashTests testCrashes]' started.
        Fatal error: Unexpectedly found nil
        ◇ Test hangs() started.
        """, exit: 134)
        XCTAssertEqual(report.cases, [
            TestCaseResult(suite: "CrashTests", name: "testFine", passed: true),
            TestCaseResult(suite: "CrashTests", name: "testCrashes", passed: false),
            TestCaseResult(suite: "", name: "hangs()", passed: false),
        ])
    }

    func testOutputInNeitherFormatHasNoCases() {
        let report = parse("PASS src/glob.test.ts\nTests: 4 passed, 4 total\n", exit: 0)
        XCTAssertEqual(report.cases, [])
        XCTAssertEqual(report.exit, 0)
    }

    func testReportRoundTripsAsJSON() throws {
        let report = parse(mixedLog, exit: 1)
        let decoded = try JSONDecoder().decode(TestReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["ranAt", "command", "exit", "cases"])
    }

    func testFunctionNamedByACase() {
        XCTAssertEqual(TestSources.function("testPatterns"), "testPatterns")
        XCTAssertEqual(TestSources.function("sums(of:)"), "sums")
        XCTAssertEqual(TestSources.function(#""named" (aka 'testNamed()')"#), "testNamed")
        XCTAssertNil(TestSources.function(#""named""#))
    }
}
