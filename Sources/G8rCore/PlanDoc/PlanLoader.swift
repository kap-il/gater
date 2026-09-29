import Foundation

/// Reads every plan doc of a repo into one graph, and says what is wrong
/// with it. Docs are read from disk as they are, so edits that aren't
/// committed yet count.
public enum PlanLoader {
    public static func load(planRoot: String, config: G8rConfig,
                            extractor: PlanDocExtractor?) -> PlanGraph {
        var graph = PlanGraph(docs: [], components: [], retired: [], problems: [])
        var found: [PlanComponent] = []

        for doc in docs(in: planRoot, config: config, problems: &graph.problems) {
            let file = URL(fileURLWithPath: planRoot).appendingPathComponent(doc)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                graph.problems.append("couldn't read \(doc)")
                continue
            }
            let parsed = PlanDocParser.parse(text: text, doc: doc)
            graph.docs.append(PlanDocInfo(path: doc, title: parsed.title))
            graph.retired += parsed.retired

            if !parsed.components.isEmpty {
                found += parsed.components
            } else if text.allSatisfy(\.isWhitespace) {
                continue
            } else if let extractor {
                do {
                    found += try extractor.extract(text: text, doc: doc)
                } catch {
                    graph.problems.append("couldn't extract components from \(doc): \(error)")
                }
            } else {
                graph.problems.append("\(doc) has no component sections and nothing to extract them with, so it was skipped")
            }
        }

        let checked = check(found)
        graph.components = checked.components
        graph.problems += checked.problems
        return graph
    }

    // MARK: - Finding the docs

    /// Plan-root-relative paths of the plan docs, in the order `plans`
    /// names them, each once.
    private static func docs(in planRoot: String, config: G8rConfig, problems: inout [String]) -> [String] {
        var docs: [String] = []
        for entry in config.plans {
            let matched = files(matching: entry, in: planRoot)
            // The defaults are places to look. Anything else was named by
            // someone, who should hear that it isn't there.
            if matched.isEmpty, config.plans != G8rConfig.defaultPlans {
                problems.append("no plan doc at \(entry)")
            }
            docs += matched.filter { !docs.contains($0) }
        }
        return docs
    }

    private static func files(matching entry: String, in planRoot: String) -> [String] {
        let root = URL(fileURLWithPath: planRoot)
        func isWild(_ part: String) -> Bool { part.contains("*") || part.contains("?") }
        guard isWild(entry) else {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(entry).path,
                                                        isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue ? [entry] : []
        }

        // Only the directory the pattern starts in is searched, and only as
        // deep as the pattern can reach: `*` and `?` stay within one path
        // segment, so nothing but `**` goes deeper than the pattern is long.
        let parts = entry.split(separator: "/").map(String.init)
        let fixed = Array(parts.prefix { !isWild($0) })
        let depth = entry.contains("**") ? Int.max : parts.count - fixed.count
        var found: [String] = []
        collect(under: fixed.joined(separator: "/"), depth: depth, root: root, into: &found)
        return found.filter { Glob.matches(entry, $0) }.sorted()
    }

    /// The files under a directory, down to `depth` levels. Hidden entries
    /// are passed over, which keeps a `**` out of `.git` and `.build`.
    private static func collect(under directory: String, depth: Int, root: URL, into found: inout [String]) {
        guard depth > 0 else { return }
        let here = directory.isEmpty ? root : root.appendingPathComponent(directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: here.path)) ?? []
        for name in names where !name.hasPrefix(".") {
            let path = directory.isEmpty ? name : directory + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path,
                                                 isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                collect(under: path, depth: depth - 1, root: root, into: &found)
            } else {
                found.append(path)
            }
        }
    }

    // MARK: - Checking the graph

    /// Keeps the first definition of each id, and lists what the plan gets
    /// wrong: ids defined twice, needs and changes that name nothing, and
    /// needs that lead back to where they started.
    static func check(_ found: [PlanComponent]) -> (components: [PlanComponent], problems: [String]) {
        var components: [PlanComponent] = []
        var byID: [String: PlanComponent] = [:]
        var problems: [String] = []

        for component in found {
            if let first = byID[component.id] {
                problems.append("\(component.id) is defined twice: at \(first.doc):\(first.line) "
                    + "and \(component.doc):\(component.line)")
            } else {
                byID[component.id] = component
                components.append(component)
            }
        }
        for component in components {
            for need in component.needs where byID[need] == nil {
                problems.append("\(component.id) needs an unknown component: \(need)")
            }
            for change in component.changes where byID[change] == nil {
                problems.append("\(component.id) changes an unknown component: \(change)")
            }
        }

        let needs = byID.mapValues { Set($0.needs) }
        for unit in IntegrationPlanner.stronglyConnectedComponents(of: Set(byID.keys), dependencies: needs) {
            if unit.count > 1 {
                problems.append("these need each other, so none can be built first: \(unit.joined(separator: ", "))")
            } else if let id = unit.first, needs[id]?.contains(id) == true {
                problems.append("\(id) needs itself")
            }
        }
        return (components, problems)
    }
}
