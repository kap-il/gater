import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// The bundled retro faces: IBM 3270 (mainframe terminal) for body text and
/// VT323 (DEC VT320) for headings. Both live in G8rCore's resource bundle.
public enum RetroFonts {
    public struct File {
        public let name: String
        public let ext: String
        public let family: String
        /// The PostScript name, for `NSFont(name:size:)`.
        public let postScriptName: String
    }

    public static let body = File(name: "IBM3270-Regular", ext: "otf", family: "IBM 3270", postScriptName: "3270-Regular")
    public static let display = File(name: "VT323-Regular", ext: "ttf", family: "VT323", postScriptName: "VT323-Regular")
    public static let files = [body, display]

    public static func url(_ file: File) -> URL? {
        Bundle.module.url(forResource: file.name, withExtension: file.ext, subdirectory: "Fonts")
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
