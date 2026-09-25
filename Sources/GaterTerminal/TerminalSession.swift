import Foundation

/// One running terminal: a child on a PTY feeding a libghostty terminal.
///
/// This is the pane's engine with no UI in it — TerminalView draws its
/// snapshots and forwards input, and Gater itself drives it through
/// `inject(text:submit:)` to wake the orchestrator.
///
/// Callbacks are delivered on the main queue.
public final class TerminalSession {
    public let core: TerminalCore
    public let process: PTYProcess

    public var onNeedsDisplay: (() -> Void)?
    public var onTitleChanged: ((String) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public private(set) var title: String = ""
    public private(set) var exitStatus: Int32?

    private let displayLock = NSLock()
    private var displayScheduled = false

    public init(config: LaunchConfig, size: PTYSize) throws {
        core = try TerminalCore(cols: size.cols, rows: size.rows)
        core.resize(cols: size.cols, rows: size.rows,
                    cellWidth: UInt32(size.cellWidth), cellHeight: UInt32(size.cellHeight))
        process = try PTYProcess(config: config, size: size)

        // Replies the terminal generates (DSR, DA, ...) go straight back to
        // the child; this runs on the read queue inside core.feed.
        core.onWritePty = { [weak process] bytes in process?.write(bytes) }
        core.onTitleChanged = { [weak self] title in
            DispatchQueue.main.async {
                guard let self else { return }
                self.title = title
                self.onTitleChanged?(title)
            }
        }
        process.onOutput = { [weak self] bytes in
            guard let self else { return }
            self.core.feed(bytes)
            self.scheduleDisplay()
        }
        process.onExit = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exitStatus = status
                self.onExit?(status)
                self.onNeedsDisplay?()
            }
        }
        process.start()
    }

    public var isRunning: Bool { exitStatus == nil }

    /// Coalesces a burst of PTY reads into one redraw per main-queue turn.
    private func scheduleDisplay() {
        displayLock.lock()
        let alreadyScheduled = displayScheduled
        displayScheduled = true
        displayLock.unlock()
        guard !alreadyScheduled else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayLock.lock()
            self.displayScheduled = false
            self.displayLock.unlock()
            self.onNeedsDisplay?()
        }
    }

    // MARK: - Input

    /// Raw bytes to the child, as if typed.
    public func send(_ bytes: [UInt8]) {
        process.write(bytes)
    }

    /// A key press from the UI. Snaps the viewport back to the live screen,
    /// like every terminal does when you start typing in scrollback.
    public func send(key: KeyEvent) {
        let bytes = core.encode(key: key)
        guard !bytes.isEmpty else { return }
        core.scrollToBottom()
        process.write(bytes)
    }

    public func paste(_ text: String) {
        core.scrollToBottom()
        process.write(core.encode(paste: text))
    }

    /// Writes `text` into the pane as if the user entered it.
    ///
    /// Sent as a paste (bracketed when the program enabled it) so multi-line
    /// text lands as one block instead of each newline submitting early —
    /// Claude Code's input box relies on this. With `submit`, a carriage
    /// return follows, which is what pressing Enter sends.
    public func inject(text: String, submit: Bool = false) {
        var bytes = core.encode(paste: text)
        if submit { bytes.append(0x0D) }
        core.scrollToBottom()
        process.write(bytes)
    }

    public func focusChanged(_ gained: Bool) {
        process.write(core.encode(focus: gained))
    }

    // MARK: - Geometry and lifecycle

    public func resize(_ size: PTYSize) {
        core.resize(cols: size.cols, rows: size.rows,
                    cellWidth: UInt32(size.cellWidth), cellHeight: UInt32(size.cellHeight))
        process.resize(size)
        onNeedsDisplay?()
    }

    public func terminate() {
        process.terminate()
    }
}
