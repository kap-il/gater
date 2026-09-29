import Foundation

/// Runs a program and returns what it printed. Injected so tests never
/// start a real process.
public typealias CommandRunner =
    (_ executable: String, _ arguments: [String], _ stdin: String?) throws -> (status: Int32, output: String)

/// Reads a free-form plan doc by asking Claude which components it
/// describes. The answer is kept under the hash of the doc's text, so a
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
            case .noAnswer: return "claude gave no component list"
            }
        }
    }

    private let cacheDirectory: URL
    private let run: CommandRunner

    public init(cacheDirectory: URL, run: @escaping CommandRunner) {
        self.cacheDirectory = cacheDirectory
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

        let answer = try Self.answer(from: try run("claude", Self.arguments, text))

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(answer).write(to: cache, options: .atomic)
        return components(from: answer, text: text, doc: doc)
    }

    // MARK: - The command

    /// The doc itself goes in on standard input, so its size never meets
    /// the limit on argument length.
    static let arguments = ["-p", prompt, "--output-format", "json", "--json-schema", schema]

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
        - doneWhen: how the document says to tell it is finished; leave it out if the document doesn't say

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

    /// What `claude -p --output-format json` prints: one object, with the
    /// schema's answer under `structured_output`.
    private struct Output: Decodable {
        var type: String
        var isError: Bool?
        var result: String?
        var answer: Answer?

        enum CodingKeys: String, CodingKey {
            case type, result
            case isError = "is_error"
            case answer = "structured_output"
        }
    }

    /// Finds the result in what the command printed. A runner may hand back
    /// warnings along with it, so when the output as a whole isn't the
    /// result, its lines are tried, last first.
    private static func answer(from run: (status: Int32, output: String)) throws -> Answer {
        let lines = run.output.split(whereSeparator: \.isNewline).map(String.init)
        let result = ([run.output] + lines.reversed()).lazy
            .compactMap { try? JSONDecoder().decode(Output.self, from: Data($0.utf8)) }
            .first { $0.type == "result" }

        if run.status != 0 || result?.isError == true {
            // Claude's own words when it has any; otherwise the end of the
            // output, which is where a failing program says why.
            throw ExtractorError.failed(result?.result ?? lines.suffix(5).joined(separator: "\n"))
        }
        guard let answer = result?.answer else { throw ExtractorError.noAnswer }
        return answer
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
