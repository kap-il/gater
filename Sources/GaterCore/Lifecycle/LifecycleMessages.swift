import Foundation

/// What the orchestrator is told as dishes move through the kitchen
/// (spec §4.10). Terse and structured, like overlap wakes.
public enum LifecycleMessages {
    /// On `pass`: the dish's diff plus its done note, so the orchestrator
    /// can check them against the vision before finishing.
    public static func pass(dish: Dish, did: String?, assumed: String?, worktree: String, base: String,
                            stat: String, diff: String, truncated: Bool) -> String {
        var lines = ["[GATER] \(dish.id) at the pass (\(dish.feature) · \(dish.pane ?? "?"))"]
        if let did { lines.append("did: \(did)") }
        if let assumed, !assumed.isEmpty { lines.append("assumed: \(assumed)") }
        if !stat.isEmpty { lines.append(stat) }
        if !diff.isEmpty {
            lines.append("--- diff since the dish started ---")
            lines.append(diff)
            if truncated { lines.append("… (truncated; full diff: git -C \(worktree) diff \(base))") }
        } else {
            lines.append("(no changes since the dish started)")
        }
        lines.append("Finish with GATER/1 type: finish for \(dish.id), or instruct/rescope it.")
        return lines.joined(separator: "\n")
    }

    public static func served(dishes: [String], commit: String, integrationWorktree: String,
                              tests: Integrator.TestRun?) -> String {
        let short = String(commit.prefix(7))
        var lines = ["[GATER] served \(dishes.joined(separator: " + ")) into \(Integrator.branch) (merge \(short))"]
        switch tests {
        case nil:
            lines.append("tests: not configured (set \"test_command\" in .gater/config.json)")
        case let run? where run.passed:
            lines.append("tests: passed")
        case let run?:
            lines.append("tests: FAILED after this merge — it's the likely cause:")
            lines.append(run.tail)
        }
        lines.append("Review this delta against the integrated code: git -C \(integrationWorktree) show \(short)")
        return lines.joined(separator: "\n")
    }

    public static func conflict(dishes: [String], files: [String]) -> String {
        """
        [GATER] couldn't merge \(dishes.joined(separator: " + ")) into \(Integrator.branch): conflicts in \(files.joined(separator: ", "))
        Integration is unchanged. Get it resolved on the dish's branch (e.g. instruct its delegate), then finish it again.
        """
    }
}

extension GitWorktree {
    /// Removes a served delegate's worktree folder, keeping its branch (and
    /// so its commits and Gater trailers). Refuses — without forcing — if
    /// it has uncommitted changes, so nothing is lost silently.
    @discardableResult
    public static func remove(worktree path: String, repoRoot: String) -> Bool {
        (try? git(["worktree", "remove", path], in: repoRoot))?.status == 0
    }
}
