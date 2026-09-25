import Foundation

/// What gater-hook should do for one Claude Code hook invocation.
public struct HookOutcome: Equatable {
    /// Events to forward to the event bus, in order.
    public var events: [GaterEvent]
    /// Process exit code: 0 = proceed, 2 = block (PreToolUse only).
    public var exitCode: Int32
    /// Fed back to Claude when blocking.
    public var stderr: String?
}

/// The pure logic behind gater-hook: hook payload + pane environment →
/// events and an exit code. Kept out of the executable so it's testable.
///
/// Verified facts it relies on (spec §4.2, checked against the Claude Code
/// docs): the cross-session send tool is `SendMessage` with `tool_input`
/// `{to, message, summary?}`; PreToolUse can block it with exit 2; no hook
/// fires on the *receiving* side, so delegations are logged here, on the
/// sender's PostToolUse.
public enum HookProcessor {
    public struct Environment: Equatable {
        public var paneId: String
        /// orchestrator | delegate (GATER_ROLE).
        public var role: String?
        public var delegationTool: String
        public var now: Date

        public init(paneId: String, role: String?, delegationTool: String = "SendMessage", now: Date = Date()) {
            self.paneId = paneId
            self.role = role
            self.delegationTool = delegationTool
            self.now = now
        }
    }

    /// Reads the transcript file a Stop payload points at; injectable for tests.
    public typealias TranscriptReader = (String) -> String?

    public static func process(payload: [String: JSONValue], env: Environment,
                               readTranscript: TranscriptReader = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> HookOutcome {
        let hookEvent = payload["hook_event_name"]?.stringValue
        let toolName = payload["tool_name"]?.stringValue
        let toolInput = payload["tool_input"]
        let ts = ISO8601DateFormatter().string(from: env.now)

        func event(_ kind: String, _ extra: [String: JSONValue]) -> GaterEvent {
            var fields = extra
            fields["kind"] = .string(kind)
            fields["pane"] = .string(env.paneId)
            fields["ts"] = .string(ts)
            if let session = payload["session_id"] { fields["session"] = session }
            return GaterEvent(fields: fields)
        }

        switch (hookEvent, toolName) {
        // Format enforcement: only the orchestrator's sends must carry a
        // GATER/1 block. Delegates replying to the orchestrator are free-form.
        case ("PreToolUse", env.delegationTool?):
            guard env.role == "orchestrator" else { return HookOutcome(events: [], exitCode: 0, stderr: nil) }
            let text = toolInput?.value(atPath: "message")?.stringValue ?? ""
            if case let .failure(error) = GaterProtocol.parseDelegationMessage(text) {
                let message = """
                Gater: blocked this message — \(error)
                Messages from the orchestrator must start with a GATER/1 block. Fix the block and resend; nothing else about the message is being judged.

                Expected format:
                \(GaterProtocol.expectedFormatHelp)
                """
                return HookOutcome(events: [], exitCode: 2, stderr: message)
            }
            return HookOutcome(events: [], exitCode: 0, stderr: nil)

        // The send went through: log it. Orchestrator sends that parse as
        // GATER/1 are delegations; anything else is a plain message.
        case ("PostToolUse", env.delegationTool?):
            let text = toolInput?.value(atPath: "message")?.stringValue ?? ""
            var extra: [String: JSONValue] = ["raw": .string(text)]
            if let to = toolInput?.value(atPath: "to") { extra["to"] = to }
            if let summary = toolInput?.value(atPath: "summary") { extra["summary"] = summary }
            if env.role == "orchestrator", case let .success(message) = GaterProtocol.parseDelegationMessage(text) {
                extra["gater"] = gaterObject(message)
                return HookOutcome(events: [event("delegation", extra)], exitCode: 0, stderr: nil)
            }
            return HookOutcome(events: [event("message", extra)], exitCode: 0, stderr: nil)

        case ("PostToolUse", "Edit"?), ("PostToolUse", "Write"?), ("PostToolUse", "MultiEdit"?):
            var extra: [String: JSONValue] = ["tool": .string(toolName ?? "")]
            if let path = toolInput?.value(atPath: "file_path") { extra["path"] = path }
            return HookOutcome(events: [event("edit", extra)], exitCode: 0, stderr: nil)

        case ("PostToolUse", "Bash"?):
            var extra: [String: JSONValue] = [:]
            if let command = toolInput?.value(atPath: "command") { extra["command"] = command }
            if let description = toolInput?.value(atPath: "description") { extra["description"] = description }
            return HookOutcome(events: [event("command", extra)], exitCode: 0, stderr: nil)

        case ("Stop", _):
            var events = [event("stop", [:])]
            let last = payload["last_assistant_message"]?.stringValue
                ?? payload["transcript_path"]?.stringValue.flatMap(readTranscript).flatMap(lastAssistantText)
            if let last, let note = GaterProtocol.extractDoneNote(from: last) {
                events.append(event("done_note", [
                    "dish": .string(note.dishId),
                    "did": .string(note.did),
                    "assumed": .string(note.assumed),
                    "touched": .array(note.touched.map { .string($0) }),
                ]))
            }
            return HookOutcome(events: events, exitCode: 0, stderr: nil)

        default:
            // Anything else a matcher routed here: keep it, tagged raw.
            var extra = payload
            extra["hook"] = payload["hook_event_name"]
            return HookOutcome(events: [event("raw", extra)], exitCode: 0, stderr: nil)
        }
    }

    static func gaterObject(_ message: GaterMessage) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string(message.type.rawValue),
            "id": .string(message.id),
            "scope": .array(message.scope.map { .string($0) }),
        ]
        if let feature = message.feature { fields["feature"] = .string(feature) }
        if let directive = message.directive { fields["directive"] = .string(directive) }
        if let mergeInto = message.mergeInto { fields["merge_into"] = .string(mergeInto) }
        return .object(fields)
    }

    /// Text of the last assistant message in a Claude Code transcript
    /// (JSONL; assistant entries carry `message.content` text blocks).
    static func lastAssistantText(transcript: String) -> String? {
        for line in transcript.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(JSONValue.self, from: data),
                  entry.value(atPath: "type")?.stringValue == "assistant" else { continue }
            let content = entry.value(atPath: "message.content")
            if let text = content?.stringValue { return text }
            let texts = (content?.arrayValue ?? []).compactMap { block -> String? in
                block.value(atPath: "type")?.stringValue == "text" ? block.value(atPath: "text")?.stringValue : nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }
}
