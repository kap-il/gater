import Foundation

/// What click-to-build adds to the map: the prompt a planned node would be
/// built with, what earlier sessions assumed, and which nodes have a
/// session open now.
///
/// Notes are the `Assumed:` lines of commits whose trailer names the node,
/// on the code root's `HEAD` or on any `g8r/*` branch, oldest first. Open
/// sessions come from the plan root's event log: a `build_started` with no
/// `build_merged` or `pane_closed` after it.
///
/// Runs before evidence, which keeps a node `building` once this stage
/// has made it so.
public struct BuildNotes: MapStage {
    public static let trailer = "G8r-Component"
    public static let assumed = "Assumed:"

    public init() {}

    public func apply(to map: inout LivingMap, context: MapContext) throws {
        let base = GitWorktree.head(of: context.codeRoot) ?? "HEAD"
        let notes = Self.notes(in: context.codeRoot)
        let open = Self.openSessions(planRoot: context.planRoot)

        let snapshot = map
        for index in map.nodes.indices {
            let node = map.nodes[index]
            if node.status == .planned {
                let interfaces = BuildInterfaces.from(scans: context.scans, map: snapshot, needs: node.needs)
                map.nodes[index].prompt = PromptComposer.prompt(for: node.id, in: snapshot,
                                                                interfaces: interfaces, base: base)
            }
            if let found = notes[node.id], !found.isEmpty {
                map.nodes[index].notes = found
            }
            if open[node.id] != nil {
                map.nodes[index].building = true
                map.nodes[index].status = .building
            }
        }
    }

    // MARK: - Notes

    private static let separator = "\u{1E}"

    /// Each component's notes, read from the commits that carry its trailer.
    static func notes(in codeRoot: String) -> [String: [String]] {
        guard let log = try? GitWorktree.git(["log", "--reverse", "HEAD", "--branches=g8r/*",
                                              "--format=\(separator)%B"], in: codeRoot),
              log.status == 0 else { return [:] }
        var out: [String: [String]] = [:]
        for message in log.output.components(separatedBy: separator) {
            let parsed = parse(message: message)
            for component in parsed.components {
                for note in parsed.assumed where out[component]?.contains(note) != true {
                    out[component, default: []].append(note)
                }
            }
        }
        return out
    }

    /// The components a commit message's trailers name, and its
    /// `Assumed:` lines.
    static func parse(message: String) -> (components: [String], assumed: [String]) {
        var components: [String] = []
        var assumed: [String] = []
        let key = trailer.lowercased() + ":"
        for raw in message.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix(key) {
                let value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && !components.contains(value) { components.append(value) }
            } else if line.hasPrefix(Self.assumed), line.count > Self.assumed.count {
                assumed.append(line)
            }
        }
        return (components, assumed)
    }

    // MARK: - Open sessions

    /// Components with a session open, and the pane each runs in.
    public static func openSessions(planRoot: String) -> [String: String] {
        let log = URL(fileURLWithPath: planRoot).appendingPathComponent(".g8r/events.jsonl")
        return openSessions(in: (try? EventLog.replay(path: log)) ?? [])
    }

    static func openSessions(in events: [G8rEvent]) -> [String: String] {
        var open: [String: String] = [:]
        for event in events {
            switch event.kind {
            case "build_started":
                guard let component = event["component"]?.stringValue else { continue }
                open[component] = event.pane ?? BuildLaunch.pane(for: component)
            case "build_merged":
                if let component = event["component"]?.stringValue { open[component] = nil }
            case "pane_closed":
                guard let pane = event.pane else { continue }
                open = open.filter { $0.value != pane }
            default:
                continue
            }
        }
        return open
    }
}
