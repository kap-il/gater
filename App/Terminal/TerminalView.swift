import AppKit
import GaterTerminal

/// Draws one TerminalSession with CoreText and forwards keyboard, paste,
/// scroll, focus, and resize events to it.
///
/// Rendering reads a ScreenSnapshot (a copy of libghostty's render state),
/// so drawing never holds the terminal lock while it lays out text.
final class TerminalView: NSView {
    let session: TerminalSession
    private let font = TerminalFont()
    private let padding: CGFloat = 4
    private var scrollAccumulator: CGFloat = 0
    private var lastGrid: (cols: UInt16, rows: UInt16)?

    /// Called for every keystroke or paste the human sends to this pane;
    /// the pane manager uses it to log human_intervention on delegates.
    var onHumanInput: ((HumanInput) -> Void)?

    enum HumanInput {
        case typed(String)
        case backspace
        case submitted  // Enter pressed
        case pasted(String)
    }

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        session.onNeedsDisplay = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - Geometry

    /// Grid size (in cells) and the pixel metrics libghostty/TIOCSWINSZ need.
    static func gridSize(for bounds: CGSize, font: TerminalFont, padding: CGFloat) -> PTYSize {
        let cols = max(Int((bounds.width - 2 * padding) / font.cellSize.width), 1)
        let rows = max(Int((bounds.height - 2 * padding) / font.cellSize.height), 1)
        return PTYSize(cols: UInt16(min(cols, Int(UInt16.max))),
                       rows: UInt16(min(rows, Int(UInt16.max))),
                       cellWidth: UInt16(font.cellSize.width),
                       cellHeight: UInt16(font.cellSize.height))
    }

    /// Size for a fresh session before the view has been laid out.
    static func initialPTYSize(for bounds: CGSize) -> PTYSize {
        gridSize(for: bounds, font: TerminalFont(), padding: 4)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let size = Self.gridSize(for: newSize, font: font, padding: padding)
        if lastGrid?.cols != size.cols || lastGrid?.rows != size.rows {
            lastGrid = (size.cols, size.rows)
            session.resize(size)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let snap = session.core.snapshot()
        let cellH = font.cellSize.height

        ctx.setFillColor(snap.background.cgColor)
        ctx.fill(bounds)

        for (y, row) in snap.cells.enumerated() {
            let top = padding + CGFloat(y) * cellH
            drawBackgrounds(row: row, top: top, snap: snap, ctx: ctx)
            drawText(row: row, top: top, snap: snap)
        }

        if let cursor = snap.cursor {
            drawCursor(cursor, snap: snap, ctx: ctx)
        }
        if let bar = snap.scrollbar, bar.isScrollable, bar.offset + bar.visible < bar.total {
            drawScrollbar(bar, ctx: ctx)
        }
        if let status = session.exitStatus {
            drawExitBanner(status: status, ctx: ctx)
        }
    }

    private func resolvedColors(_ cell: Cell, snap: ScreenSnapshot) -> (fg: RGB, bg: RGB?) {
        var fg = cell.fg ?? snap.foreground
        var bg = cell.bg
        if cell.style.contains(.inverse) {
            let newFg = bg ?? snap.background
            bg = fg
            fg = newFg
        }
        return (fg, bg)
    }

    private func drawBackgrounds(row: [Cell], top: CGFloat, snap: ScreenSnapshot, ctx: CGContext) {
        let cellW = font.cellSize.width
        var x = 0
        while x < row.count {
            guard let bg = resolvedColors(row[x], snap: snap).bg else { x += 1; continue }
            var end = x + 1
            while end < row.count, resolvedColors(row[end], snap: snap).bg == bg { end += 1 }
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(x: padding + CGFloat(x) * cellW, y: top,
                            width: CGFloat(end - x) * cellW, height: font.cellSize.height))
            x = end
        }
    }

    /// Consecutive ASCII cells with identical attributes are drawn as one
    /// string (a monospace font keeps them on the grid). Anything else —
    /// wide chars, emoji, combining marks — is drawn alone at its own cell
    /// so a font-fallback advance can't push the rest of the row off-grid.
    private func drawText(row: [Cell], top: CGFloat, snap: ScreenSnapshot) {
        let cellW = font.cellSize.width
        var runStart = 0
        var runText = ""
        var runAttrs: [NSAttributedString.Key: Any]?

        func flush() {
            if let attrs = runAttrs, !runText.allSatisfy({ $0 == " " }) {
                NSAttributedString(string: runText, attributes: attrs)
                    .draw(at: NSPoint(x: padding + CGFloat(runStart) * cellW, y: top))
            }
            runText = ""
            runAttrs = nil
        }

        for (x, cell) in row.enumerated() {
            let attrs = attributes(for: cell, snap: snap)
            let isSimple = cell.text.isEmpty || (cell.text.unicodeScalars.count == 1 && cell.text.unicodeScalars.first!.isASCII)

            if !isSimple {
                flush()
                if !cell.style.contains(.invisible) {
                    NSAttributedString(string: cell.text, attributes: attrs)
                        .draw(at: NSPoint(x: padding + CGFloat(x) * cellW, y: top))
                }
                runStart = x + 1
                continue
            }

            let text = (cell.text.isEmpty || cell.style.contains(.invisible)) ? " " : cell.text
            if let current = runAttrs, !NSDictionary(dictionary: current).isEqual(to: attrs) {
                flush()
            }
            if runAttrs == nil {
                runStart = x
                runAttrs = attrs
            }
            runText += text
        }
        flush()
    }

    private func attributes(for cell: Cell, snap: ScreenSnapshot) -> [NSAttributedString.Key: Any] {
        let (fg, _) = resolvedColors(cell, snap: snap)
        var color = fg.nsColor
        if cell.style.contains(.faint) { color = color.withAlphaComponent(0.6) }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font.font(for: CellStyleFlags(bold: cell.style.contains(.bold),
                                                 italic: cell.style.contains(.italic))),
            .foregroundColor: color,
        ]
        if cell.style.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if cell.style.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    private func drawCursor(_ cursor: CursorState, snap: ScreenSnapshot, ctx: CGContext) {
        let cellW = font.cellSize.width
        let cellH = font.cellSize.height
        let rect = CGRect(x: padding + CGFloat(cursor.x) * cellW,
                          y: padding + CGFloat(cursor.y) * cellH,
                          width: cellW, height: cellH)
        let color = (cursor.color ?? snap.foreground).cgColor
        let focused = window?.isKeyWindow == true && window?.firstResponder === self

        switch (cursor.shape, focused) {
        case (.bar, _):
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        case (.underline, _):
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case (.blockHollow, _), (.block, false):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        case (.block, true):
            ctx.setFillColor(color.copy(alpha: 0.5) ?? color)
            ctx.fill(rect)
        }
    }

    private func drawScrollbar(_ bar: Scrollbar, ctx: CGContext) {
        let track = bounds.height
        let thumbHeight = max(track * CGFloat(bar.visible) / CGFloat(bar.total), 12)
        let scrollable = CGFloat(bar.total - bar.visible)
        let fraction = scrollable > 0 ? CGFloat(bar.offset) / scrollable : 1
        let thumb = CGRect(x: bounds.width - 8, y: fraction * (track - thumbHeight), width: 5, height: thumbHeight)
        ctx.setFillColor(NSColor(white: 0.8, alpha: 0.5).cgColor)
        ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.fillPath()
    }

    private func drawExitBanner(status: Int32, ctx: CGContext) {
        let message = "[process exited with status \(status)]"
        let attrs: [NSAttributedString.Key: Any] = [.font: font.regular, .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: message, attributes: attrs)
        let height = font.cellSize.height + 8
        ctx.setFillColor(NSColor(white: 0, alpha: 0.7).cgColor)
        ctx.fill(CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height))
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: bounds.height - height + 4))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        session.focusChanged(true)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        session.focusChanged(false)
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard session.isRunning else { return }
        let key = keyEvent(from: event, action: event.isARepeat ? .repeat : .press)
        session.send(key: key)

        switch event.keyCode {
        case 0x24, 0x4C: onHumanInput?(.submitted)  // Return / keypad Enter
        case 0x33: onHumanInput?(.backspace)
        default:
            if let text = key.text, key.mods.isDisjoint(with: [.control, .option, .command]) {
                onHumanInput?(.typed(text))
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard session.isRunning else { return }
        // Only produces bytes under the Kitty protocol's release reporting.
        session.send(key: keyEvent(from: event, action: .release))
    }

    /// Ctrl-combos like ctrl-tab / ctrl-/ come through here instead of
    /// keyDown; claim everything that isn't a Cmd shortcut for the menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              !event.modifierFlags.contains(.command),
              event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private func keyEvent(from event: NSEvent, action: KeyAction) -> KeyEvent {
        let flags = event.modifierFlags
        var mods: KeyMods = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }

        // Option acts as Alt/Meta (ESC-prefixed) rather than composing
        // characters like "å" — what CLI tools, Claude Code included, expect.
        let text: String? = flags.contains(.option)
            ? event.characters(byApplyingModifiers: flags.intersection(.shift))
            : event.characters

        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        return KeyEvent(keyCode: event.keyCode,
                        action: action,
                        mods: mods,
                        text: Self.printable(text),
                        unshiftedCodepoint: unshifted.flatMap { Self.isPrintable($0) ? $0.value : nil } ?? 0)
    }

    /// AppKit reports control characters (ctrl-c → U+0003) and private-use
    /// function-key codes (arrows → U+F700...) as "characters"; the encoder
    /// derives those from the key + mods, so only real text is passed on.
    private static func printable(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.unicodeScalars.allSatisfy(isPrintable) else { return nil }
        return text
    }

    private static func isPrintable(_ s: Unicode.Scalar) -> Bool {
        !(s.value < 0x20 || s.value == 0x7F || (0xF700...0xF8FF).contains(s.value))
    }

    // MARK: - Paste

    @objc func paste(_ sender: Any?) {
        guard session.isRunning, let text = NSPasteboard.general.string(forType: .string) else { return }
        session.paste(text)
        onHumanInput?(.pasted(text))
    }

    // MARK: - Scrollback

    override func scrollWheel(with event: NSEvent) {
        // Mouse-tracking programs would want wheel reports; that encoder
        // isn't wired up yet, so the wheel always scrolls history for now.
        let lineHeight = font.cellSize.height
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight * 3
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator / lineHeight)
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines) * lineHeight
        session.core.scrollViewport(delta: -lines)
        needsDisplay = true
    }
}

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var cgColor: CGColor { nsColor.cgColor }
}
