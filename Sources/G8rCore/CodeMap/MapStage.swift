import Foundation

/// A name a file declares.
public struct Declaration: Codable, Equatable {
    /// Qualified by the types around it: `EventBus.start`.
    public var name: String
    public var kind: String
    public var exported: Bool
    public var topLevel: Bool
    /// One line, no body.
    public var signature: String

    public init(name: String, kind: String, exported: Bool, topLevel: Bool, signature: String) {
        self.name = name
        self.kind = kind
        self.exported = exported
        self.topLevel = topLevel
        self.signature = signature
    }
}

/// What the symbol engine found in one file.
public struct FileScan: Codable, Equatable {
    public var declarations: [Declaration]
    /// How often each name appears in the file's code.
    public var uses: [String: Int]

    public init(declarations: [Declaration], uses: [String: Int]) {
        self.declarations = declarations
        self.uses = uses
    }
}

/// Reads one file's declarations and uses. The real one is tree-sitter,
/// which lives in `G8rSymbols`; the map only knows this shape of it.
public protocol SymbolScanning {
    /// Nil when the file is in a language the scanner can't read.
    func scan(source: String, path: String) -> FileScan?
}

/// What a stage may read besides the map.
public struct MapContext {
    public var planRoot: String
    public var codeRoot: String
    public var config: G8rConfig
    public var graph: PlanGraph
    /// Code-root-relative paths of every file on the map.
    public var files: [String]
    /// What the symbol engine found in each file it understands.
    public var scans: [String: FileScan]

    public init(planRoot: String, codeRoot: String, config: G8rConfig, graph: PlanGraph,
                files: [String], scans: [String: FileScan]) {
        self.planRoot = planRoot
        self.codeRoot = codeRoot
        self.config = config
        self.graph = graph
        self.files = files
        self.scans = scans
    }
}

/// Adds to the map after codemap has measured it. Stages run in order,
/// each on what the one before left.
public protocol MapStage {
    func apply(to map: inout LivingMap, context: MapContext) throws
}
