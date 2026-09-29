import Foundation
import SwiftTreeSitter

extension SymbolExtractor {
    /// How often each identifier appears in the file, outside comments and
    /// string literals. Empty for a language the engine doesn't know.
    ///
    /// Every appearance counts, the declaration of a name as much as a call
    /// to it: telling them apart is for whoever knows what the file
    /// declares. Code interpolated into a string is inside the string, so
    /// it isn't counted.
    public static func uses(source: String, path: String) -> [String: Int] {
        guard let language = SymbolLanguage.reading(path),
              let root = (try? language.parse(source))?.rootNode else { return [:] }
        let text = source as NSString
        var counts: [String: Int] = [:]

        // Walked with a cursor and a loop, not recursion: a long chain of
        // operators or calls nests as deep as it is long.
        let cursor = root.treeCursor
        var arriving = true
        while true {
            if arriving, let node = cursor.currentNode, let type = node.nodeType {
                if language.identifiers.contains(type) {
                    counts[node.text(in: text), default: 0] += 1
                } else if !language.prose.contains(type), cursor.goToFirstChild() {
                    continue
                }
            }
            arriving = cursor.gotoNextSibling()
            if !arriving, !cursor.gotoParent() { return counts }
        }
    }
}
