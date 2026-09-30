import Foundation

/// "Change this" on a built node: what the user typed into the node's
/// change box, with enough of the plan around it for the agent they wired
/// up to find the code. It goes into an interactive session, so it stays
/// short: the plan's section and done-when are trimmed, and files are
/// listed by path only.
public enum ChangeRequest {
    /// The event the app records when it sends one.
    public static let eventKind = "change_requested"
    /// What the map says when there's no agent to send it to.
    public static let missing = "Start claude or codex in a shell first."

    public static let sectionLimit = 1200
    public static let doneWhenLimit = 500
    public static let fileLimit = 12

    /// Nodes with code can be changed; planned ones are built instead.
    public static func accepts(_ status: NodeStatus) -> Bool {
        switch status {
        case .built, .proven, .unproven, .failing, .unplanned: return true
        case .planned, .building: return false
        }
    }

    /// The message typed into the session: the user's words first, then
    /// the node. Empty when there is no such node or nothing was typed.
    public static func prompt(for id: String, in map: LivingMap, text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node = map.node(id), !text.isEmpty else { return "" }
        var parts = [text]

        parts.append("This is about the `\(id)` component (\(node.name)) on the g8r map.")

        if let section = node.section {
            parts.append("Its plan, \(section.doc):\(section.line), \"\(section.heading)\":\n"
                + trimmed(section.text, to: sectionLimit))
        } else if !node.summary.isEmpty {
            parts.append("What it is: \(node.summary)")
        }

        if let doneWhen = node.doneWhen, !doneWhen.isEmpty {
            parts.append("Done when: " + trimmed(doneWhen, to: doneWhenLimit))
        }

        let paths = node.files.map(\.path)
        if !paths.isEmpty {
            var list = paths.prefix(fileLimit).map { "- \($0)" }
            if paths.count > fileLimit { list.append("- and \(paths.count - fileLimit) more") }
            parts.append("Its files:\n" + list.joined(separator: "\n"))
        } else if !node.paths.isEmpty {
            parts.append("Its code goes in: " + node.paths.joined(separator: ", "))
        }

        var context: [String] = []
        let needs = needs(of: id, node: node, in: map)
        if !needs.isEmpty { context.append("It needs " + names(needs, in: map) + ".") }
        let users = PromptComposer.users(of: id, in: map)
        if !users.isEmpty { context.append("Needed by " + names(users, in: map) + ".") }
        if !context.isEmpty { parts.append(context.joined(separator: " ")) }

        parts.append("Keep the change inside those files where you can. If it needs to touch "
            + "another component, say which one and why.")

        return parts.joined(separator: "\n\n")
    }

    /// What the status line says once it's sent.
    public static func sent(to agent: Agent, pane: String, queued: Bool) -> String {
        queued ? "Queued for \(agent.rawValue) in \(pane); it's still working."
               : "Sent to \(agent.rawValue) in \(pane)."
    }

    /// What it needs, by the plan and by the code, in that order.
    static func needs(of id: String, node: MapNode, in map: LivingMap) -> [String] {
        var out = node.needs
        for edge in map.edges where edge.from == id && edge.to != id && !out.contains(edge.to) {
            out.append(edge.to)
        }
        return out
    }

    static func names(_ ids: [String], in map: LivingMap) -> String {
        ids.map { id in
            let name = map.node(id)?.name ?? id
            return name == id ? "`\(id)`" : "`\(id)` (\(name))"
        }.joined(separator: ", ")
    }

    /// At most `limit` characters, cut at the last line break (or else
    /// space) before it, with "…" to say there's more.
    static func trimmed(_ text: String, to limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(of: "\n").flatMap { $0 > head.index(head.startIndex, offsetBy: limit / 2) ? $0 : nil }
            ?? head.lastIndex(of: " ")
            ?? head.endIndex
        return head[..<cut].trimmingCharacters(in: .whitespacesAndNewlines) + " …"
    }
}
