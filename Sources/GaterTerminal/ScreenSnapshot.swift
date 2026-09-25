import Foundation

public struct RGB: Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct CellStyle: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold          = CellStyle(rawValue: 1 << 0)
    public static let italic        = CellStyle(rawValue: 1 << 1)
    public static let faint         = CellStyle(rawValue: 1 << 2)
    public static let underline     = CellStyle(rawValue: 1 << 3)
    public static let strikethrough = CellStyle(rawValue: 1 << 4)
    public static let inverse       = CellStyle(rawValue: 1 << 5)
    public static let invisible     = CellStyle(rawValue: 1 << 6)
}

/// One grid cell, copied out of libghostty's render state so drawing never
/// touches the (non-thread-safe) terminal.
///
/// `fg`/`bg` are nil when the cell uses the terminal's default color; they're
/// resolved at draw time so cached rows stay valid if the default colors change.
public struct Cell: Equatable, Sendable {
    public var text: String
    public var fg: RGB?
    public var bg: RGB?
    public var style: CellStyle

    public static let blank = Cell(text: "", fg: nil, bg: nil, style: [])

    public init(text: String, fg: RGB?, bg: RGB?, style: CellStyle) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.style = style
    }
}

public enum CursorShape: Sendable {
    case block, bar, underline, blockHollow
}

public struct CursorState: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var shape: CursorShape
    public var color: RGB?
}

public struct Scrollbar: Equatable, Sendable {
    public var total: UInt64
    public var offset: UInt64
    public var visible: UInt64

    /// Whether there's scrollback to scroll through at all.
    public var isScrollable: Bool { total > visible }
}

public struct ScreenSnapshot: Sendable {
    public var cols: Int
    public var rows: Int
    public var cells: [[Cell]]
    public var foreground: RGB
    public var background: RGB
    /// nil when the cursor is hidden or scrolled out of the viewport.
    public var cursor: CursorState?
    public var scrollbar: Scrollbar?

    /// A row's text with trailing blanks trimmed; handy for tests and logs.
    public func text(row: Int) -> String {
        guard row < cells.count else { return "" }
        let joined = cells[row].map { $0.text.isEmpty ? " " : $0.text }.joined()
        return String(joined.reversed().drop(while: { $0 == " " }).reversed())
    }
}
