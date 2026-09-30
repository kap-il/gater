import Foundation

/// Decides a built node's status from the last test run in the plan root:
/// `proven` when its tests ran and all passed, `failing` when any failed,
/// `unproven` when it has no tests or no run covers them. It never takes a
/// build session's word for it.
///
/// A test case belongs to the test file that declares its suite, and
/// through the file to the component codemap attributed the file to. A
/// case whose suite the output doesn't name, as swift-testing's doesn't,
/// belongs to the test file that declares its function.
public struct Evidence: MapStage {
    public init() {}

    public func apply(to map: inout LivingMap, context: MapContext) throws {
        let report = TestRunner.lastReport(planRoot: context.planRoot)
        if let report {
            map.tests = TestRunSummary(ranAt: report.ranAt, command: report.command,
                                       passed: report.passed, failed: report.failed, exit: report.exit)
        }

        let testFiles = Set(map.nodes.flatMap { $0.tests?.files ?? [] })
        let sources = TestSources(files: testFiles, codeRoot: context.codeRoot)
        /// The cases each test file holds.
        var casesIn: [String: [TestCaseResult]] = [:]
        for testCase in report?.cases ?? [] {
            for file in sources.files(holding: testCase) {
                casesIn[file, default: []].append(testCase)
            }
        }

        for index in map.nodes.indices {
            var node = map.nodes[index]
            let verdict = Self.verdict(for: node, report: report, casesIn: casesIn, sources: sources)
            if let counts = verdict.counts {
                node.tests?.passed = counts.passed
                node.tests?.failed = counts.failed
            }
            if node.status == .building || node.building == true {
                node.status = .building
            } else if node.status == .built {
                node.status = verdict.status
            }
            map.nodes[index] = node
        }
    }

    private struct Verdict {
        var status: NodeStatus
        var counts: (passed: Int, failed: Int)?
    }

    /// What the last run says about a node that has code.
    private static func verdict(for node: MapNode, report: TestReport?, casesIn: [String: [TestCaseResult]],
                                sources: TestSources) -> Verdict {
        guard let report, let tests = node.tests else { return Verdict(status: .unproven) }
        // Files with no test functions are helpers; there is nothing in them to run.
        let runnable = tests.files.filter { sources.testCount($0) > 0 }
        guard !runnable.isEmpty else { return Verdict(status: .unproven) }

        if report.cases.isEmpty {
            // The output said nothing about single tests; the exit status
            // speaks for all of them.
            return Verdict(status: report.exit == 0 ? .proven : .failing)
        }

        let cases = tests.files.flatMap { casesIn[$0] ?? [] }
        let passed = cases.filter(\.passed).count
        let failed = cases.count - passed
        let status: NodeStatus
        if failed > 0 {
            status = .failing
        } else if runnable.allSatisfy({ casesIn[$0]?.isEmpty == false }) {
            status = .proven
        } else {
            status = .unproven
        }
        return Verdict(status: status, counts: (passed, failed))
    }
}

/// The text of the map's test files, and which of them declares what.
struct TestSources {
    private var texts: [String: String] = [:]
    private let paths: [String]

    init(files: Set<String>, codeRoot: String) {
        paths = files.sorted()
        let root = URL(fileURLWithPath: codeRoot)
        for path in paths {
            texts[path] = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
    }

    func testCount(_ path: String) -> Int {
        CodeFiles.testCount(source: texts[path] ?? "", path: path)
    }

    /// The files a case belongs to: those declaring its suite, else those
    /// declaring its function. A name several files declare belongs to
    /// each of them, so a failure is never dropped for being ambiguous.
    func files(holding testCase: TestCaseResult) -> [String] {
        if !testCase.suite.isEmpty {
            let suite = NSRegularExpression.escapedPattern(for: testCase.suite)
            let declaring = matching(#"\b(?:class|struct|enum|actor|extension)\s+"# + suite + #"\b"#)
            if !declaring.isEmpty { return declaring }
        }
        if let function = Self.function(testCase.name) {
            return matching(#"\bfunc\s+"# + NSRegularExpression.escapedPattern(for: function) + #"\s*[(<]"#)
        }
        // A display name alone: the file whose `@Test` gives it.
        let display = NSRegularExpression.escapedPattern(for: testCase.name)
        return matching(#"@Test\s*\(\s*"# + display)
    }

    private func matching(_ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return paths.filter { path in
            guard let text = texts[path] else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// The function a case names: `testPatterns`, `works()` → `works`,
    /// `"named" (aka 'testNamed()')` → `testNamed`. Nil for a display name
    /// that doesn't say.
    static func function(_ name: String) -> String? {
        var name = name
        if name.hasPrefix("\"") {
            guard let aka = name.range(of: "(aka '") else { return nil }
            name = String(name[aka.upperBound...])
        }
        let base = name.prefix { $0 != "(" && $0 != "'" && $0 != " " }
        return base.isEmpty ? nil : String(base)
    }
}
