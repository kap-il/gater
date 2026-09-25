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

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = (try? JSONDecoder().decode(JSONValue.self, from: stdinData))?.objectValue else {
    FileHandle.standardError.write("gater-hook: could not parse hook JSON from stdin\n".data(using: .utf8)!)
    exit(0)
}

let outcome = HookProcessor.process(
    payload: payload,
    env: .init(paneId: paneId,
               role: environment["GATER_ROLE"],
               delegationTool: environment["GATER_DELEGATION_TOOL_NAME"] ?? "SendMessage")
)

let collector = environment["GATER_COLLECTOR"] ?? EventBus.defaultSocketPath()
for event in outcome.events {
    if let line = try? JSONEncoder().encode(event), let text = String(data: line, encoding: .utf8) {
        try? UnixSocketClient(path: collector).send(line: text) // best effort
    }
}
if let stderr = outcome.stderr {
    FileHandle.standardError.write(stderr.data(using: .utf8)!)
}
exit(outcome.exitCode)
