import Foundation

/// The pure logic behind g8r-hook: a Claude Code hook payload, or a Codex
/// `notify` payload, plus the pane it came from → the events to log. Kept
/// out of the executable so it's testable.
///
/// Observation only: nothing here blocks or changes a tool call.
public enum HookProcessor {
    public struct Environment: Equatable {
        public var paneId: String
        /// The component a build session is building (`G8R_COMPONENT`);
        /// nil for every other pane.
        public var component: String?
        public var now: Date

        public init(paneId: String, component: String? = nil, now: Date = Date()) {
            self.paneId = paneId
            self.component = component
            self.now = now
        }
    }

    /// What g8r-hook was run with, after its own name. Claude Code's hooks
    /// run it bare and pipe the payload in; Codex's `notify` runs it as
    /// `g8r-hook codex-notify <payload>`, the payload as the last argument.
    /// Returns nil when there is no payload to read.
    public static func process(arguments: [String], stdin: () -> Data, env: Environment) -> [G8rEvent]? {
        if arguments.first == Agent.codexNotifyArgument {
            guard arguments.count > 1, let last = arguments.last,
                  let payload = (try? JSONDecoder().decode(JSONValue.self, from: Data(last.utf8)))?.objectValue
            else { return nil }
            return process(codexNotify: payload, env: env)
        }
        guard let payload = (try? JSONDecoder().decode(JSONValue.self, from: stdin()))?.objectValue else {
            return nil
        }
        return process(payload: payload, env: env)
    }

    /// Codex's `notify` payload. It says only that a turn finished
    /// (`agent-turn-complete`), which is Codex's session going idle: a
    /// `stop`, like Claude Code's Stop hook. Codex reports no edits or
    /// commands this way.
    public static func process(codexNotify payload: [String: JSONValue], env: Environment) -> [G8rEvent] {
        var fields: [String: JSONValue]
        if payload["type"]?.stringValue == "agent-turn-complete" {
            fields = ["kind": .string("stop"), "agent": .string(Agent.codex.rawValue)]
            if let turn = payload["turn-id"] { fields["turn"] = turn }
        } else {
            fields = payload
            fields["kind"] = .string("raw")
            fields["hook"] = payload["type"]
        }
        fields["pane"] = .string(env.paneId)
        if let component = env.component, !component.isEmpty { fields["component"] = .string(component) }
        fields["ts"] = .string(ISO8601DateFormatter().string(from: env.now))
        if let thread = payload["thread-id"] { fields["session"] = thread }
        return [G8rEvent(fields: fields)]
    }

    public static func process(payload: [String: JSONValue], env: Environment) -> [G8rEvent] {
        let toolName = payload["tool_name"]?.stringValue
        let toolInput = payload["tool_input"]
        let ts = ISO8601DateFormatter().string(from: env.now)

        func event(_ kind: String, _ extra: [String: JSONValue]) -> G8rEvent {
            var fields = extra
            fields["kind"] = .string(kind)
            fields["pane"] = .string(env.paneId)
            if let component = env.component, !component.isEmpty { fields["component"] = .string(component) }
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
