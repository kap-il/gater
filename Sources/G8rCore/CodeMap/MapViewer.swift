import Foundation

/// The map viewer: one self-contained page (`Viewer/viewer.html`) that
/// loads nothing from the network. In a browser it draws the map embedded
/// in it; in the app it starts empty and is fed through `window.g8r.setMap`.
public enum MapViewer {
    public enum ViewerError: Error {
        case missingPage
    }

    static let placeholder = "/*G8R_MAP*/null"

    /// A page that draws this map when opened in a browser.
    public static func page(for map: LivingMap) throws -> String {
        try template().replacingOccurrences(of: placeholder, with: scriptJSON(map))
    }

    /// The page with no map in it, for the app to load and then feed.
    public static func shell() throws -> String {
        try template()
    }

    /// The map as JSON that is safe inside a `<script>` element and as a
    /// JavaScript expression.
    public static func scriptJSON(_ map: LivingMap) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(map), as: UTF8.self)
        return json
            // `<` only occurs inside strings, where \u003c means the same.
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Where a map's file paths are relative to: the integration worktree
    /// once it exists, else the plan root (as `StandardMap` measures).
    public static func codeRoot(planRoot: String) -> String {
        let integration = Integrator(repoRoot: planRoot).worktree
        return GitWorktree.head(of: integration) != nil ? integration : planRoot
    }

    /// The files whose change on disk means the map must be measured again:
    /// the plan docs and `g8r.json`, as absolute paths.
    public static func watchedFiles(planRoot: String, map: LivingMap?) -> [String] {
        let root = URL(fileURLWithPath: planRoot)
        var paths = (map?.docs ?? []).map { root.appendingPathComponent($0.path).path }
        paths.append(root.appendingPathComponent("g8r.json").path)
        if map == nil { paths.append(root.appendingPathComponent("PLAN.md").path) }
        return Array(Set(paths)).sorted()
    }

    /// Zero-based lines of `text` that declare one of `symbols`: the first
    /// line with the kind and the name as words, else the first line with
    /// the name as a word.
    public static func symbolLines(in text: String, symbols: [MapSymbol]) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        func words(_ line: String) -> Set<Substring> {
            Set(line.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") })
        }
        let lineWords = lines.map(words)
        var found = Set<Int>()
        for symbol in symbols where !symbol.name.isEmpty {
            let name = Substring(symbol.name), kind = Substring(symbol.kind)
            if let index = lineWords.firstIndex(where: { $0.contains(name) && $0.contains(kind) })
                ?? lineWords.firstIndex(where: { $0.contains(name) }) {
                found.insert(index)
            }
        }
        return found.sorted()
    }

    private static func template() throws -> String {
        guard let url = Bundle.module.url(forResource: "viewer", withExtension: "html", subdirectory: "Viewer")
        else { throw ViewerError.missingPage }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
