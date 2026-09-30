import AppKit

/// g8r's palette and type, shared with the map page: deep greens, a brass
/// for commands, a rust red for errors, and old book faces for labels.
enum Theme {
    static let background = hex(0x0B1A12)
    static let surface = hex(0x10261A)
    static let raised = hex(0x16331F)
    static let line = hex(0x234A31)
    static let ink = hex(0xD8E8D0)
    static let muted = hex(0x8FAE93)
    static let accent = hex(0x3F8F5A)
    static let brightAccent = hex(0x6FBF73)
    static let brass = hex(0xB89B4A)
    static let error = hex(0xC0573E)

    /// Labels, tab titles, tile titles.
    static func label(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let font = first(["Hoefler Text", "Iowan Old Style"], size) ?? .systemFont(ofSize: size)
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    /// Headings, used sparingly.
    static func heading(_ size: CGFloat) -> NSFont {
        first(["Luminari", "Hoefler Text"], size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// Typewriter monospace for the padded event feed.
    static func typewriter(_ size: CGFloat) -> NSFont {
        first(["Courier New", "Courier"], size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static func first(_ names: [String], _ size: CGFloat) -> NSFont? {
        for name in names { if let f = NSFont(name: name, size: size) { return f } }
        return nil
    }
}
