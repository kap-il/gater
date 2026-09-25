import Foundation

/// Classifies what changed between two parses of a file (spec §4.6).
public enum SymbolDiff {
    public static func diff(old: [CodeSymbol], new: [CodeSymbol]) -> [SymbolChange] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changes: [SymbolChange] = []

        for symbol in new {
            guard let previous = before[symbol.id] else {
                changes.append(change(symbol, .added, exported: symbol.isExported))
                continue
            }
            if previous.signatureHash != symbol.signatureHash || previous.kind != symbol.kind {
                // Losing `export` is a breaking change too, so a symbol
                // counts as exported if it was on either side.
                changes.append(change(symbol, .signature, exported: previous.isExported || symbol.isExported))
            } else if previous.bodyHash != symbol.bodyHash {
                changes.append(change(symbol, .body, exported: symbol.isExported))
            }
        }
        for symbol in old where after[symbol.id] == nil {
            changes.append(change(symbol, .removed, exported: symbol.isExported))
        }
        return changes
    }

    private static func change(_ symbol: CodeSymbol, _ kind: SymbolChangeKind, exported: Bool) -> SymbolChange {
        SymbolChange(id: symbol.id, symbol: symbol.qualifiedName, kind: symbol.kind, change: kind, isExported: exported)
    }
}
