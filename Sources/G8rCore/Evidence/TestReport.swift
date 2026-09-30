import Foundation

/// One test case from a run.
public struct TestCaseResult: Codable, Equatable {
    /// The suite as the output names it, without its module: `GlobTests`.
    /// Empty when the output doesn't say, as swift-testing's doesn't.
    public var suite: String
    /// As the output prints it: `testPatterns`, `works()`, or
    /// `"named" (aka 'testNamed()')`.
    public var name: String
    public var passed: Bool

    public init(suite: String, name: String, passed: Bool) {
        self.suite = suite
        self.name = name
        self.passed = passed
    }
}

/// What a test run showed: the command, how it exited, and each test case
/// the output reported. Kept at `.g8r/tests.json` in the plan root.
public struct TestReport: Codable, Equatable {
    /// ISO 8601 in UTC.
    public var ranAt: String
    public var command: String
    public var exit: Int32
    public var cases: [TestCaseResult]

    public init(ranAt: String, command: String, exit: Int32, cases: [TestCaseResult]) {
        self.ranAt = ranAt
        self.command = command
        self.exit = exit
        self.cases = cases
    }

    public var passed: Int { cases.filter(\.passed).count }
    public var failed: Int { cases.filter { !$0.passed }.count }

    /// Reads XCTest's `Test Case '-[M.Suite name]' passed` lines (and the
    /// `'Suite.name'` form XCTest prints off Apple platforms) and
    /// swift-testing's `✔ Test name() passed after …` lines. A case that
    /// started and never finished, because the run crashed or was stopped,
    /// counts as failed. Output in neither format gives no cases, and only
    /// `exit` is known.
    public static func parse(output: String, command: String, exit: Int32, ranAt: Date) -> TestReport {
        var cases: [TestCaseResult] = []
        /// Cases started and not yet finished, by suite and name.
        var open: [String: (suite: String, name: String, count: Int)] = [:]
        var order: [String] = []

        for line in output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init) {
            guard let (suite, name, event) = xcTestCase(line) ?? swiftTestingCase(line) else { continue }
            let key = suite + "\n" + name
            switch event {
            case "started":
                if open[key] == nil { order.append(key) }
                open[key, default: (suite, name, 0)].count += 1
            case "passed", "failed":
                cases.append(TestCaseResult(suite: suite, name: name, passed: event == "passed"))
                if let pending = open[key], pending.count > 0 { open[key]?.count = pending.count - 1 }
            default:
                // Skipped: neither passed nor failed.
                if let pending = open[key], pending.count > 0 { open[key]?.count = pending.count - 1 }
            }
        }
        for key in order {
            guard let pending = open[key] else { continue }
            for _ in 0..<pending.count {
                cases.append(TestCaseResult(suite: pending.suite, name: pending.name, passed: false))
            }
        }
        return TestReport(ranAt: ISO8601DateFormatter().string(from: ranAt), command: command,
                          exit: exit, cases: cases)
    }

    // MARK: - Formats

    private static let xcTestObjC = try! NSRegularExpression(
        pattern: #"Test Case '-\[([^\s\]]+) ([^\]\s]+)\]' (started|passed|failed|skipped)\b"#)
    private static let xcTestPlain = try! NSRegularExpression(
        pattern: #"Test Case '([^'\s]+)\.([^'.\s]+)' (started|passed|failed|skipped)\b"#)

    /// `Test Case '-[G8rCoreTests.GlobTests testPatterns]' passed (0.002 seconds).`
    private static func xcTestCase(_ line: String) -> (String, String, String)? {
        guard line.contains("Test Case '") else { return nil }
        for regex in [xcTestObjC, xcTestPlain] {
            if let groups = match(regex, line) {
                let suite = groups[0].split(separator: ".").last.map(String.init) ?? groups[0]
                return (suite, groups[1], groups[2])
            }
        }
        return nil
    }

    /// A name is a function with its argument labels, `works()` or
    /// `run(with:)`, or a display name in quotes, followed in verbose
    /// output by the function it names. `Test run with 4 tests …` has
    /// neither shape, so the run's own summary is never a case.
    private static let swiftTesting = try! NSRegularExpression(pattern:
        #"^\S+ Test ("(?:[^"\\]|\\.)*"(?: \(aka '[^']*'\))?|[^\s"(]+\([^)]*\))"#
        + #"(?: with \d+ test cases?)? (started|passed|failed|skipped)\b"#)

    /// `✔ Test works() passed after 0.001 seconds.` swift-testing doesn't
    /// print the suite, so the suite is empty.
    private static func swiftTestingCase(_ line: String) -> (String, String, String)? {
        guard line.contains(" Test "), let groups = match(swiftTesting, line) else { return nil }
        return ("", groups[0], groups[1])
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        guard let found = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
