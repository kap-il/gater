import Foundation

/// The real `CommandRunner`: starts a program and waits for it.
public enum ProcessRunner {
    public enum RunnerError: Error, Equatable, CustomStringConvertible {
        case couldNotStart(String)
        case timedOut(String, output: String)

        public var description: String {
            switch self {
            case let .couldNotStart(reason): return reason
            case let .timedOut(executable, output):
                return "\(executable) was stopped after running too long\(output.isEmpty ? "" : ":\n" + output)"
            }
        }
    }

    /// Runs in `directory` through a login shell, so programs on the user's
    /// PATH are found even when the app was opened from Finder. Output and
    /// errors come back as one string.
    public static func runner(in directory: String, timeout: TimeInterval = 600) -> CommandRunner {
        { executable, arguments, stdin in
            try run(executable, arguments, stdin: stdin, in: directory, timeout: timeout)
        }
    }

    private static func run(_ executable: String, _ arguments: [String], stdin: String?,
                            in directory: String, timeout: TimeInterval) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The shell only finds the program; `exec` hands it the arguments
        // untouched, so nothing in them is read as shell syntax.
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", executable] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw RunnerError.couldNotStart("couldn't run \(executable): \(error)")
        }

        // Written and read on their own threads, so a program that talks
        // before it has read everything can't wedge both sides of a pipe.
        if let stdin {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        var data = Data()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }

        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            finished.wait()
        }
        read.wait()
        let text = String(decoding: data, as: UTF8.self)
        if timedOut { throw RunnerError.timedOut(executable, output: text) }
        return (process.terminationStatus, text)
    }
}
