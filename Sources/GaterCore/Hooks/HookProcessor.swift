import Foundation

/// What gater-hook should do for one Claude Code hook invocation.
public struct HookOutcome: Equatable {
    /// Events to forward to the event bus, in order.
    public var events: [GaterEvent]
    /// Process exit code: 0 = proceed, 2 = block (PreToolUse only).
    public var exitCode: Int32
    /// Fed back to Claude when blocking.
    public var stderr: String?
    /// A delegate pane that must be open (and its session ready) before
    /// this send may proceed: the orchestrator is delegating to a
    /// `delegate-<name>` that may not exist yet, so Gater spawns it.
    public var ensurePane: String?

    public init(events: [GaterEvent], exitCode: Int32, stderr: String?, ensurePane: String? = nil) {
        self.events = events
        self.exitCode = exitCode
        self.stderr = stderr
        self.ensurePane = ensurePane
    }
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
        /// Current plan.json, when the pane knows its repo. Enables id
        /// consistency checks; nil skips them.
        public var plan: Plan?
        public var now: Date

        public init(paneId: String, role: String?, delegationTool: String = "SendMessage",
                    plan: Plan? = nil, now: Date = Date()) {
            self.paneId = paneId
            self.role = role
            self.delegationTool = delegationTool
            self.plan = plan
            self.now = now
        }
    }

    /// Reads the transcript file a Stop payload points at; injectable for tests.
    public typealias TranscriptReader = (String) -> String?

    /// Maps a SendMessage address (e.g. a peer's `uds:` socket) to a pane id.
    public typealias PaneResolver = (String) -> String?

    public static func process(payload: [String: JSONValue], env: Environment,
                               readTranscript: TranscriptReader = { try? String(contentsOfFile: $0, encoding: .utf8) },
                               resolvePane: PaneResolver = { _ in nil }) -> HookOutcome {
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
            // Asking to be notified when a delegate goes idle isn't a
            // delegation (seen live: the orchestrator's idle subscriptions
            // were blocked). Only messages that carry work need GATER/1.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if toolInput?.value(atPath: "notify_when_idle") == .bool(true), !trimmed.hasPrefix("GATER/1") {
                return HookOutcome(events: [], exitCode: 0, stderr: nil)
            }
            switch GaterProtocol.parseDelegationMessage(text) {
            case let .failure(error):
                let message = """
                Gater: blocked this message — \(error)
                Messages from the orchestrator must start with a GATER/1 block. Fix the block and resend; nothing else about the message is being judged.

                Expected format:
                \(GaterProtocol.expectedFormatHelp)
                """
                return HookOutcome(events: [], exitCode: 2, stderr: message)
            case let .success(message):
                if let plan = env.plan, let problem = idProblem(message, plan: plan) {
                    return HookOutcome(events: [], exitCode: 2, stderr: """
                    Gater: blocked this message — \(problem)
                    Only the GATER/1 block needs fixing; resend with the corrected id or type.
                    """)
                }
                // New work for a `delegate-<name>` session: make sure it
                // exists — Gater opens the pane and worktree if needed.
                var ensure: String?
                if message.type == .delegate, let to = toolInput?.value(atPath: "to")?.stringValue,
                   to.hasPrefix("delegate-"), GitWorktree.isValidName(String(to.dropFirst("delegate-".count))) {
                    ensure = to
                }
                return HookOutcome(events: [], exitCode: 0, stderr: nil, ensurePane: ensure)
            }

        // The send went through: log it. Orchestrator sends that parse as
        // GATER/1 are delegations; anything else is a plain message.
        case ("PostToolUse", env.delegationTool?):
            let text = toolInput?.value(atPath: "message")?.stringValue ?? ""
            var extra: [String: JSONValue] = ["raw": .string(text)]
            if let to = toolInput?.value(atPath: "to") {
                extra["to"] = to
                // Replies address the sender's socket (uds:/…/<pid>.sock);
                // name the pane so the log reads orch → delegate → orch.
                if let address = to.stringValue {
                    extra["to_pane"] = .string(resolvePane(address) ?? address)
                }
            }
            if let summary = toolInput?.value(atPath: "summary") { extra["summary"] = summary }
            if env.role == "orchestrator", case let .success(message) = GaterProtocol.parseDelegationMessage(text) {
                extra["gater"] = gaterObject(message)
                return HookOutcome(events: [event("delegation", extra)], exitCode: 0, stderr: nil)
            }
            var events = [event("message", extra)]
            // Delegates report back by messaging the orchestrator, so the
            // GATER-DONE note usually rides in the reply (seen live), not in
            // the final turn text the Stop hook sees.
            if let note = GaterProtocol.extractDoneNote(from: text) {
                events.append(doneEvent(note, event))
            }
            return HookOutcome(events: events, exitCode: 0, stderr: nil)

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
                events.append(doneEvent(note, event))
            }
            return HookOutcome(events: events, exitCode: 0, stderr: nil)

        default:
            // Anything else a matcher routed here: keep it, tagged raw.
            var extra = payload
            extra["hook"] = payload["hook_event_name"]
            return HookOutcome(events: [event("raw", extra)], exitCode: 0, stderr: nil)
        }
    }

    /// Id/type consistency against the plan: `delegate` must mint a new id;
    /// every other type must reference an existing dish. This is still
    /// format checking (is the block well-formed for the plan it's about),
    /// never a judgment about the delegation itself.
    static func idProblem(_ message: GaterMessage, plan: Plan) -> String? {
        let existing = plan.dish(message.id)
        switch message.type {
        case .delegate:
            if let existing {
                return "dish \(message.id) already exists (\(existing.feature): \"\(existing.directive)\", \(existing.state.rawValue)). New work needs a new id — next free is \(plan.nextDishId). To change \(message.id), use type: instruct or rescope."
            }
        default:
            if existing == nil {
                let known = plan.dishes.filter { $0.state.isActive }.map(\.id)
                let list = known.isEmpty ? "there are no dishes yet" : "existing dishes: \(known.joined(separator: ", "))"
                return "type: \(message.type.rawValue) needs an existing dish, but \(message.id) doesn't exist (\(list)). For new work use type: delegate with id: \(plan.nextDishId), plus feature and directive."
            }
            if message.type == .merge, let target = message.mergeInto, plan.dish(target) == nil {
                return "merge_into: \(target) doesn't exist."
            }
        }
        return nil
    }

    private static func doneEvent(_ note: GaterDoneNote,
                                  _ make: (String, [String: JSONValue]) -> GaterEvent) -> GaterEvent {
        make("done_note", [
            "dish": .string(note.dishId),
            "did": .string(note.did),
            "assumed": .string(note.assumed),
            "touched": .array(note.touched.map { .string($0) }),
        ])
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
