import XCTest
@testable import G8rCore

/// Stands in for the `claude` command: records what it was asked and
/// prints what the test tells it to. No process is started.
final class StubClaude {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var stdin: String?
    }

    var calls: [Call] = []
    var status: Int32 = 0
    var output: String

    init(output: String) {
        self.output = output
    }

    var run: CommandRunner {
        { executable, arguments, stdin in
            self.calls.append(Call(executable: executable, arguments: arguments, stdin: stdin))
            return (self.status, self.output)
        }
    }

    /// What `claude -p --output-format json --json-schema …` printed for
    /// `PlanDocExtractorTests.doc` (Claude Code 2.1.285), less the fields
    /// about timing and cost.
    static let realOutput = #"""
        {"stop_reason":"tool_use","session_id":"93f412f7-9a61-4b1f-a992-b20238ec36ff","total_cost_usd":0.57864,"permission_denials":[],"terminal_reason":"completed","is_error":false,"num_turns":2,"subtype":"success","api_error_status":null,"result":"{\"components\":[{\"id\":\"csv-reader\",\"name\":\"CSV reader\",\"summary\":\"A CSV reader that turns rows into records.\",\"heading\":\"Notes on the importer\",\"paths\":[\"src/csv/\"],\"needs\":[],\"changes\":[]},{\"id\":\"loader\",\"name\":\"The loader\",\"summary\":\"A loader that writes the records produced by the reader to the database.\",\"heading\":\"The loader\",\"paths\":[\"src/load.py\"],\"needs\":[\"csv-reader\"],\"changes\":[],\"doneWhen\":\"A thousand-row file loads in under a second.\"}]}","structured_output":{"components":[{"id":"csv-reader","name":"CSV reader","summary":"A CSV reader that turns rows into records.","heading":"Notes on the importer","paths":["src/csv/"],"needs":[],"changes":[]},{"id":"loader","name":"The loader","summary":"A loader that writes the records produced by the reader to the database.","heading":"The loader","paths":["src/load.py"],"needs":["csv-reader"],"changes":[],"doneWhen":"A thousand-row file loads in under a second."}]},"type":"result","uuid":"96e2aa9d-ffb2-4361-9736-eb8f9ea8a730"}
        """#

    /// A result in the same shape, holding the given components.
    static func output(components: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"components":["#
            + components + "]}}"
    }
}

final class PlanDocExtractorTests: XCTestCase {
    static let doc = """
        # Notes on the importer

        We need a CSV reader that turns rows into records. It lives in src/csv/.

        ## The loader

        Then a loader that writes those records to the database, in src/load.py. It depends on the reader. \
        It is finished when a thousand-row file loads in under a second.

        """
    static let docHash = "99dc09546dfafc90a10f63304960c77790b9e9a0e82c40f277fa642dbf54072d"

    private var sandbox: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        cache = sandbox.appendingPathComponent(".g8r/plans")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    private func cached() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).sorted()
    }

    func testAsksClaudeForTheComponentsOfTheDoc() throws {
        let claude = StubClaude(output: StubClaude.realOutput)
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)

        let components = try extractor.extract(text: Self.doc, doc: "NOTES.md")

        XCTAssertEqual(claude.calls.count, 1)
        let call = try XCTUnwrap(claude.calls.first)
        XCTAssertEqual(call.executable, "claude")
        XCTAssertEqual(call.arguments, ["-p", PlanDocExtractor.prompt, "--output-format", "json",
                                        "--json-schema", PlanDocExtractor.schema])
        XCTAssertEqual(call.stdin, Self.doc, "the doc goes in on standard input")

        XCTAssertEqual(components, [
            PlanComponent(
                id: "csv-reader", name: "CSV reader", summary: "A CSV reader that turns rows into records.",
                doc: "NOTES.md", line: 1, heading: "Notes on the importer",
                text: Self.doc.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                paths: ["src/csv/"], needs: [], changes: [], doneWhen: nil),
            PlanComponent(
                id: "loader", name: "The loader",
                summary: "A loader that writes the records produced by the reader to the database.",
                doc: "NOTES.md", line: 5, heading: "The loader",
                text: "Then a loader that writes those records to the database, in src/load.py. "
                    + "It depends on the reader. It is finished when a thousand-row file loads in under a second.",
                paths: ["src/load.py"], needs: ["csv-reader"], changes: [],
                doneWhen: "A thousand-row file loads in under a second."),
        ])
    }

    func testTheSchemaNamesEveryFieldOfTheAnswer() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(PlanDocExtractor.schema.utf8))
        let component = try XCTUnwrap(schema.value(atPath: "properties.components.items"))
        let fields = try XCTUnwrap(component.value(atPath: "properties")?.objectValue)
        XCTAssertEqual(fields.keys.sorted(),
                       ["changes", "doneWhen", "heading", "id", "name", "needs", "paths", "summary"])
        let required = try XCTUnwrap(component.value(atPath: "required")?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(required.sorted(), ["changes", "heading", "id", "name", "needs", "paths", "summary"])
    }

    func testASecondReadOfTheSameTextRunsNoCommand() throws {
        let claude = StubClaude(output: StubClaude.realOutput)
        let first = try PlanDocExtractor(cacheDirectory: cache, run: claude.run)
            .extract(text: Self.doc, doc: "NOTES.md")
        XCTAssertEqual(cached(), [Self.docHash + ".json"], "kept under the SHA-256 of the text")

        // A new extractor, as after a restart: only the file carries over.
        claude.output = "nothing a second run could use"
        let second = try PlanDocExtractor(cacheDirectory: cache, run: claude.run)
            .extract(text: Self.doc, doc: "NOTES.md")

        XCTAssertEqual(claude.calls.count, 1)
        XCTAssertEqual(second, first)
    }

    func testAChangedDocIsReadAgain() throws {
        let claude = StubClaude(output: StubClaude.realOutput)
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)
        _ = try extractor.extract(text: Self.doc, doc: "NOTES.md")
        _ = try extractor.extract(text: Self.doc + "\nOne more thought.\n", doc: "NOTES.md")

        XCTAssertEqual(claude.calls.count, 2)
        XCTAssertEqual(claude.calls.last?.stdin, Self.doc + "\nOne more thought.\n")
        XCTAssertEqual(cached().count, 2)
    }

    func testTheSameTextAtAnotherPathIsNotReadAgain() throws {
        let claude = StubClaude(output: StubClaude.realOutput)
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)
        _ = try extractor.extract(text: Self.doc, doc: "NOTES.md")
        let moved = try extractor.extract(text: Self.doc, doc: "docs/plans/importer.md")

        XCTAssertEqual(claude.calls.count, 1)
        XCTAssertEqual(moved.map(\.doc), ["docs/plans/importer.md", "docs/plans/importer.md"])
    }

    func testAFailedRunThrowsAndIsNotKept() throws {
        let claude = StubClaude(output: "claude: command not found\n")
        claude.status = 127
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)

        XCTAssertThrowsError(try extractor.extract(text: Self.doc, doc: "NOTES.md")) { error in
            XCTAssertEqual(error as? PlanDocExtractor.ExtractorError, .failed("claude: command not found"))
        }
        XCTAssertEqual(cached(), [])

        // Once the command works, the same text is asked about again.
        claude.status = 0
        claude.output = StubClaude.realOutput
        XCTAssertEqual(try extractor.extract(text: Self.doc, doc: "NOTES.md").map(\.id), ["csv-reader", "loader"])
        XCTAssertEqual(claude.calls.count, 2)
    }

    func testAnErrorClaudeReportsThrowsAndIsNotKept() throws {
        let claude = StubClaude(output: #"{"type":"result","subtype":"success","is_error":true,"#
            + #""result":"Invalid API key · Please run /login"}"#)
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)

        // Whether or not the exit status says so too.
        for status: Int32 in [0, 1] {
            claude.status = status
            XCTAssertThrowsError(try extractor.extract(text: Self.doc, doc: "NOTES.md")) { error in
                XCTAssertEqual(error as? PlanDocExtractor.ExtractorError,
                               .failed("Invalid API key · Please run /login"))
                XCTAssertEqual("\(error)", "Invalid API key · Please run /login")
            }
        }
        XCTAssertEqual(cached(), [])
    }

    func testAFailureIsToldByTheEndOfTheOutput() throws {
        let claude = StubClaude(output: (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n\n")
        claude.status = 2
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)

        XCTAssertThrowsError(try extractor.extract(text: Self.doc, doc: "NOTES.md")) { error in
            XCTAssertEqual(error as? PlanDocExtractor.ExtractorError,
                           .failed("line 36\nline 37\nline 38\nline 39\nline 40"))
        }
    }

    func testAnAnswerFromAFailedRunIsNotUsed() throws {
        let claude = StubClaude(output: StubClaude.realOutput)
        claude.status = 1
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)

        XCTAssertThrowsError(try extractor.extract(text: Self.doc, doc: "NOTES.md"))
        XCTAssertEqual(cached(), [])
    }

    func testOutputWithNoComponentListThrows() throws {
        let outputs = [
            "",
            "Here are the components: a reader and a loader.",
            #"{"type":"result","subtype":"success","is_error":false,"result":"a reader and a loader"}"#,
            #"{"type":"result","is_error":false,"structured_output":{"components":[{"id":"half"}]}}"#,
            #"{"type":"assistant","structured_output":{"components":[]}}"#,
        ]
        for output in outputs {
            let claude = StubClaude(output: output)
            let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)
            XCTAssertThrowsError(try extractor.extract(text: Self.doc, doc: "NOTES.md"), output) { error in
                XCTAssertEqual(error as? PlanDocExtractor.ExtractorError, .noAnswer, output)
            }
        }
        XCTAssertEqual(cached(), [])
    }

    func testFindsTheResultAmongOtherLines() throws {
        let claude = StubClaude(output: "warning: something on standard error\n"
            + StubClaude.realOutput + "\n{\"note\": \"not the result\"}\n")
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)
        XCTAssertEqual(try extractor.extract(text: Self.doc, doc: "NOTES.md").map(\.id), ["csv-reader", "loader"])
    }

    func testIdsComeOutTheWayAPlanDocWritesThem() throws {
        let claude = StubClaude(output: StubClaude.output(components: """
            {"id":"CSV Reader","name":" CSV reader ","summary":"Reads.","heading":"","paths":[],\
            "needs":[],"changes":[]},\
            {"id":"2nd_loader!","name":"Loader","summary":"Loads.","heading":"the LOADER","paths":[],\
            "needs":["CSV Reader","???"],"changes":["csv_reader"],"doneWhen":""},\
            {"id":"!!!","name":"Nameless","summary":"","heading":"","paths":[],"needs":[],"changes":[]}
            """))
        let components = try PlanDocExtractor(cacheDirectory: cache, run: claude.run)
            .extract(text: Self.doc, doc: "NOTES.md")

        XCTAssertEqual(components.map(\.id), ["csv-reader", "nd-loader"], "one with no id at all is left out")
        XCTAssertEqual(components[0].name, "CSV reader")
        XCTAssertEqual(components[1].needs, ["csv-reader"])
        XCTAssertEqual(components[1].changes, ["csv-reader"])
        XCTAssertNil(components[1].doneWhen)
        XCTAssertEqual(components[1].line, 5, "headings are matched whatever their case")
        XCTAssertEqual(components[1].heading, "The loader")
    }

    func testAComponentWithNoHeadingIsDescribedByTheWholeDoc() throws {
        let claude = StubClaude(output: StubClaude.output(components: """
            {"id":"reader","name":"Reader","summary":"Reads.","heading":"A heading that isn't there",\
            "paths":[],"needs":[],"changes":[]}
            """))
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)

        let titled = try XCTUnwrap(extractor.extract(text: Self.doc, doc: "NOTES.md").first)
        XCTAssertEqual(titled.line, 1)
        XCTAssertEqual(titled.heading, "Notes on the importer")
        XCTAssertEqual(titled.text, Self.doc.trimmingCharacters(in: .whitespacesAndNewlines))

        let untitled = try XCTUnwrap(extractor.extract(text: "Just build a reader.\n", doc: "ideas/reader.md").first)
        XCTAssertEqual(untitled.heading, "ideas/reader.md")
        XCTAssertEqual(untitled.text, "Just build a reader.")
    }

    func testADamagedCacheFileIsReadAgain() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent(Self.docHash + ".json")
        try "{ cut short".write(to: file, atomically: true, encoding: .utf8)

        let claude = StubClaude(output: StubClaude.realOutput)
        let extractor = PlanDocExtractor(cacheDirectory: cache, run: claude.run)
        XCTAssertEqual(try extractor.extract(text: Self.doc, doc: "NOTES.md").count, 2)
        XCTAssertEqual(try extractor.extract(text: Self.doc, doc: "NOTES.md").count, 2)
        XCTAssertEqual(claude.calls.count, 1, "the file was written again, whole")
    }

    func testARunnerThatThrowsIsPassedOn() {
        struct NoSuchProgram: Error {}
        let extractor = PlanDocExtractor(cacheDirectory: cache) { _, _, _ in throw NoSuchProgram() }
        XCTAssertThrowsError(try extractor.extract(text: Self.doc, doc: "NOTES.md")) { error in
            XCTAssertTrue(error is NoSuchProgram)
        }
    }

    func testTheCacheOfARepoIsUnderItsDotG8r() {
        XCTAssertEqual(PlanDocExtractor.cacheDirectory(planRoot: "/work/shop").path, "/work/shop/.g8r/plans")
    }
}
