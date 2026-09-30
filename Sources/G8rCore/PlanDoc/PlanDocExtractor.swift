import Foundation

/// Runs a program and returns what it printed. Injected so tests never
/// start a real process.
public typealias CommandRunner =
    (_ executable: String, _ arguments: [String], _ stdin: String?) throws -> (status: Int32, output: String)

/// Reads a free-form plan doc by asking the agent (Claude Code or Codex)
/// which components it describes. The answer is kept under the hash of the doc's text, so a
/// doc is only read by a model when it changes.
///
/// A failed run is not kept: the next call asks again.
public struct PlanDocExtractor {
    public enum ExtractorError: Error, Equatable, CustomStringConvertible {
        /// The command exited with a failure, or reported one.
        case failed(String)
        /// The command's output held no component list.
        case noAnswer

        public var description: String {
            switch self {
            case let .failed(output): return output
            case .noAnswer: return "the agent gave no component list"
            }
        }
    }

    private let cacheDirectory: URL
    private let agent: Agent
    private let run: CommandRunner

    public init(cacheDirectory: URL, agent: Agent = .default, run: @escaping CommandRunner) {
        self.cacheDirectory = cacheDirectory
        self.agent = agent
        self.run = run
    }

    /// Where a repo's answers are kept: `<plan root>/.g8r/plans`.
    public static func cacheDirectory(planRoot: String) -> URL {
        URL(fileURLWithPath: planRoot).appendingPathComponent(".g8r/plans")
    }

    public func extract(text: String, doc: String) throws -> [PlanComponent] {
        let cache = cacheDirectory.appendingPathComponent(TextHash.sha256(text) + ".json")
        if let data = try? Data(contentsOf: cache),
           let answer = try? JSONDecoder().decode(Answer.self, from: data) {
            return components(from: answer, text: text, doc: doc)
        }

        let answer = try ask(text)

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(answer).write(to: cache, options: .atomic)
        return components(from: answer, text: text, doc: doc)
    }

    // MARK: - The command

    /// Asks the agent about `text`, which goes in on standard input. A
    /// schema the agent wants as a file is written for the one run.
    private func ask(_ text: String) throws -> Answer {
        let schema = agent.needsStrictSchema ? Self.strictSchema : Self.schema
        var schemaFile: URL?
        if agent.needsSchemaFile {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("g8r-plan-schema-\(UUID().uuidString).json")
            try schema.write(to: file, atomically: true, encoding: .utf8)
            schemaFile = file
        }
        defer { if let schemaFile { try? FileManager.default.removeItem(at: schemaFile) } }

        let command = agent.oneShot(prompt: Self.prompt, schema: schema, schemaFile: schemaFile?.path ?? "")
        let found: JSONValue
        do {
            found = try agent.oneShotAnswer(from: try run(command.executable, command.arguments, text))
        } catch let error as Agent.OneShotError {
            switch error {
            case let .failed(output): throw ExtractorError.failed(output)
            case .noAnswer: throw ExtractorError.noAnswer
            }
        }
        guard let data = try? JSONEncoder().encode(found),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw ExtractorError.noAnswer
        }
        return answer
    }

    /// Claude Code's arguments, kept for the tests that pin them.
    static var arguments: [String] {
        Agent.claudeCode.oneShot(prompt: prompt, schema: schema, schemaFile: "").arguments
    }

    static let prompt = """
        The text on standard input is a plan document for a codebase. List the components it \
        describes: the units of code that get built and kept, not tasks or milestones.

        For each component give:
        - id: a short name in lowercase letters, digits and hyphens, starting with a letter, unique in the list
        - name: what the document calls it
        - summary: one sentence saying what it is
        - heading: the text of the heading it is described under, copied exactly without the leading # marks; \
        empty if there is none
        - paths: the files, directories (ending in /) or globs the document says its code lives in; \
        empty if it names none
        - needs: ids of the components in your list that it can't be built without
        - changes: ids of the components in your list that it modifies
        - doneWhen: how the document says to tell it is finished; leave it out, or empty, if the document doesn't say

        Use only what the document says. Don't read files or run anything.
        """

    static let schema = """
        {"type":"object","properties":{"components":{"type":"array","items":{"type":"object",\
        "properties":{"id":{"type":"string"},"name":{"type":"string"},"summary":{"type":"string"},\
        "heading":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},\
        "needs":{"type":"array","items":{"type":"string"}},\
        "changes":{"type":"array","items":{"type":"string"}},"doneWhen":{"type":"string"}},\
        "required":["id","name","summary","heading","paths","needs","changes"],\
        "additionalProperties":false}}},"required":["components"],"additionalProperties":false}
        """

    /// The same list for a model that checks schemas strictly (Codex):
    /// every property is required, so `doneWhen` is always given, and
    /// empty when the document doesn't say.
    static let strictSchema = """
        {"type":"object","properties":{"components":{"type":"array","items":{"type":"object",\
        "properties":{"id":{"type":"string"},"name":{"type":"string"},"summary":{"type":"string"},\
        "heading":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},\
        "needs":{"type":"array","items":{"type":"string"}},\
        "changes":{"type":"array","items":{"type":"string"}},"doneWhen":{"type":"string"}},\
        "required":["id","name","summary","heading","paths","needs","changes","doneWhen"],\
        "additionalProperties":false}}},"required":["components"],"additionalProperties":false}
        """

    // MARK: - The answer

    /// What the schema asks for. This is also what the cache holds.
    struct Answer: Codable, Equatable {
        struct Component: Codable, Equatable {
            var id: String
            var name: String
            var summary: String
            var heading: String
            var paths: [String]
            var needs: [String]
            var changes: [String]
            var doneWhen: String?
        }
        var components: [Component]
    }

    /// Fills in what only the doc can say: where each component's section
    /// is. A component whose heading isn't in the doc is described by the
    /// doc as a whole.
    private func components(from answer: Answer, text: String, doc: String) -> [PlanComponent] {
        let outline = PlanDocOutline(text)
        return answer.components.compactMap { found in
            let id = Self.id(found.id)
            guard !id.isEmpty else { return nil }
            let wanted = found.heading.trimmingCharacters(in: .whitespaces).lowercased()
            let position = outline.headings.firstIndex { $0.text.lowercased() == wanted }
            let heading = position.map { outline.headings[$0] }
            return PlanComponent(
                id: id,
                name: found.name.trimmingCharacters(in: .whitespaces),
                summary: found.summary.trimmingCharacters(in: .whitespaces),
                doc: doc,
                line: heading.map { $0.index + 1 } ?? 1,
                heading: heading?.text ?? outline.title ?? doc,
                text: position.map(outline.body) ?? text.trimmingCharacters(in: .whitespacesAndNewlines),
                paths: found.paths,
                needs: found.needs.map(Self.id).filter { !$0.isEmpty },
                changes: found.changes.map(Self.id).filter { !$0.isEmpty },
                doneWhen: found.doneWhen.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// An id as the plan doc format writes one, whatever the model wrote.
    /// Applied to needs and changes as well, so they still name the same
    /// components.
    static func id(_ written: String) -> String {
        let words = written.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return String(words.joined(separator: "-").drop { !$0.isLetter })
    }
}
