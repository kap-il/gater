import Foundation
import GaterCore

// gater-hook: invoked by Claude Code hooks (see claude/settings.hooks.json).
// Reads the hook's JSON payload from stdin, forwards an enriched event to
// the Gater event bus, and — for PreToolUse on the delegation tool —
// validates the GATER/1 format, blocking (exit 2) on a bad message so
// Claude sees the expected format on stderr and retries.
//
// NOTE: the exact field names Claude Code's hook payloads use for the
// message text of a cross-session send are unverified (spec §4.2 flags
// this explicitly). Candidate field names below are best-effort until
// that's confirmed against a live hook payload.

func env(_ name: String, default def: String? = nil) -> String? {
    ProcessInfo.processInfo.environment[name] ?? def
}

// Hooks live in the worktree's settings, so they also fire when someone
// runs `claude` there outside Gater. Only Gater panes set GATER_PANE_ID.
guard let paneId = env("GATER_PANE_ID"), !paneId.isEmpty else { exit(0) }

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder()

guard let payload = try? decoder.decode(JSONValue.self, from: stdinData),
      case .object(var fields) = payload else {
    FileHandle.standardError.write("gater-hook: could not parse hook JSON from stdin\n".data(using: .utf8)!)
    exit(0) // fail open — never break the hook chain over a transport-side problem
}

let collectorPath = env("GATER_COLLECTOR") ?? EventBus.defaultSocketPath()
let delegationToolName = env("GATER_DELEGATION_TOOL_NAME")

fields["pane"] = .string(paneId)
if fields["ts"] == nil {
    fields["ts"] = .string(ISO8601DateFormatter().string(from: Date()))
}

let hookEventName = fields["hook_event_name"]?.stringValue
let toolName = fields["tool_name"]?.stringValue

func send(_ event: GaterEvent) {
    guard let line = try? JSONEncoder().encode(event) else { return }
    let text = String(data: line, encoding: .utf8) ?? "{}"
    try? UnixSocketClient(path: collectorPath).send(line: text)
    // Best-effort: if Gater.app isn't running, the hook still shouldn't fail.
}

func candidateMessageText(from toolInput: JSONValue?) -> String {
    guard let toolInput else { return "" }
    for key in ["message", "prompt", "text", "body", "content"] {
        if let value = toolInput.value(atPath: key)?.stringValue {
            return value
        }
    }
    return ""
}

if hookEventName == "PreToolUse",
   let delegationToolName,
   toolName == delegationToolName {
    let toolInput = fields["tool_input"]
    let messageText = candidateMessageText(from: toolInput)

    switch GaterProtocol.parseDelegationMessage(messageText) {
    case .failure(let error):
        let msg = """
        Gater: blocked malformed delegation message — \(error)

        Expected format:
        \(GaterProtocol.expectedFormatHelp)

        """
        FileHandle.standardError.write(msg.data(using: .utf8)!)
        exit(2)
    case .success(let message):
        var extra: [String: JSONValue] = fields
        extra["kind"] = .string("delegation")
        extra["gater_type"] = .string(message.type.rawValue)
        extra["gater_id"] = .string(message.id)
        if let feature = message.feature { extra["gater_feature"] = .string(feature) }
        if let directive = message.directive { extra["gater_directive"] = .string(directive) }
        extra["gater_scope"] = .array(message.scope.map { .string($0) })
        send(GaterEvent(fields: extra))
        exit(0)
    }
} else {
    var kind = "raw"
    switch hookEventName {
    case "PostToolUse": kind = "edit"
    case "Stop": kind = "stop"
    default: break
    }
    fields["kind"] = .string(fields["kind"]?.stringValue ?? kind)
    send(GaterEvent(fields: fields))

    if hookEventName == "Stop" {
        let lastMessage = fields["last_message"]?.stringValue ?? fields["message"]?.stringValue ?? ""
        if let note = GaterProtocol.extractDoneNote(from: lastMessage) {
            let doneFields: [String: JSONValue] = [
                "kind": .string("done_note"),
                "pane": .string(paneId),
                "ts": .string(ISO8601DateFormatter().string(from: Date())),
                "dish": .string(note.dishId),
                "did": .string(note.did),
                "assumed": .string(note.assumed),
                "touched": .array(note.touched.map { .string($0) })
            ]
            send(GaterEvent(fields: doneFields))
        }
    }
    exit(0)
}
