import AppKit
import CoreText

/// The monospace font set a terminal view draws with, plus the cell size
/// derived from it. Every cell is exactly `cellSize`; glyphs are placed on
/// that grid rather than trusting text layout advances.
struct TerminalFont {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let cellSize: CGSize
    /// Distance from a cell's top to the text baseline (flipped coords).
    let baselineOffset: CGFloat

    init(size: CGFloat = 13) {
        let base = TerminalFont.preferredFont(size: size)
        let manager = NSFontManager.shared
        regular = base
        bold = manager.convert(base, toHaveTrait: .boldFontMask)
        italic = manager.convert(base, toHaveTrait: .italicFontMask)
        boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)

        let ctFont = base as CTFont
        var glyph = CGGlyph()
        var m: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(ctFont, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        cellSize = CGSize(width: ceil(advance.width), height: ceil(ascent + descent + leading))
        baselineOffset = ceil(ascent + leading / 2)
    }

    func font(for style: CellStyleFlags) -> NSFont {
        switch (style.bold, style.italic) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        case (false, false): return regular
        }
    }

    private static func preferredFont(size: CGFloat) -> NSFont {
        for name in ["JetBrainsMono-Regular", "SFMono-Regular", "Menlo-Regular"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

struct CellStyleFlags: Hashable {
    var bold: Bool
    var italic: Bool
}
