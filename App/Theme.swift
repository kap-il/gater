import AppKit
import G8rCore

/// g8r's palette and type, shared with the map page: built around the
/// forest green #002008 and the olive #172D00, every colour a green:
/// khaki-olive for commands and acid chartreuse for errors.
/// /// for commands, a rust red for errors, and IBM Plex Mono bundled
/// in G8rCore and registered at launch.
enum Theme {
    static let background = hex(0x002008)   // primary: forest
    static let surface = hex(0x172D00)      // primary: olive
    static let raised = hex(0x223F05)
    static let line = hex(0x2E4E0C)
    static let ink = hex(0xDCEAC6)
    static let muted = hex(0x92AB7E)
    static let accent = hex(0x3F6E12)
    static let brightAccent = hex(0x8BC34A)
    static let olive = hex(0x8AA13A)
    static let murkyTeal = hex(0x2F6A45)
    static let bog = hex(0x3F5A12)
    static let brass = hex(0xA5A94E)
    static let error = hex(0xD4E23A)

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
