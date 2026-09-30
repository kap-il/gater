import AppKit
import G8rCore

/// g8r's palette and type, shared with the map page: deep greens, a brass
/// for commands, a rust red for errors, and IBM Plex Mono bundled
/// in G8rCore and registered at launch.
enum Theme {
    static let background = hex(0x07110B)
    static let surface = hex(0x0C1A12)
    static let raised = hex(0x122419)
    static let line = hex(0x1E3A28)
    static let ink = hex(0xCFDCC4)
    static let muted = hex(0x7E9A7F)
    static let accent = hex(0x2F6B45)
    static let brightAccent = hex(0x5E9E5A)
    static let olive = hex(0x556B2F)
    static let murkyTeal = hex(0x2E5A4C)
    static let bog = hex(0x4A5A2A)
    static let brass = hex(0x8C7A3A)
    static let error = hex(0xA94A35)

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
