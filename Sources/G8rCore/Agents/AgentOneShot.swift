import Foundation

/// Asking an agent one question and reading back an answer shaped by a JSON
/// schema, as plan extraction does. The question's text goes in on standard
/// input, so its size never meets the limit on argument length.
extension Agent {
    public struct OneShot: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
    }

    /// Whether the agent needs the schema in a file, at the path given to
    /// `oneShot`. Codex's `--output-schema` takes a file; Claude Code's
    /// `--json-schema` takes the text.
    public var needsSchemaFile: Bool { self == .codex }

    /// Whether the agent's model checks the schema strictly: every object
    /// closed, every property required. Codex asks the Responses API for
    /// strict validation.
    public var needsStrictSchema: Bool { self == .codex }

    /// The command that asks `prompt`, about the text on standard input,
    /// and answers in the shape of `schema`.
    ///
    /// - Claude Code: `claude -p <prompt> --output-format json --json-schema <schema>`.
    /// - Codex: `codex exec --json --ephemeral --sandbox read-only
    ///   --output-schema <schemaFile> <prompt>`. Codex appends piped
    ///   standard input to the prompt as a `<stdin>` block. Read-only is
    ///   `codex exec`'s default sandbox, said again so a user's config
    ///   can't widen it for a question that needs no tools.
    public func oneShot(prompt: String, schema: String, schemaFile: String) -> OneShot {
        switch self {
        case .claudeCode:
            return OneShot(executable: program,
                           arguments: ["-p", prompt, "--output-format", "json", "--json-schema", schema])
        case .codex:
            return OneShot(executable: program,
                           arguments: ["exec", "--json", "--ephemeral", "--sandbox", "read-only",
                                       "--output-schema", schemaFile, prompt])
        }
    }

    public enum OneShotError: Error, Equatable {
        /// The command failed, or said it did; the agent's words, or the
        /// end of what it printed.
        case failed(String)
        /// It finished without an answer.
        case noAnswer
    }

    /// The answer in what the one-shot command printed. A runner may hand
    /// back warnings along with it, so a line that isn't the agent's is
    /// passed over.
    public func oneShotAnswer(from run: (status: Int32, output: String)) throws -> JSONValue {
        let lines = run.output.split(whereSeparator: \.isNewline).map(String.init)
        switch self {
        case .claudeCode: return try Self.claudeAnswer(run, lines: lines)
        case .codex: return try Self.codexAnswer(run, lines: lines)
        }
    }

    /// `claude -p --output-format json` prints one object, with the
    /// schema's answer under `structured_output`. When the output as a
    /// whole isn't it, its lines are tried, last first.
    private static func claudeAnswer(_ run: (status: Int32, output: String), lines: [String]) throws -> JSONValue {
        let result = ([run.output] + lines.reversed()).lazy
            .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            .first { $0.value(atPath: "type")?.stringValue == "result" }

        if run.status != 0 || result?.value(atPath: "is_error") == .bool(true) {
            // Claude's own words when it has any; otherwise the end of the
            // output, which is where a failing program says why.
            throw OneShotError.failed(result?.value(atPath: "result")?.stringValue
                                      ?? lines.suffix(5).joined(separator: "\n"))
        }
        guard let answer = result?.value(atPath: "structured_output"), answer.objectValue != nil else {
            throw OneShotError.noAnswer
        }
        return answer
    }

    /// `codex exec --json` prints one event per line. The answer is the
    /// text of the last completed `agent_message` item, which is the
    /// schema's JSON. `turn.failed` and `error` events say what went wrong.
    /// Without `--json`, Codex prints only the final message, which is
    /// tried as the answer when there are no events.
    private static func codexAnswer(_ run: (status: Int32, output: String), lines: [String]) throws -> JSONValue {
        var message: String?
        var failure: String?
        var sawEvent = false
        for line in lines {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let type = event.value(atPath: "type")?.stringValue else { continue }
            sawEvent = true
            switch type {
            case "item.completed" where event.value(atPath: "item.type")?.stringValue == "agent_message":
                message = event.value(atPath: "item.text")?.stringValue
            case "turn.failed":
                failure = event.value(atPath: "error.message")?.stringValue ?? failure
            case "error":
                failure = event.value(atPath: "message")?.stringValue ?? failure
            default:
                continue
            }
        }
        if !sawEvent, run.status == 0 { message = run.output }

        let answer = message.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        if run.status != 0 || (failure != nil && answer == nil) {
            throw OneShotError.failed(failure ?? lines.suffix(5).joined(separator: "\n"))
        }
        guard let answer, answer.objectValue != nil else { throw OneShotError.noAnswer }
        return answer
    }
}
