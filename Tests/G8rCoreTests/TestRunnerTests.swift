import XCTest
@testable import G8rCore

final class TestRunnerTests: XCTestCase {
    private var sandbox: URL!
    private var planRoot: String!
    private var codeRoot: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        planRoot = sandbox.appendingPathComponent("plan").path
        codeRoot = sandbox.appendingPathComponent("code").path
        try FileManager.default.createDirectory(atPath: planRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: codeRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    private func run(_ command: String, timeout: TimeInterval = 60) -> TestReport {
        TestRunner.run(command: command, codeRoot: codeRoot, planRoot: planRoot, timeout: timeout)
    }

    func testKeepsTheLogTheReportAndAnEventInThePlanRoot() throws {
        XCTAssertNil(TestRunner.lastReport(planRoot: planRoot))
        let report = run("""
        pwd
        echo "Test Case '-[M.GlobTests testPatterns]' passed (0.001 seconds)."
        echo "Test Case '-[M.GlobTests testEdges]' failed (0.001 seconds)."
        exit 3
        """)
        XCTAssertEqual(report.exit, 3)
        XCTAssertEqual(report.passed, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(TestRunner.lastReport(planRoot: planRoot), report)

        let log = try String(contentsOfFile: planRoot + "/.g8r/test.log", encoding: .utf8)
        XCTAssertTrue(log.hasPrefix(codeRoot + "\n"), "runs in the code root: \(log)")
        XCTAssertTrue(log.contains("testEdges]' failed"))

        let events = try EventLog.replay(path: URL(fileURLWithPath: planRoot + "/.g8r/events.jsonl"))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, "tests_ran")
        XCTAssertEqual(events[0]["passed"], .number(1))
        XCTAssertEqual(events[0]["failed"], .number(1))
        XCTAssertEqual(events[0]["exit"], .number(3))
        XCTAssertEqual(events[0]["command"]?.stringValue, report.command)
    }

    func testACommandThatSleepsSilentlyIsStoppedAtTheTimeout() {
        let started = Date()
        let report = run("sleep 30", timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertNotEqual(report.exit, 0)
        let log = (try? String(contentsOfFile: planRoot + "/.g8r/test.log", encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("stopped the tests after 1 seconds"), log)
    }

    func testACommandThatGoesQuietIsStoppedWithWhatItStartedAndKeepsItsOutput() {
        let started = Date()
        let report = run("""
        echo "Test Case '-[M.SlowTests testFine]' passed (0.001 seconds)."
        echo "Test Case '-[M.SlowTests testHangs]' started."
        sleep 30
        echo never
        """, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertNotEqual(report.exit, 0)
        XCTAssertEqual(report.cases, [
            TestCaseResult(suite: "SlowTests", name: "testFine", passed: true),
            TestCaseResult(suite: "SlowTests", name: "testHangs", passed: false),
        ])
        let log = (try? String(contentsOfFile: planRoot + "/.g8r/test.log", encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("never"))
    }

    func testSomethingLeftRunningInTheBackgroundDoesNotHoldTheRun() {
        let started = Date()
        let report = run("(sleep 30 &); echo done", timeout: 60)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(report.exit, 0)
    }
}
