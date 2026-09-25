import XCTest
@testable import GaterTerminal

final class TerminalCoreTests: XCTestCase {
    func testPlainTextLandsInGrid() throws {
        let core = try TerminalCore(cols: 20, rows: 4)
        core.feed("hello\r\nworld")
        let snap = core.snapshot()
        XCTAssertEqual(snap.cols, 20)
        XCTAssertEqual(snap.rows, 4)
        XCTAssertEqual(snap.text(row: 0), "hello")
        XCTAssertEqual(snap.text(row: 1), "world")
        XCTAssertEqual(snap.cursor?.x, 5)
        XCTAssertEqual(snap.cursor?.y, 1)
    }

    func testSGRColorsAndStyles() throws {
        let core = try TerminalCore(cols: 20, rows: 2)
        core.feed("a\u{1b}[1;38;2;255;0;0mb\u{1b}[0;44mc\u{1b}[0m")
        let row = core.snapshot().cells[0]
        XCTAssertNil(row[0].fg)
        XCTAssertEqual(row[0].style, [])
        XCTAssertEqual(row[1].fg, RGB(r: 255, g: 0, b: 0))
        XCTAssertTrue(row[1].style.contains(.bold))
        XCTAssertNotNil(row[2].bg, "palette color 4 should resolve to RGB")
        XCTAssertFalse(row[2].style.contains(.bold))
    }

    func testDirtyRowCacheSeesLaterWrites() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        core.feed("one")
        XCTAssertEqual(core.snapshot().text(row: 0), "one")
        core.feed("\r\ntwo")
        let snap = core.snapshot()
        XCTAssertEqual(snap.text(row: 0), "one")
        XCTAssertEqual(snap.text(row: 1), "two")
        core.feed("\u{1b}[2J\u{1b}[H")
        XCTAssertEqual(core.snapshot().text(row: 1), "")
    }

    func testResizeChangesGrid() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        core.resize(cols: 40, rows: 12, cellWidth: 8, cellHeight: 16)
        let snap = core.snapshot()
        XCTAssertEqual(snap.cols, 40)
        XCTAssertEqual(snap.rows, 12)
        XCTAssertEqual(snap.cells.count, 12)
        XCTAssertEqual(snap.cells[0].count, 40)
    }

    func testWritePtyEffectAnswersCursorPositionReport() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        var replies: [[UInt8]] = []
        core.onWritePty = { replies.append($0) }
        core.feed("ab\u{1b}[6n")
        XCTAssertEqual(replies.map { String(decoding: $0, as: UTF8.self) }, ["\u{1b}[1;3R"])
    }

    func testTitleEffect() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        var title: String?
        core.onTitleChanged = { title = $0 }
        core.feed("\u{1b}]2;my pane\u{07}")
        XCTAssertEqual(title, "my pane")
    }

    func testHiddenCursorIsNil() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        core.feed("\u{1b}[?25l")
        XCTAssertNil(core.snapshot().cursor)
    }

    // MARK: - Key encoding

    private func encode(_ core: TerminalCore, _ event: KeyEvent) -> String {
        String(decoding: core.encode(key: event), as: UTF8.self)
    }

    func testPrintableKey() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        XCTAssertEqual(encode(core, KeyEvent(keyCode: 0x00, text: "a", unshiftedCodepoint: 0x61)), "a")
        XCTAssertEqual(encode(core, KeyEvent(keyCode: 0x00, mods: .shift, text: "A", unshiftedCodepoint: 0x61)), "A")
    }

    func testControlKeys() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        XCTAssertEqual(core.encode(key: KeyEvent(keyCode: 0x08, mods: .control, unshiftedCodepoint: 0x63)), [0x03], "ctrl-c")
        XCTAssertEqual(core.encode(key: KeyEvent(keyCode: 0x24)), [0x0D], "enter")
        XCTAssertEqual(core.encode(key: KeyEvent(keyCode: 0x33)), [0x7F], "backspace")
        XCTAssertEqual(core.encode(key: KeyEvent(keyCode: 0x30)), [0x09], "tab")
        XCTAssertEqual(core.encode(key: KeyEvent(keyCode: 0x35)), [0x1B], "escape")
    }

    func testArrowKeysFollowCursorKeyMode() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        XCTAssertEqual(encode(core, KeyEvent(keyCode: 0x7E)), "\u{1b}[A")
        core.feed("\u{1b}[?1h") // DECCKM: application cursor keys
        XCTAssertEqual(encode(core, KeyEvent(keyCode: 0x7E)), "\u{1b}OA")
    }

    func testReleaseProducesNothingByDefault() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        XCTAssertEqual(core.encode(key: KeyEvent(keyCode: 0x00, action: .release, unshiftedCodepoint: 0x61)), [])
    }

    // MARK: - Paste and focus

    func testPasteIsBracketedOnlyWhenRequested() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        XCTAssertEqual(String(decoding: core.encode(paste: "hi"), as: UTF8.self), "hi")
        core.feed("\u{1b}[?2004h")
        XCTAssertEqual(String(decoding: core.encode(paste: "hi"), as: UTF8.self), "\u{1b}[200~hi\u{1b}[201~")
    }

    func testFocusOnlyWhenRequested() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        XCTAssertEqual(core.encode(focus: true), [])
        core.feed("\u{1b}[?1004h")
        XCTAssertEqual(String(decoding: core.encode(focus: true), as: UTF8.self), "\u{1b}[I")
        XCTAssertEqual(String(decoding: core.encode(focus: false), as: UTF8.self), "\u{1b}[O")
    }

    // MARK: - Scrollback

    func testScrollbackAndViewportScroll() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        core.feed((1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        var snap = core.snapshot()
        XCTAssertEqual(snap.text(row: 2), "line10")
        XCTAssertEqual(snap.scrollbar?.isScrollable, true)

        core.scrollViewport(delta: -2)
        snap = core.snapshot()
        XCTAssertEqual(snap.text(row: 2), "line8")

        core.scrollToBottom()
        XCTAssertEqual(core.snapshot().text(row: 2), "line10")
    }

    // MARK: - Mouse and wheel

    private let geometry = MouseGeometry(screenWidth: 800, screenHeight: 480, cellWidth: 8,
                                         cellHeight: 16, padding: 0)

    func testWheelScrollsScrollbackOnPrimaryScreen() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        core.feed((1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        XCTAssertEqual(core.wheel(lines: -2, at: .zero, mods: [], geometry: geometry), [])
        XCTAssertEqual(core.snapshot().text(row: 2), "line8")
    }

    func testWheelSendsArrowsOnAlternateScreen() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        core.feed("\u{1b}[?1049h") // vim/less/top enter the alt screen but never set 1007
        XCTAssertEqual(String(decoding: core.wheel(lines: -2, at: .zero, mods: [], geometry: geometry), as: UTF8.self),
                       "\u{1b}[A\u{1b}[A")
        core.feed("\u{1b}[?1h")
        XCTAssertEqual(String(decoding: core.wheel(lines: 1, at: .zero, mods: [], geometry: geometry), as: UTF8.self),
                       "\u{1b}OB")
    }

    func testWheelAndClicksReportedWhenProgramTracksMouse() throws {
        let core = try TerminalCore(cols: 100, rows: 30)
        core.feed("\u{1b}[?1000h\u{1b}[?1006h") // normal tracking, SGR format
        let point = CGPoint(x: 8 * 4 + 1, y: 16 * 2 + 1) // cell (col 5, row 3), 1-based
        XCTAssertEqual(String(decoding: core.wheel(lines: -1, at: point, mods: [], geometry: geometry), as: UTF8.self),
                       "\u{1b}[<64;5;3M")
        XCTAssertEqual(String(decoding: core.encode(mouse: .press, button: .left, at: point, mods: [],
                                                    anyButtonPressed: true, geometry: geometry), as: UTF8.self),
                       "\u{1b}[<0;5;3M")
        XCTAssertEqual(String(decoding: core.encode(mouse: .release, button: .left, at: point, mods: [],
                                                    anyButtonPressed: false, geometry: geometry), as: UTF8.self),
                       "\u{1b}[<0;5;3m")
    }

    func testNoMouseReportsWithoutTracking() throws {
        let core = try TerminalCore(cols: 10, rows: 3)
        XCTAssertEqual(core.encode(mouse: .press, button: .left, at: .zero, mods: [],
                                   anyButtonPressed: true, geometry: geometry), [])
    }
}
