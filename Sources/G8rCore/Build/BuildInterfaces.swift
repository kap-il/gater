import Foundation

/// The signatures a component exports, for the prompt of a component
/// that needs it. Read from the files the map gives the component, less
/// its tests.
public enum BuildInterfaces {
    /// Signatures kept per component, so one large dependency can't drown
    /// the prompt.
    public static let limit = 60

    /// From scans already made, such as the map's own.
    public static func from(scans: [String: FileScan], map: LivingMap, needs: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for need in needs {
            out[need] = signatures(sourceFiles(of: need, in: map).compactMap { scans[$0] })
        }
        return out
    }

    /// From the files as they are at `commit`, which is what a session that
    /// branches from it will see.
    public static func at(commit: String, repoRoot: String, map: LivingMap, needs: [String],
                          scanner: SymbolScanning) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for need in needs {
            let scans = sourceFiles(of: need, in: map).compactMap { path -> FileScan? in
                guard let shown = try? GitWorktree.git(["show", "\(commit):\(path)"], in: repoRoot),
                      shown.status == 0 else { return nil }
                return scanner.scan(source: shown.output, path: path)
            }
            out[need] = signatures(scans)
        }
        return out
    }

    static func sourceFiles(of id: String, in map: LivingMap) -> [String] {
        (map.node(id)?.files ?? []).map(\.path).filter { CodeFiles.isCode($0) && !CodeFiles.isTest($0) }
    }

    /// Exported declarations' signatures, in file order, each once.
    static func signatures(_ scans: [FileScan]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for declaration in scans.flatMap(\.declarations) where declaration.exported {
            let signature = declaration.signature.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !signature.isEmpty, seen.insert(signature).inserted else { continue }
            out.append(signature)
            if out.count == limit { break }
        }
        return out
    }
}
