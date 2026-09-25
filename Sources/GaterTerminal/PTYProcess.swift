import Foundation
import GaterPTY

/// What to run in a pane.
public struct LaunchConfig: Sendable {
    /// Absolute path to the executable.
    public var executable: String
    /// Full argv, including argv[0].
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// The user's login shell, optionally running `command` first.
    ///
    /// Everything goes through a login shell so panes get the user's real
    /// PATH even when Gater is launched from Finder (where PATH is minimal).
    /// With a command, the pane drops back to an interactive shell when the
    /// command exits instead of dying — so quitting `claude` leaves you in
    /// the worktree.
    public static func loginShell(command: String? = nil,
                                  workingDirectory: String?,
                                  extraEnvironment: [String: String] = [:],
                                  baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchConfig {
        let shell = userShell(environment: baseEnvironment)
        let name = (shell as NSString).lastPathComponent
        var env = baseEnvironment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "gater"
        for (key, value) in extraEnvironment { env[key] = value }

        let args: [String]
        if let command {
            args = [name, "-l", "-c", "\(command); exec \(shellQuote(shell)) -l"]
        } else {
            args = ["-\(name)"] // leading dash = login shell, by convention
        }
        return LaunchConfig(executable: shell, arguments: args, environment: env,
                            workingDirectory: workingDirectory)
    }

    static func userShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct PTYSize: Equatable, Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public var cellWidth: UInt16
    public var cellHeight: UInt16

    public init(cols: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16) {
        self.cols = cols
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }
}

public enum PTYError: Error, CustomStringConvertible {
    case spawnFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .spawnFailed(code): return "forkpty failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A child process attached to a pseudo-terminal.
///
/// Reads happen on `readQueue` via a dispatch source; writes are serialized
/// on `writeQueue` (so `inject`, keystrokes, and terminal replies never
/// interleave mid-sequence, and a slow child never blocks the main thread).
/// Call `start()` after setting the callbacks.
public final class PTYProcess {
    public let pid: pid_t
    private let fd: Int32

    private let readQueue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "gater.pty.write")
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    /// Only touched on `writeQueue`; guards against writing to a closed fd
    /// whose number the kernel may have handed to something else.
    private var closed = false

    /// Output from the child, delivered on the read queue. The buffer is
    /// only valid for the duration of the call.
    public var onOutput: ((UnsafeRawBufferPointer) -> Void)?
    /// The child's exit status (128+signal if killed), on the read queue.
    public var onExit: ((Int32) -> Void)?

    public init(config: LaunchConfig, size: PTYSize,
                readQueue: DispatchQueue = DispatchQueue(label: "gater.pty.read")) throws {
        self.readQueue = readQueue

        // Build C argv/envp before forking: the child may only run
        // async-signal-safe code, so no allocation happens over there.
        let argv = config.arguments.map { strdup($0) } + [nil]
        let envp = config.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var fd: Int32 = -1
        var pid: pid_t = 0
        let rc = argv.withUnsafeBufferPointer { argvBuf in
            envp.withUnsafeBufferPointer { envpBuf in
                withOptionalCString(config.workingDirectory) { cwd in
                    gater_pty_spawn(config.executable, argvBuf.baseAddress, envpBuf.baseAddress, cwd,
                                    size.cols, size.rows, size.cellWidth, size.cellHeight, &fd, &pid)
                }
            }
        }
        guard rc == 0 else { throw PTYError.spawnFailed(errno: errno) }

        self.fd = fd
        self.pid = pid
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit {
        readSource?.cancel()
        exitSource?.cancel()
    }

    public func start() {
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.setCancelHandler { [writeQueue, fd] in
            writeQueue.async { close(fd) }
        }
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        exit.setEventHandler { [weak self] in self?.reap() }
        exitSource = exit

        read.resume()
        exit.resume()
    }

    /// Drains everything currently readable. The fd is non-blocking, so
    /// this stops at EAGAIN; EOF/EIO means the child side closed.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.withUnsafeBytes { onOutput?(UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { return }
            // EOF, or EIO once the slave is gone.
            markClosed()
            readSource?.cancel()
            readSource = nil
            // The exit source can miss a child that died before it was
            // armed; EOF is a second chance to reap it.
            reap()
            return
        }
    }

    private func markClosed() {
        writeQueue.async { [weak self] in self?.closed = true }
    }

    private func reap() {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        exitSource?.cancel()
        exitSource = nil
        // WIFEXITED / WEXITSTATUS / WTERMSIG are C macros Swift can't import.
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        onExit?(code)
    }

    /// Queues bytes for the child. Never blocks the caller.
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.writeAll(bytes)
        }
    }

    /// Runs on writeQueue. The fd is non-blocking (shared with the reader),
    /// so wait for POLLOUT on EAGAIN instead of dropping input — a large
    /// inject must arrive whole even if the child is momentarily busy.
    private func writeAll(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset)
            }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, 1000)
                if ready > 0 && (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 { return }
            } else {
                return
            }
        }
    }

    public func resize(_ size: PTYSize) {
        writeQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            _ = gater_pty_resize(self.fd, size.cols, size.rows, size.cellWidth, size.cellHeight)
        }
    }

    /// SIGHUP, like a terminal window closing.
    public func terminate() {
        kill(pid, SIGHUP)
    }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
