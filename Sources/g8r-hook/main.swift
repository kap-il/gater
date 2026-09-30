import Foundation
import G8rCore

// g8r-hook: invoked by the Claude Code hooks G8r installs into each
// pane's worktree (.claude/settings.local.json). Reads the hook payload on
// stdin and forwards what happened (edits, commands, stops) to the G8r
// event bus. The decisions live in G8rCore.HookProcessor; this file only
// does I/O.
//
// Observation only, and fails open: nothing here ever blocks Claude.

let environment = ProcessInfo.processInfo.environment

// Hooks also fire when someone runs `claude` in the worktree outside
// G8r; only G8r panes set G8R_PANE_ID.
guard let paneId = environment["G8R_PANE_ID"], !paneId.isEmpty else { exit(0) }

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = (try? JSONDecoder().decode(JSONValue.self, from: stdinData))?.objectValue else {
    FileHandle.standardError.write("g8r-hook: could not parse hook JSON from stdin\n".data(using: .utf8)!)
    exit(0)
}

let collector = environment["G8R_COLLECTOR"] ?? EventBus.defaultSocketPath()
// Build sessions also say which component they are building.
let env = HookProcessor.Environment(paneId: paneId, component: environment["G8R_COMPONENT"])
for event in HookProcessor.process(payload: payload, env: env) {
    if let line = try? JSONEncoder().encode(event), let text = String(data: line, encoding: .utf8) {
        try? UnixSocketClient(path: collector).send(line: text) // best effort
    }
}
exit(0)
