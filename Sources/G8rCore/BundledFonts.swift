import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// The bundled type: IBM Plex Mono, one monospace family for the app, the
/// terminal and the map page. The TrueType files are registered with the app;
/// the map page embeds the smaller WOFF2 cuts of only the styles it uses.
public enum BundledFonts {
    public static let family = "IBM Plex Mono"

    public struct File {
        public let name: String
        /// The PostScript name, for `NSFont(name:size:)`.
        public let postScriptName: String
        public let weight: Int
        public let italic: Bool
    }

    public static let regular = File(name: "IBMPlexMono-Regular", postScriptName: "IBMPlexMono", weight: 400, italic: false)
    public static let italic = File(name: "IBMPlexMono-Italic", postScriptName: "IBMPlexMono-Italic", weight: 400, italic: true)
    public static let medium = File(name: "IBMPlexMono-Medium", postScriptName: "IBMPlexMono-Medm", weight: 500, italic: false)
    public static let semiBold = File(name: "IBMPlexMono-SemiBold", postScriptName: "IBMPlexMono-SmBld", weight: 600, italic: false)
    public static let bold = File(name: "IBMPlexMono-Bold", postScriptName: "IBMPlexMono-Bold", weight: 700, italic: false)

    /// Registered with the app.
    public static let files = [regular, italic, medium, semiBold, bold]
    /// Embedded in the map page as WOFF2.
    public static let webFiles = [regular, italic, semiBold]

    public static func url(_ file: File, ext: String = "ttf") -> URL? {
        Bundle.module.url(forResource: file.name, withExtension: ext, subdirectory: "Fonts")
    }

    #if canImport(CoreText)
    private static let registered: Bool = {
        var all = true
        for file in files {
            guard let url = url(file) else { all = false; continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered counts as success.
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
                if code != CTFontManagerError.alreadyRegistered.rawValue { all = false }
            }
        }
        return all
    }()

    /// Registers the bundled fonts for this process. Safe to call repeatedly;
    /// returns whether every font is available.
    @discardableResult
    public static func register() -> Bool { registered }
    #endif
}
