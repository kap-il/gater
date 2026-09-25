import Foundation
import GaterCore

// gater-hook: invoked by the Claude Code hooks Gater installs into each
// pane's worktree (.claude/settings.local.json). Reads the hook payload on
// stdin, forwards events to the Gater event bus, and — for the
// orchestrator's SendMessage — blocks malformed GATER/1 messages with
// exit 2 so Claude sees the expected format and retries. The decisions
// live in GaterCore.HookProcessor; this file only does I/O.
//
// Fails open: transport problems never block Claude.

let environment = ProcessInfo.processInfo.environment

// Hooks also fire when someone runs `claude` in the worktree outside
// Gater; only Gater panes set GATER_PANE_ID.
guard let paneId = environment["GATER_PANE_ID"], !paneId.isEmpty else { exit(0) }

// prepare-commit-msg mode: `gater-hook --commit-trailers <message-file>`.
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--commit-trailers" {
    let plan = environment["GATER_REPO"].flatMap { PlanStore.load(from: PlanStore.defaultPath(repoRoot: $0)) }
    try? CommitTrailers.append(to: arguments[2], plan: plan, pane: paneId)
    exit(0) // never block a commit over trailers
}

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = (try? JSONDecoder().decode(JSONValue.self, from: stdinData))?.objectValue else {
    FileHandle.standardError.write("gater-hook: could not parse hook JSON from stdin\n".data(using: .utf8)!)
    exit(0)
}

// The plan lets the orchestrator's sends be checked for id mistakes.
let plan = environment["GATER_REPO"].flatMap { PlanStore.load(from: PlanStore.defaultPath(repoRoot: $0)) }

let outcome = HookProcessor.process(
    payload: payload,
    env: .init(paneId: paneId,
               role: environment["GATER_ROLE"],
               delegationTool: environment["GATER_DELEGATION_TOOL_NAME"] ?? "SendMessage",
               plan: plan),
    resolvePane: PaneAddressResolver.pane(forAddress:)
)

let collector = environment["GATER_COLLECTOR"] ?? EventBus.defaultSocketPath()

// Delegating to a pane that may not exist: ask Gater to open it and wait
// until its session can receive the message. Gater unreachable → fail open.
if outcome.exitCode == 0, let pane = outcome.ensurePane {
    let request = JSONValue.object(["request": .string("ensure_delegate"), "pane": .string(pane)])
    if let line = try? JSONEncoder().encode(request),
       let replyText = try? UnixSocketClient(path: collector).request(line: String(decoding: line, as: UTF8.self), timeout: 90),
       let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(replyText.utf8)),
       reply.value(atPath: "ok") != .bool(true) {
        let reason = reply.value(atPath: "reason")?.stringValue ?? "unknown error"
        FileHandle.standardError.write("Gater: couldn't open \(pane) — \(reason)\n".data(using: .utf8)!)
        exit(2)
    }
}
for event in outcome.events {
    if let line = try? JSONEncoder().encode(event), let text = String(data: line, encoding: .utf8) {
        try? UnixSocketClient(path: collector).send(line: text) // best effort
    }
}
if let stderr = outcome.stderr {
    FileHandle.standardError.write(stderr.data(using: .utf8)!)
}
exit(outcome.exitCode)
