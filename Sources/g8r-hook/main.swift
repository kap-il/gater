import Foundation
import G8rCore

// g8r-hook: invoked by the Claude Code hooks G8r installs into each
// pane's worktree (.claude/settings.local.json), which pipe the payload in,
// and by Codex's notify, which G8r sets per launch as
// `g8r-hook codex-notify` and which appends the payload as an argument.
// Forwards what happened (edits, commands, stops) to the G8r event bus.
// The decisions live in G8rCore.HookProcessor; this file only does I/O.
//
// Observation only, and fails open: nothing here ever blocks the agent.

let environment = ProcessInfo.processInfo.environment

// Hooks also fire when someone runs the agent in the worktree outside
// G8r; only G8r panes set G8R_PANE_ID.
guard let paneId = environment["G8R_PANE_ID"], !paneId.isEmpty else { exit(0) }

// Build sessions also say which component they are building.
let env = HookProcessor.Environment(paneId: paneId, component: environment["G8R_COMPONENT"])
guard let events = HookProcessor.process(arguments: Array(CommandLine.arguments.dropFirst()),
                                         stdin: { FileHandle.standardInput.readDataToEndOfFile() },
                                         env: env) else {
    FileHandle.standardError.write("g8r-hook: could not parse the hook payload\n".data(using: .utf8)!)
    exit(0)
}

let collector = environment["G8R_COLLECTOR"] ?? EventBus.defaultSocketPath()
for event in events {
    if let line = try? JSONEncoder().encode(event), let text = String(data: line, encoding: .utf8) {
        try? UnixSocketClient(path: collector).send(line: text) // best effort
    }
}
exit(0)
