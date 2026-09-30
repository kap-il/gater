import Foundation
import G8rCore

// g8r-hook: invoked by the Claude Code hooks g8r passes each session with
// --settings, which pipe the payload in; by Codex's notify, which g8r sets
// per launch as `g8r-hook codex-notify` and which appends the payload as an
// argument; and by the agent shims, as `g8r-hook agent-started <agent>`.
// Forwards what happened (starts, edits, commands, stops) to the G8r event
// bus.
// The decisions live in G8rCore.HookProcessor; this file only does I/O.
//
// Observation only, and fails open: nothing here ever blocks the agent.

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

// `g8r-hook claude-settings <file-or-json>`: a `claude` shim asks for the
// user's own --settings with g8r's hooks merged in. Prints the JSON, or
// fails so the shim passes the user's value on as it was.
if arguments.first == "claude-settings", arguments.count == 2 {
    let hook = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    guard let merged = try? HookInstaller.flagSettings(merging: arguments[1], hookBinary: hook,
                                                       directory: FileManager.default.currentDirectoryPath)
    else { exit(1) }
    print(merged)
    exit(0)
}

// Hooks also fire when someone runs the agent in the worktree outside
// G8r; only G8r panes set G8R_PANE_ID.
guard let paneId = environment["G8R_PANE_ID"], !paneId.isEmpty else { exit(0) }

// Build sessions also say which component they are building.
let env = HookProcessor.Environment(paneId: paneId, component: environment["G8R_COMPONENT"])
guard let events = HookProcessor.process(arguments: arguments,
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
