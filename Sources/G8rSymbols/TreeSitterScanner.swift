import Foundation
import G8rCore

/// The symbol engine as the map sees it: each file parsed once for its
/// declarations, and read once more for the names it uses.
public struct TreeSitterScanner: SymbolScanning {
    public init() {}

    public func scan(source: String, path: String) -> FileScan? {
        guard SymbolExtractor.supports(path: path),
              let described = try? SymbolExtractor.describeAll(source: source, path: path) else { return nil }
        // Top-level code in `main.swift` is the program's body, so its
        // variables are locals that nothing else can use.
        let script = (path as NSString).lastPathComponent == "main.swift"
        let declarations = described.filter { !(script && $0.symbol.kind == .variable) }.map { found in
            Declaration(name: found.symbol.qualifiedName,
                        kind: found.symbol.kind.rawValue,
                        exported: found.symbol.isExported,
                        topLevel: found.symbol.qualifiedName == found.symbol.name,
                        signature: found.signature)
        }
        return FileScan(declarations: declarations, uses: SymbolExtractor.uses(source: source, path: path))
    }
}
