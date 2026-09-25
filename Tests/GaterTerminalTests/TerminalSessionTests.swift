import XCTest
@testable import GaterTerminal

final class TerminalSessionTests: XCTestCase {
    private let size = PTYSize(cols: 40, rows: 5, cellWidth: 8, cellHeight: 16)

    /// Spins the main run loop (session callbacks land on main) until
    /// `condition` holds or the timeout passes.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testChildOutputReachesGridAndExitIsReported() throws {
        let config = LaunchConfig(executable: "/bin/sh",
                                  arguments: ["sh", "-c", "printf 'hi from pty'; exit 3"],
                                  environment: ["PATH": "/usr/bin:/bin"])
        let session = try TerminalSession(config: config, size: size)
        XCTAssertTrue(waitUntil { session.exitStatus != nil })
        XCTAssertEqual(session.exitStatus, 3)
        XCTAssertEqual(session.core.snapshot().text(row: 0), "hi from pty")
    }

    func testInjectReachesChildStdin() throws {
        // `read` then echo back what arrived, so the grid proves the round trip.
        let config = LaunchConfig(executable: "/bin/sh",
                                  arguments: ["sh", "-c", "read line; printf \"got:%s\" \"$line\""],
                                  environment: ["PATH": "/usr/bin:/bin"])
        let session = try TerminalSession(config: config, size: size)
        session.inject(text: "wake up", submit: true)
        XCTAssertTrue(waitUntil { session.exitStatus != nil })
        let snap = session.core.snapshot()
        let all = (0..<snap.rows).map { snap.text(row: $0) }.joined(separator: "\n")
        XCTAssertTrue(all.contains("got:wake up"), all)
    }

    func testWorkingDirectoryAndEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let config = LaunchConfig(executable: "/bin/sh",
                                  arguments: ["sh", "-c", "printf '%s|%s' \"$PWD\" \"$GATER_PANE_ID\""],
                                  environment: ["PATH": "/usr/bin:/bin", "GATER_PANE_ID": "p-42"],
                                  workingDirectory: dir)
        let session = try TerminalSession(config: config, size: PTYSize(cols: 120, rows: 3, cellWidth: 8, cellHeight: 16))
        XCTAssertTrue(waitUntil { session.exitStatus != nil })
        let text = session.core.snapshot().text(row: 0)
        XCTAssertTrue(text.hasSuffix("|p-42"), text)
        XCTAssertTrue(text.contains((dir as NSString).lastPathComponent), text)
    }

    func testLoginShellConfigWrapsCommand() {
        let config = LaunchConfig.loginShell(command: "claude", workingDirectory: "/tmp",
                                             extraEnvironment: ["GATER_ROLE": "delegate"],
                                             baseEnvironment: ["SHELL": "/bin/zsh", "HOME": "/Users/x"])
        XCTAssertEqual(config.executable, "/bin/zsh")
        XCTAssertEqual(config.arguments, ["zsh", "-l", "-c", "claude; exec '/bin/zsh' -l"])
        XCTAssertEqual(config.environment["GATER_ROLE"], "delegate")
        XCTAssertEqual(config.environment["TERM"], "xterm-256color")
        XCTAssertEqual(config.workingDirectory, "/tmp")

        let plain = LaunchConfig.loginShell(workingDirectory: nil, baseEnvironment: ["SHELL": "/bin/zsh"])
        XCTAssertEqual(plain.arguments, ["-zsh"])
    }

    /// Closing a pane must take down the agent running *under* the pane's
    /// shell, not just the shell (panes run `zsh -l -c "claude; exec zsh -l"`).
    func testTerminateKillsGrandchildProcess() throws {
        let marker = "gater-kill-test-\(UUID().uuidString.prefix(8))"
        let config = LaunchConfig.loginShell(command: "/bin/zsh -fc 'exec -a \(marker) sleep 300'", workingDirectory: nil,
                                             baseEnvironment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"])
        let session = try TerminalSession(config: config, size: size)
        XCTAssertTrue(waitUntil { Self.isRunning(marker) }, "agent stand-in never started")
        XCTAssertNotEqual(Self.pid(of: marker), session.process.pid, "stand-in must be a grandchild, not the shell")

        session.terminate()
        XCTAssertTrue(waitUntil { session.exitStatus != nil })
        XCTAssertTrue(waitUntil { !Self.isRunning(marker) }, "agent stand-in survived terminate()")
    }

    private static func pid(of pattern: String) -> pid_t? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "^" + pattern] // argv0 only, not shells quoting it
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    private static func isRunning(_ pattern: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "^" + pattern] // argv0 only, not shells quoting it
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
