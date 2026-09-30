import Foundation

/// Runs the project's tests and keeps what they showed in the plan root:
/// `.g8r/test.log`, the raw output, and `.g8r/tests.json`, the report.
/// Each run also logs a `tests_ran` event.
public enum TestRunner {
    /// Runs the command, writes the log and the report, returns the report.
    public static func run(command: String, codeRoot: String, planRoot: String,
                           timeout: TimeInterval) -> TestReport {
        runKeepingOutput(command: command, codeRoot: codeRoot, planRoot: planRoot, timeout: timeout).report
    }

    /// The report `run` last wrote; nil before the first run, or when the
    /// file can't be read.
    public static func lastReport(planRoot: String) -> TestReport? {
        guard let data = try? Data(contentsOf: reportURL(planRoot: planRoot)) else { return nil }
        return try? JSONDecoder().decode(TestReport.self, from: data)
    }

    static func logURL(planRoot: String) -> URL {
        URL(fileURLWithPath: planRoot).appendingPathComponent(".g8r/test.log")
    }

    static func reportURL(planRoot: String) -> URL {
        URL(fileURLWithPath: planRoot).appendingPathComponent(".g8r/tests.json")
    }

    /// `run`, also handing back the output for callers that show it.
    static func runKeepingOutput(command: String, codeRoot: String, planRoot: String,
                                 timeout: TimeInterval) -> (report: TestReport, output: String) {
        let started = Date()
        let (output, exit) = execute(command, in: codeRoot, timeout: timeout)
        let report = TestReport.parse(output: output, command: command, exit: exit, ranAt: started)
        record(report, output: output, planRoot: planRoot)
        return (report, output)
    }

    private static func record(_ report: TestReport, output: String, planRoot: String) {
        let directory = URL(fileURLWithPath: planRoot).appendingPathComponent(".g8r")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(output.utf8).write(to: logURL(planRoot: planRoot), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: reportURL(planRoot: planRoot), options: .atomic)
        }
        if let log = try? EventLog(path: directory.appendingPathComponent("events.jsonl")) {
            _ = try? log.append(G8rEvent(kind: "tests_ran", extra: [
                "passed": .number(Double(report.passed)),
                "failed": .number(Double(report.failed)),
                "exit": .number(Double(report.exit)),
                "command": .string(report.command),
            ]))
            log.close()
        }
    }

    // MARK: - Running

    /// Runs the command through a login shell in `directory` and returns
    /// its output and exit status. A run that outlasts `timeout` is
    /// stopped, with everything it started, and exits non-zero; a quiet
    /// command can't hold it past the deadline, because the output is read
    /// on a thread of its own and the wait is on the process, not the pipe.
    static func execute(_ command: String, in directory: String,
                        timeout: TimeInterval) -> (output: String, exit: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return ("couldn't run \(command): \(error)\n", 127)
        }
        let output = Collected()
        let reading = DispatchGroup()
        reading.enter()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    output.append(buffer[0..<count])
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            reading.leave()
        }

        // Foundation starts the child as the leader of its own process
        // group, so signalling the group reaches whatever the shell started.
        let group = process.processIdentifier
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(-group, SIGTERM)
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(-group, SIGKILL)
                finished.wait()
            }
        }
        // Something the command left running in the background may still
        // hold the pipe open; it gets a moment, then it is stopped too.
        if reading.wait(timeout: .now() + 2) == .timedOut {
            kill(-group, SIGKILL)
            _ = reading.wait(timeout: .now() + 2)
        }

        var text = output.text
        var exit = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus : process.terminationStatus
        if timedOut {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "g8r: stopped the tests after \(Int(timeout.rounded())) seconds\n"
            if exit == 0 { exit = 124 }
        }
        return (text, exit)
    }

    /// Output gathered on the reading thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ bytes: ArraySlice<UInt8>) {
            lock.lock()
            data.append(contentsOf: bytes)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
