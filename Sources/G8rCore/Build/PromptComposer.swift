import Foundation

/// The first message of a build session, composed from the plan and the
/// code. Nothing in it is written by hand: the section and done-when are
/// the plan's words, the signatures are what the code exports.
public enum PromptComposer {
    /// - Parameters:
    ///   - interfaces: for each component the node needs, the signatures it
    ///     exports at `base`. A need with none is said to have none.
    ///   - base: the commit the session's branch starts from.
    public static func prompt(for id: String, in map: LivingMap,
                              interfaces: [String: [String]], base: String) -> String {
        guard let node = map.node(id) else { return "" }
        var parts: [String] = []

        parts.append("""
            You are building the `\(id)` component (\(node.name)) in a fresh session of its own. \
            Your branch, `\(GitWorktree.branch(forDelegate: id))`, starts at commit \(base).
            """)

        var section = "## The plan's section\n\n"
        if let text = node.section {
            section += "From \(text.doc), line \(text.line):\n\n### \(text.heading)\n\n\(text.text)"
        } else {
            section += "\(node.summary)"
        }
        parts.append(section.trimmingCharacters(in: .whitespacesAndNewlines))

        let paths = node.paths.isEmpty
            ? "The plan doesn't say. Put it where the code around it suggests."
            : node.paths.map { "- `\($0)`" }.joined(separator: "\n")
        parts.append("## Where its code goes\n\n" + paths)

        parts.append("## Done when\n\n" + (node.doneWhen ?? "The plan gives no done-when. Build what the section describes."))

        var needs = "## What it needs\n\n"
        if node.needs.isEmpty {
            needs += "Nothing: it stands on its own."
        } else {
            needs += "What each component it needs exports at \(base). Use these; don't change them.\n"
            for need in node.needs {
                let name = map.node(need)?.name ?? need
                let signatures = interfaces[need] ?? []
                needs += "\n### \(need): \(name)\n\n"
                needs += signatures.isEmpty
                    ? "No exported signatures were found in its code.\n"
                    : "```\n" + signatures.joined(separator: "\n") + "\n```\n"
            }
        }
        parts.append(needs.trimmingCharacters(in: .whitespacesAndNewlines))

        var changes = "## What it changes\n\n"
        if node.changes.isEmpty {
            changes += "Nothing that exists: it only adds code."
        } else {
            changes += node.changes.map { changed in
                let name = map.node(changed)?.name ?? changed
                let users = users(of: changed, in: map)
                let used = users.isEmpty ? "nothing else uses it" : "used by " + users.joined(separator: ", ")
                return "- `\(changed)` (\(name)): \(used)"
            }.joined(separator: "\n")
            changes += "\n\nKeep what those users rely on working."
        }
        parts.append(changes)

        parts.append("## Rules\n\n" + rules(for: id).enumerated()
            .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The six rules every build session is given.
    public static func rules(for id: String) -> [String] {
        let branch = GitWorktree.branch(forDelegate: id)
        return [
            "Stay in this worktree, the directory this session started in. Don't edit files anywhere else.",
            "Commit to this branch, `\(branch)`. Don't switch branches, push, rebase or merge; g8r merges it.",
            "Give each commit the trailer `\(BuildNotes.trailer): \(id)`.",
            "List what you assumed in the commit body, one assumption per line, each starting `Assumed:`.",
            "Leave nothing uncommitted. g8r checks that, then runs the build and the tests.",
            "Stop when the done-when holds.",
        ]
    }

    /// The components with an edge to `id`, declared or measured.
    static func users(of id: String, in map: LivingMap) -> [String] {
        var users: [String] = []
        for edge in map.edges where edge.to == id && !users.contains(edge.from) {
            users.append(edge.from)
        }
        return users.sorted()
    }
}
