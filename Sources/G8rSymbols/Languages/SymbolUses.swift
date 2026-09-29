import Foundation
import SwiftTreeSitter

extension SymbolExtractor {
    /// How often each identifier appears in the file, outside comments and
    /// string literals. Empty for a language the engine doesn't know.
    ///
    /// Every appearance counts, the declaration of a name as much as a call
    /// to it: telling them apart is for whoever knows what the file
    /// declares. Code interpolated into a string is code and is counted;
    /// the words of the literal around it are not.
    public static func uses(source: String, path: String) -> [String: Int] {
        guard let language = SymbolLanguage.reading(path),
              let root = (try? language.parse(source))?.rootNode else { return [:] }
        let text = source as NSString
        var counts: [String: Int] = [:]

        // Walked with a cursor and a loop, not recursion: a long chain of
        // operators or calls nests as deep as it is long.
        let cursor = root.treeCursor
        // Whether the nodes at each depth, down to the cursor's, are prose.
        var prose = [false]
        var arriving = true
        while true {
            if arriving, let node = cursor.currentNode, let type = node.nodeType {
                let inProse = prose[prose.count - 1]
                if !inProse, language.identifiers.contains(type) {
                    counts[node.text(in: text), default: 0] += 1
                } else if cursor.goToFirstChild() {
                    prose.append(!language.interpolations.contains(type) && (inProse || language.prose.contains(type)))
                    continue
                }
            }
            arriving = cursor.gotoNextSibling()
            if !arriving {
                guard cursor.gotoParent() else { return counts }
                prose.removeLast()
            }
        }
    }
}
