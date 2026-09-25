import Foundation
import GhosttyVT

public enum TerminalCoreError: Error, CustomStringConvertible {
    case ghostty(call: String, code: Int32)

    public var description: String {
        switch self {
        case let .ghostty(call, code): return "\(call) failed (GhosttyResult \(code))"
        }
    }
}

/// Owns one libghostty-vt terminal plus the render-state and encoder handles
/// that go with it.
///
/// libghostty's terminal isn't thread-safe, and in Gater bytes arrive on a
/// PTY read queue while drawing and key encoding happen on the main thread,
/// so every entry point takes `lock`. Effect callbacks fire synchronously
/// *inside* `feed(_:)` (already under the lock) and must never re-enter.
public final class TerminalCore {
    private let lock = NSLock()

    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var keyEncoder: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?

    public private(set) var cols: UInt16
    public private(set) var rows: UInt16
    private var cellWidth: UInt32 = 0
    private var cellHeight: UInt32 = 0

    /// Rows copied out of the render state, reused across snapshots and
    /// rebuilt only when libghostty marks them dirty.
    private var cachedRows: [[Cell]] = []

    /// Bytes the terminal wants sent back to the child (DSR replies, DA
    /// responses, mode reports). Called on whatever thread called `feed`.
    public var onWritePty: (([UInt8]) -> Void)?
    /// Called (on the feeding thread) when OSC 0/2 changes the title.
    public var onTitleChanged: ((String) -> Void)?
    /// Called (on the feeding thread) on BEL.
    public var onBell: (() -> Void)?

    public init(cols: UInt16, rows: UInt16, scrollbackLines: Int = 10_000) throws {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)

        try check("ghostty_terminal_new", ghostty_terminal_new(nil, &terminal, self.cols, self.rows))
        try check("ghostty_render_state_new", ghostty_render_state_new(nil, &renderState))
        try check("ghostty_render_state_row_iterator_new", ghostty_render_state_row_iterator_new(nil, &rowIterator))
        try check("ghostty_render_state_row_cells_new", ghostty_render_state_row_cells_new(nil, &rowCells))
        try check("ghostty_key_encoder_new", ghostty_key_encoder_new(nil, &keyEncoder))
        try check("ghostty_key_event_new", ghostty_key_event_new(nil, &keyEvent))
        try check("ghostty_mouse_encoder_new", ghostty_mouse_encoder_new(nil, &mouseEncoder))
        try check("ghostty_mouse_event_new", ghostty_mouse_event_new(nil, &mouseEvent))
        var trackLastCell = true // suppress repeat motion reports within one cell
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)

        var scrollback = scrollbackLines
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback)
        installEffects()
    }

    deinit {
        if let mouseEvent { ghostty_mouse_event_free(mouseEvent) }
        if let mouseEncoder { ghostty_mouse_encoder_free(mouseEncoder) }
        if let keyEvent { ghostty_key_event_free(keyEvent) }
        if let keyEncoder { ghostty_key_encoder_free(keyEncoder) }
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
    }

    // MARK: - Feeding and geometry

    /// Feeds raw PTY output through the VT parser.
    public func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        ghostty_terminal_vt_write(terminal, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    public func feed(_ string: String) {
        feed(Array(string.utf8))
    }

    /// Reflows the grid. Cell pixel size is needed for XTWINOPS pixel
    /// reports and image placement, so pass the real font metrics.
    public func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        lock.lock(); defer { lock.unlock() }
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        ghostty_terminal_resize(terminal, self.cols, self.rows, cellWidth, cellHeight)
    }

    // MARK: - Scrollback

    public func scrollViewport(delta: Int) {
        lock.lock(); defer { lock.unlock() }
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = delta
        ghostty_terminal_scroll_viewport(terminal, scroll)
    }

    public func scrollToBottom() {
        lock.lock(); defer { lock.unlock() }
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, scroll)
    }

    // MARK: - Modes

    /// Whether the running program asked for mouse reports; when it did,
    /// the wheel should go to the program rather than scroll history.
    public var isMouseTracking: Bool {
        lock.lock(); defer { lock.unlock() }
        var tracking = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    private func modeEnabled(_ code: UInt16) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(code, false), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
            return false
        }
        return config.value
    }

    // MARK: - Input encoding

    /// Encodes a key press into the bytes the child expects, honoring
    /// whatever modes the program set (application cursor keys, Kitty
    /// keyboard protocol, ...). Returns [] for keys that produce nothing.
    public func encode(key: KeyEvent) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let keyEncoder, let keyEvent else { return [] }

        ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)

        let action: GhosttyKeyAction
        switch key.action {
        case .press: action = GHOSTTY_KEY_ACTION_PRESS
        case .repeat: action = GHOSTTY_KEY_ACTION_REPEAT
        case .release: action = GHOSTTY_KEY_ACTION_RELEASE
        }
        ghostty_key_event_set_key(keyEvent, MacKeyMap.ghosttyKey(forKeyCode: key.keyCode))
        ghostty_key_event_set_action(keyEvent, action)
        ghostty_key_event_set_mods(keyEvent, key.mods.rawValue)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, key.unshiftedCodepoint)

        // Shift is "consumed" when the platform already applied it to the
        // text ('a' → 'A'); the encoder must not apply it a second time.
        var consumed: KeyMods = []
        if key.unshiftedCodepoint != 0 && key.mods.contains(.shift) { consumed.insert(.shift) }
        ghostty_key_event_set_consumed_mods(keyEvent, consumed.rawValue)

        let text = (key.action == .release) ? [] : Array((key.text ?? "").utf8)
        let capacity = 128 + text.count * 4
        var out = [UInt8](repeating: 0, count: capacity)
        var written = 0

        let result: GhosttyResult = text.withUnsafeBufferPointer { textBuf in
            textBuf.withMemoryRebound(to: CChar.self) { chars in
                ghostty_key_event_set_utf8(keyEvent, chars.isEmpty ? nil : chars.baseAddress, chars.count)
                return out.withUnsafeMutableBufferPointer { outBuf in
                    outBuf.withMemoryRebound(to: CChar.self) { outChars in
                        ghostty_key_encoder_encode(keyEncoder, keyEvent, outChars.baseAddress, capacity, &written)
                    }
                }
            }
        }
        // Don't leave the event pointing at the (now freed) text buffer.
        ghostty_key_event_set_utf8(keyEvent, nil, 0)

        guard result == GHOSTTY_SUCCESS else { return [] }
        return Array(out.prefix(written))
    }

    /// Encodes pasted text: wraps it in bracketed-paste markers when the
    /// program enabled mode 2004, so shells and TUIs (claude included)
    /// treat it as a paste rather than a burst of typing.
    public func encode(paste text: String) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let bracketed = modeEnabled(2004)
        var data = Array(text.utf8)
        let capacity = data.count + 32
        var out = [UInt8](repeating: 0, count: capacity)
        var written = 0
        let result: GhosttyResult = data.withUnsafeMutableBufferPointer { dataBuf in
            dataBuf.withMemoryRebound(to: CChar.self) { dataChars in
                out.withUnsafeMutableBufferPointer { outBuf in
                    outBuf.withMemoryRebound(to: CChar.self) { outChars in
                        ghostty_paste_encode(dataChars.baseAddress, dataChars.count, bracketed,
                                             outChars.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return Array(out.prefix(written))
    }

    /// Encodes a focus change, but only if the program enabled focus
    /// reporting (mode 1004) — shells that never asked would echo junk.
    public func encode(focus gained: Bool) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard modeEnabled(1004) else { return [] }
        var out = [CChar](repeating: 0, count: 8)
        var written = 0
        let result = ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
                                          &out, out.count, &written)
        guard result == GHOSTTY_SUCCESS else { return [] }
        return out.prefix(written).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Mouse

    /// Encodes a click/drag/move for programs that enabled mouse reporting
    /// (the encoder picks X10/SGR/... from the terminal's modes). Returns []
    /// when the program didn't ask for this kind of event.
    public func encode(mouse action: MouseAction, button: MouseButton?, at point: CGPoint,
                       mods: KeyMods, anyButtonPressed: Bool, geometry: MouseGeometry) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let ghosttyAction: GhosttyMouseAction
        switch action {
        case .press: ghosttyAction = GHOSTTY_MOUSE_ACTION_PRESS
        case .release: ghosttyAction = GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: ghosttyAction = GHOSTTY_MOUSE_ACTION_MOTION
        }
        return encodeMouseLocked(action: ghosttyAction, button: button.map(\.ghostty), at: point,
                                 mods: mods, anyButtonPressed: anyButtonPressed, geometry: geometry)
    }

    /// Handles `lines` of wheel movement (negative = up, into history) the
    /// way terminals conventionally do:
    /// - program enabled mouse reporting → wheel button presses (4/5);
    /// - full-screen program on the alternate screen with alternate-scroll
    ///   mode (1007) → arrow keys, so vim/less/top scroll their content;
    /// - otherwise → scroll our own scrollback, returning [].
    public func wheel(lines: Int, at point: CGPoint, mods: KeyMods, geometry: MouseGeometry) -> [UInt8] {
        guard lines != 0 else { return [] }
        lock.lock(); defer { lock.unlock() }

        var tracking = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        if tracking {
            let button = lines < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
            var out: [UInt8] = []
            for _ in 0..<abs(lines) {
                out += encodeMouseLocked(action: GHOSTTY_MOUSE_ACTION_PRESS, button: button, at: point,
                                         mods: mods, anyButtonPressed: false, geometry: geometry)
            }
            return out
        }

        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        if screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE && modeEnabled(1007) {
            let applicationCursor = modeEnabled(1) // DECCKM
            let arrow = lines < 0 ? "A" : "B"
            let sequence = (applicationCursor ? "\u{1b}O" : "\u{1b}[") + arrow
            return Array(String(repeating: sequence, count: abs(lines)).utf8)
        }

        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = lines
        ghostty_terminal_scroll_viewport(terminal, scroll)
        return []
    }

    private func encodeMouseLocked(action: GhosttyMouseAction, button: GhosttyMouseButton?, at point: CGPoint,
                                   mods: KeyMods, anyButtonPressed: Bool, geometry: MouseGeometry) -> [UInt8] {
        guard let mouseEncoder, let mouseEvent else { return [] }
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)

        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = geometry.screenWidth
        size.screen_height = geometry.screenHeight
        size.cell_width = geometry.cellWidth
        size.cell_height = geometry.cellHeight
        size.padding_top = geometry.padding
        size.padding_bottom = geometry.padding
        size.padding_left = geometry.padding
        size.padding_right = geometry.padding
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = anyButtonPressed
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)

        ghostty_mouse_event_set_action(mouseEvent, action)
        if let button { ghostty_mouse_event_set_button(mouseEvent, button) } else { ghostty_mouse_event_clear_button(mouseEvent) }
        ghostty_mouse_event_set_mods(mouseEvent, mods.rawValue)
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(point.x), y: Float(point.y)))

        var out = [CChar](repeating: 0, count: 64)
        var written = 0
        guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &out, out.count, &written) == GHOSTTY_SUCCESS else {
            return []
        }
        return out.prefix(written).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Rendering snapshot

    /// Copies what's needed to draw one frame out of libghostty. Only rows
    /// libghostty marks dirty are rebuilt; the rest come from the cache.
    public func snapshot() -> ScreenSnapshot {
        lock.lock(); defer { lock.unlock() }

        ghostty_render_state_update(renderState, terminal)

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_colors_get(renderState, &colors)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)

        var stateCols: UInt16 = 0
        var stateRows: UInt16 = 0
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &stateCols)
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &stateRows)

        let rebuildAll = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || cachedRows.count != Int(stateRows)
        if cachedRows.count != Int(stateRows) {
            cachedRows = Array(repeating: [], count: Int(stateRows))
        }

        if ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator) == GHOSTTY_SUCCESS {
            var y = 0
            while ghostty_render_state_row_iterator_next(rowIterator), y < cachedRows.count {
                var rowDirty = false
                ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if rebuildAll || rowDirty || cachedRows[y].count != Int(stateCols) {
                    cachedRows[y] = readRow(expectedCols: Int(stateCols))
                }
                var clean = false
                ghostty_render_state_row_set(rowIterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
                y += 1
            }
        }

        var cleanState = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &cleanState)

        var scrollbar: Scrollbar?
        var bar = GhosttyTerminalScrollbar()
        if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) == GHOSTTY_SUCCESS {
            scrollbar = Scrollbar(total: bar.total, offset: bar.offset, visible: bar.len)
        }

        return ScreenSnapshot(
            cols: Int(stateCols),
            rows: Int(stateRows),
            cells: cachedRows,
            foreground: RGB(colors.foreground),
            background: RGB(colors.background),
            cursor: readCursor(colors: colors),
            scrollbar: scrollbar
        )
    }

    private func readRow(expectedCols: Int) -> [Cell] {
        var row: [Cell] = []
        row.reserveCapacity(expectedCols)
        guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells) == GHOSTTY_SUCCESS else {
            return Array(repeating: .blank, count: expectedCols)
        }

        var codepoints = [UInt32](repeating: 0, count: 16)
        while ghostty_render_state_row_cells_next(rowCells) {
            var cell = Cell.blank

            var graphemeLen: UInt32 = 0
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLen)
            if graphemeLen > 0 {
                if codepoints.count < Int(graphemeLen) {
                    codepoints = [UInt32](repeating: 0, count: Int(graphemeLen))
                }
                codepoints.withUnsafeMutableBytes { buf in
                    _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf.baseAddress)
                }
                var scalars = String.UnicodeScalarView()
                for cp in codepoints.prefix(Int(graphemeLen)) {
                    scalars.append(Unicode.Scalar(cp) ?? "\u{FFFD}")
                }
                cell.text = String(scalars)
            }

            var hasStyling = false
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
            if hasStyling {
                // FG/BG queries flatten SGR colors, palette indices, and
                // content-tag colors into RGB; INVALID/NO_VALUE = default.
                var fg = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS {
                    cell.fg = RGB(fg)
                }
                var bg = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS {
                    cell.bg = RGB(bg)
                }
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS {
                    cell.style = CellStyle(style)
                }
            }
            row.append(cell)
        }

        if row.count < expectedCols {
            row.append(contentsOf: Array(repeating: .blank, count: expectedCols - row.count))
        }
        return row
    }

    private func readCursor(colors: GhosttyRenderStateColors) -> CursorState? {
        var visible = false
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        var inViewport = false
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport)
        guard visible, inViewport else { return nil }

        var x: UInt16 = 0
        var y: UInt16 = 0
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)

        var visual = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &visual)
        let shape: CursorShape
        switch visual {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: shape = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: shape = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: shape = .blockHollow
        default: shape = .block
        }

        return CursorState(x: Int(x), y: Int(y), shape: shape,
                           color: colors.cursor_has_value ? RGB(colors.cursor) : nil)
    }

    // MARK: - Effects (libghostty → embedder callbacks)

    private func installEffects() {
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)

        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data, len > 0 else { return }
            let core = Unmanaged<TerminalCore>.fromOpaque(userdata).takeUnretainedValue()
            core.onWritePty?(Array(UnsafeBufferPointer(start: data, count: len)))
        }
        let titleChanged: GhosttyTerminalTitleChangedFn = { terminal, userdata in
            guard let userdata else { return }
            let core = Unmanaged<TerminalCore>.fromOpaque(userdata).takeUnretainedValue()
            var title = GhosttyString()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS,
                  let ptr = title.ptr else { return }
            let text = String(decoding: UnsafeBufferPointer(start: ptr, count: title.len), as: UTF8.self)
            core.onTitleChanged?(text)
        }
        let bell: GhosttyTerminalBellFn = { _, userdata in
            guard let userdata else { return }
            Unmanaged<TerminalCore>.fromOpaque(userdata).takeUnretainedValue().onBell?()
        }
        // XTWINOPS size queries (CSI 14/16/18 t).
        let size: GhosttyTerminalSizeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let core = Unmanaged<TerminalCore>.fromOpaque(userdata).takeUnretainedValue()
            out.pointee.rows = core.rows
            out.pointee.columns = core.cols
            out.pointee.cell_width = core.cellWidth
            out.pointee.cell_height = core.cellHeight
            return true
        }
        // DA1/DA2/DA3: programs probe these at startup and some block
        // waiting for a reply. Report VT220 with a modest feature set,
        // same as Ghostling.
        let deviceAttributes: GhosttyTerminalDeviceAttributesFn = { _, _, out in
            guard let out else { return false }
            out.pointee.primary.conformance_level = 62 // GHOSTTY_DA_CONFORMANCE_VT220
            out.pointee.primary.features.0 = 1         // COLUMNS_132
            out.pointee.primary.features.1 = 6         // SELECTIVE_ERASE
            out.pointee.primary.features.2 = 22        // ANSI_COLOR
            out.pointee.primary.num_features = 3
            out.pointee.secondary.device_type = 1      // GHOSTTY_DA_DEVICE_TYPE_VT220
            out.pointee.secondary.firmware_version = 1
            out.pointee.secondary.rom_cartridge = 0
            out.pointee.tertiary.unit_id = 0
            return true
        }
        let xtversion: GhosttyTerminalXtversionFn = { _, _ in
            GhosttyString(ptr: TerminalCore.xtversionBytes, len: TerminalCore.xtversionLength)
        }

        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(deviceAttributes, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self))
    }

    // Static so the pointer outlives every XTVERSION callback.
    private static let xtversionLength = 5
    private static let xtversionBytes: UnsafePointer<UInt8> = {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: xtversionLength)
        buf.initialize(from: Array("gater".utf8), count: xtversionLength)
        return UnsafePointer(buf)
    }()

    private func check(_ call: String, _ result: GhosttyResult) throws {
        guard result == GHOSTTY_SUCCESS else {
            throw TerminalCoreError.ghostty(call: call, code: result.rawValue)
        }
    }
}

extension RGB {
    init(_ c: GhosttyColorRgb) {
        self.init(r: c.r, g: c.g, b: c.b)
    }
}

extension CellStyle {
    init(_ s: GhosttyStyle) {
        var style: CellStyle = []
        if s.bold { style.insert(.bold) }
        if s.italic { style.insert(.italic) }
        if s.faint { style.insert(.faint) }
        if s.inverse { style.insert(.inverse) }
        if s.invisible { style.insert(.invisible) }
        if s.strikethrough { style.insert(.strikethrough) }
        if s.underline != 0 { style.insert(.underline) }
        self = style
    }
}

public enum MouseAction: Sendable {
    case press, release, motion
}

public enum MouseButton: Sendable {
    case left, right, middle

    var ghostty: GhosttyMouseButton {
        switch self {
        case .left: return GHOSTTY_MOUSE_BUTTON_LEFT
        case .right: return GHOSTTY_MOUSE_BUTTON_RIGHT
        case .middle: return GHOSTTY_MOUSE_BUTTON_MIDDLE
        }
    }
}

/// View geometry the mouse encoder needs to turn points into cells. All
/// values share one unit (points, in Gater), with y measured from the top.
public struct MouseGeometry: Sendable {
    public var screenWidth: UInt32
    public var screenHeight: UInt32
    public var cellWidth: UInt32
    public var cellHeight: UInt32
    public var padding: UInt32

    public init(screenWidth: UInt32, screenHeight: UInt32, cellWidth: UInt32, cellHeight: UInt32, padding: UInt32) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.padding = padding
    }
}
