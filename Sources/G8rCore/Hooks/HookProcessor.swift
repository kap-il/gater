import Foundation

/// The pure logic behind g8r-hook: a Claude Code hook payload plus the
/// pane it came from → the events to log. Kept out of the executable so
/// it's testable.
///
/// Observation only: nothing here blocks or changes a tool call.
public enum HookProcessor {
    public struct Environment: Equatable {
        public var paneId: String
        public var now: Date

        public init(paneId: String, now: Date = Date()) {
            self.paneId = paneId
            self.now = now
        }
    }

    public static func process(payload: [String: JSONValue], env: Environment) -> [G8rEvent] {
        let toolName = payload["tool_name"]?.stringValue
        let toolInput = payload["tool_input"]
        let ts = ISO8601DateFormatter().string(from: env.now)

        func event(_ kind: String, _ extra: [String: JSONValue]) -> G8rEvent {
            var fields = extra
            fields["kind"] = .string(kind)
            fields["pane"] = .string(env.paneId)
            fields["ts"] = .string(ts)
            if let session = payload["session_id"] { fields["session"] = session }
            return G8rEvent(fields: fields)
        }

        switch (payload["hook_event_name"]?.stringValue, toolName) {
        case ("PostToolUse", "Edit"?), ("PostToolUse", "Write"?), ("PostToolUse", "MultiEdit"?):
            var extra: [String: JSONValue] = ["tool": .string(toolName ?? "")]
            if let path = toolInput?.value(atPath: "file_path") { extra["path"] = path }
            return [event("edit", extra)]

        case ("PostToolUse", "Bash"?):
            var extra: [String: JSONValue] = [:]
            if let command = toolInput?.value(atPath: "command") { extra["command"] = command }
            if let description = toolInput?.value(atPath: "description") { extra["description"] = description }
            return [event("command", extra)]

        case ("Stop", _):
            return [event("stop", [:])]

        default:
            // Anything else a matcher routed here: keep it, tagged raw.
            var extra = payload
            extra["hook"] = payload["hook_event_name"]
            return [event("raw", extra)]
        }
    }
}
