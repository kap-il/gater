import Foundation

/// Measures the base map: which files make up each component, which
/// components use which, which tests cover them, and what can be built
/// next. Then hands the map to the stages.
public enum LivingMapBuilder {
    public enum BuildError: Error, Equatable, CustomStringConvertible {
        case notARepository(String)

        public var description: String {
            switch self {
            case let .notARepository(path): return "\(path) is not inside a git repository"
            }
        }
    }

    /// - Parameters:
    ///   - planRoot: where the plan docs and `g8r.json` are read.
    ///   - codeRoot: where the code is measured.
    ///   - extractor: reads plan docs that have no component sections; nil
    ///     skips them.
    public static func build(planRoot: String, codeRoot: String,
                             scanner: SymbolScanning, stages: [MapStage],
                             extractor: PlanDocExtractor?) throws -> LivingMap {
        let config = G8rConfig.load(repoRoot: planRoot)
        let graph = PlanLoader.load(planRoot: planRoot, config: config, extractor: extractor)
        let files = try trackedFiles(in: codeRoot, ignoring: config.ignore)

        let measured = Measurement(graph: graph, files: files, codeRoot: codeRoot, scanner: scanner)
        var map = LivingMap(
            repo: (planRoot as NSString).lastPathComponent,
            head: GitWorktree.head(of: codeRoot).map { String($0.prefix(7)) },
            generated: ISO8601DateFormatter().string(from: Date()),
            docs: graph.docs,
            nodes: measured.nodes(),
            edges: measured.edges(),
            retired: graph.retired,
            problems: graph.problems)
        BuildOrder.apply(to: &map)

        let context = MapContext(planRoot: planRoot, codeRoot: codeRoot, config: config, graph: graph,
                                 files: measured.filesOnMap, scans: measured.scans)
        for stage in stages {
            try stage.apply(to: &map, context: context)
        }
        return map
    }

    /// Everything git tracks or would track, less what `ignore` names.
    /// Deleted files git still tracks, and submodules, aren't files here.
    /// A folder that isn't in a git repository is walked instead.
    static func trackedFiles(in codeRoot: String, ignoring ignore: [String]) throws -> [String] {
        guard GitWorktree.repoRoot(containing: codeRoot) != nil else {
            return walkedFiles(in: codeRoot, ignoring: ignore)
        }
        let listed = try GitWorktree.git(["ls-files", "-z", "-co", "--exclude-standard"], in: codeRoot)
        guard listed.status == 0 else { throw BuildError.notARepository(codeRoot) }
        let root = URL(fileURLWithPath: codeRoot)
        let paths = Set(listed.output.split(separator: "\0").map(String.init))
        return paths.filter { path in
            var isDirectory: ObjCBool = false
            return !ignore.contains { Glob.matches($0, path) }
                && FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path,
                                                  isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }.sorted()
    }

    /// Folders a walk never enters: build output and dependencies, which
    /// a repository's `.gitignore` would usually leave out.
    static let skippedFolders: Set<String> = [".git", ".build", "node_modules", "dist", "build", ".next",
                                              "target", "vendor"]

    /// The files under a folder that isn't a git repository, the way
    /// `trackedFiles` would give them: relative paths, sorted, less hidden
    /// entries, `skippedFolders` and what `ignore` names.
    static func walkedFiles(in codeRoot: String, ignoring ignore: [String]) -> [String] {
        let manager = FileManager.default
        guard let walk = manager.enumerator(atPath: codeRoot) else { return [] }
        var files: [String] = []
        while let path = walk.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            let type = walk.fileAttributes?[.type] as? FileAttributeType
            if name.hasPrefix(".") || (type == .typeDirectory && skippedFolders.contains(name)) {
                if type == .typeDirectory { walk.skipDescendants() }
                continue
            }
            if type == .typeDirectory || ignore.contains(where: { Glob.matches($0, path) }) { continue }
            // A link counts when it leads to a file, as git would list it.
            var isDirectory: ObjCBool = false
            if type == .typeRegular
                || manager.fileExists(atPath: (codeRoot as NSString).appendingPathComponent(path),
                                      isDirectory: &isDirectory) && !isDirectory.boolValue {
                files.append(path)
            }
        }
        return files.sorted()
    }
}

/// One pass over the files: who owns each, what each declares and uses.
struct Measurement {
    private let graph: PlanGraph
    private let codeRoot: URL
    /// Node ids in the order the map lists them: the plan's, then
    /// unplanned code by directory.
    private var order: [String] = []
    private var sources: [String: [String]] = [:]
    private var otherFiles: [String: [String]] = [:]
    private var tests: [String] = []
    private var texts: [String: String] = [:]
    private(set) var scans: [String: FileScan] = [:]
    /// Test files and the node each is attributed to.
    private var testOwners: [String: String] = [:]
    /// The nodes that declare each top-level name.
    private var declaredBy: [String: Set<String>] = [:]
    /// Top-level names declared by exactly one node.
    private var nameOwners: [String: String] = [:]

    init(graph: PlanGraph, files: [String], codeRoot: String, scanner: SymbolScanning) {
        self.graph = graph
        self.codeRoot = URL(fileURLWithPath: codeRoot)
        order = graph.components.map(\.id)

        var unplanned: [String: [String]] = [:]
        var named: [String: String] = [:]
        for path in files {
            let owner = Self.owner(of: path, in: graph)
            if CodeFiles.isTest(path) {
                tests.append(path)
                if let owner { named[path] = owner }
            } else if let owner {
                if CodeFiles.isCode(path) {
                    sources[owner, default: []].append(path)
                } else {
                    otherFiles[owner, default: []].append(path)
                }
            } else if CodeFiles.isCode(path) {
                unplanned[Self.directory(of: path), default: []].append(path)
            }
        }
        for (directory, paths) in unplanned.sorted(by: { $0.key < $1.key }) {
            let id = "unplanned:" + directory
            order.append(id)
            sources[id] = paths
        }

        for path in sources.values.joined() + tests {
            guard let text = try? String(contentsOf: self.codeRoot.appendingPathComponent(path), encoding: .utf8)
            else { continue }
            texts[path] = text
            scans[path] = scanner.scan(source: text, path: path)
        }

        for (id, paths) in sources {
            for path in paths {
                for declaration in scans[path]?.declarations ?? [] where declaration.topLevel && Self.counts(declaration.name) {
                    declaredBy[declaration.name, default: []].insert(id)
                }
            }
        }
        nameOwners = declaredBy.compactMapValues { $0.count == 1 ? $0.first : nil }

        for path in tests {
            if let owner = named[path] ?? testOwner(of: path) { testOwners[path] = owner }
        }
    }

    /// Code-root-relative paths of every file on the map.
    var filesOnMap: [String] {
        (Array(sources.values.joined()) + Array(otherFiles.values.joined()) + Array(testOwners.keys)).sorted()
    }

    // MARK: - Owners

    /// The node whose `Code:` entry matches the path; the longest entry
    /// wins, and the plan's order breaks a tie.
    static func owner(of path: String, in graph: PlanGraph) -> String? {
        var best: (id: String, length: Int)?
        for component in graph.components {
            for entry in component.paths where entry.count > (best?.length ?? -1) && Glob.matches(entry, path) {
                best = (component.id, entry.count)
            }
        }
        return best?.id
    }

    private static func directory(of path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? "." : directory
    }

    /// Short names say too little about who is being used.
    private static func counts(_ name: String) -> Bool {
        name.count >= 3
    }

    /// A test file no `Code:` entry names belongs to what it is named after,
    /// a file's stem or a top-level name, if exactly one node has that;
    /// failing that, to the node whose names it uses most.
    private func testOwner(of path: String) -> String? {
        let subject = CodeFiles.testSubject(path)
        var named = Set(sources.filter { $0.value.contains { CodeFiles.stem($0) == subject } }.keys)
        named.formUnion(declaredBy[subject] ?? [])
        if named.count == 1 { return named.first }

        var totals: [String: Int] = [:]
        for (name, count) in scans[path]?.uses ?? [:] where Self.counts(name) {
            if let owner = nameOwners[name] { totals[owner, default: 0] += count }
        }
        return order.filter { totals[$0] != nil }.max { totals[$0]! < totals[$1]! }
    }

    // MARK: - Nodes

    func nodes() -> [MapNode] {
        order.map { id in
            let paths = sources[id] ?? []
            var node: MapNode
            if let component = graph.component(id) {
                node = MapNode(
                    id: id, name: component.name, summary: component.summary,
                    status: paths.isEmpty ? .planned : .built, doc: component.doc,
                    needs: component.needs, changes: component.changes, paths: component.paths,
                    section: MapSection(doc: component.doc, line: component.line,
                                        heading: component.heading, text: component.text),
                    doneWhen: component.doneWhen)
            } else {
                let directory = String(id.dropFirst("unplanned:".count))
                var stems: [String] = []
                for stem in paths.map(CodeFiles.stem) where !stems.contains(stem) { stems.append(stem) }
                node = MapNode(id: id, name: stems.joined(separator: ", "),
                               summary: "Code in \(directory) that no plan mentions.",
                               status: .unplanned, paths: paths)
            }

            node.files = (paths + (otherFiles[id] ?? [])).sorted().map { path in
                let symbols = scans[path]?.declarations.filter(\.topLevel).map { MapSymbol(kind: $0.kind, name: $0.name) }
                return MapFile(path: path, loc: texts[path].map(CodeFiles.lineCount) ?? 0, symbols: symbols ?? [])
            }
            node.loc = node.files.reduce(0) { $0 + $1.loc }

            let testFiles = testOwners.filter { $0.value == id }.keys.sorted()
            if !testFiles.isEmpty {
                let count = testFiles.reduce(0) { $0 + CodeFiles.testCount(source: texts[$1] ?? "", path: $1) }
                node.tests = NodeTests(files: testFiles, count: count)
            }
            return node
        }
    }

    // MARK: - Edges

    /// Declared edges from the plan's needs, measured edges from the code:
    /// a node uses another when its files use a name only the other
    /// declares at the top level.
    func edges() -> [MapEdge] {
        var edges: [String: MapEdge] = [:]
        func key(_ from: String, _ to: String) -> String { from + "\n" + to }

        for component in graph.components {
            for need in component.needs where need != component.id && graph.component(need) != nil {
                edges[key(component.id, need)] = MapEdge(from: component.id, to: need, declared: true, measured: false)
            }
        }

        for id in order {
            var used: [String: [String: Int]] = [:]
            for path in sources[id] ?? [] {
                for (name, count) in scans[path]?.uses ?? [:] where Self.counts(name) {
                    guard let owner = nameOwners[name], owner != id else { continue }
                    used[owner, default: [:]][name, default: 0] += count
                }
            }
            for (owner, names) in used {
                var edge = edges[key(id, owner)] ?? MapEdge(from: id, to: owner, declared: false, measured: false)
                edge.measured = true
                edge.symbols = names.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
                edge.refs = names.values.reduce(0, +)
                edges[key(id, owner)] = edge
            }
        }
        return edges.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
    }
}
