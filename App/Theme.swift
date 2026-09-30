import AppKit
import G8rCore

/// g8r's palette and type, shared with the map page. Near-black green
/// #050D03 is nearly everything; bright greens are accents only: khaki-lime
/// for commands, acid chartreuse for errors. IBM Plex Mono, bundled in
/// G8rCore and registered at launch.
enum Theme {
    static let background = hex(0x050D03)
    static let surface = hex(0x050D03)
    static let raised = hex(0x0B1A07)
    static let line = hex(0x1A3310)
    static let ink = hex(0xD8ECC8)
    static let muted = hex(0x7F9A70)
    static let accent = hex(0x3FA34D)
    static let brightAccent = hex(0x8EF05A)
    static let olive = hex(0xA3C94A)
    static let murkyTeal = hex(0x1F4A26)
    static let bog = hex(0x2F4A1A)
    static let brass = hex(0xC8D45A)
    static let error = hex(0xE4F24A)

    /// Labels, tab titles, tile titles: Plex Mono Medium, SemiBold when bold.
    static func label(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let file = bold ? BundledFonts.semiBold : BundledFonts.medium
        return first([file.postScriptName, "Menlo"], size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .medium)
    }

    /// Headings, used sparingly: Plex Mono SemiBold.
    static func heading(_ size: CGFloat) -> NSFont {
        first([BundledFonts.semiBold.postScriptName, "Menlo-Bold"], size)
            ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
    }

    /// Plex Mono Regular for the padded event feed.
    static func typewriter(_ size: CGFloat) -> NSFont {
        first([BundledFonts.regular.postScriptName, "Menlo"], size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
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
