import AppKit
import GaterTerminal

enum PaneRole: String {
    /// Exactly one per session; runs the planning `claude`.
    case orchestrator
    /// One per worktree; runs a working `claude`.
    case delegate
    /// Plain shell, not tracked.
    case shell
}

/// A terminal pane: its identity in the event log, where it runs, and the
/// live session + view.
final class Pane {
    /// Written to GATER_PANE_ID, so it's what hook events carry as "pane".
    let id: String
    let role: PaneRole
    let name: String
    let worktree: String
    let session: TerminalSession
    let view: TerminalView

    init(id: String, role: PaneRole, name: String, worktree: String, session: TerminalSession) {
        self.id = id
        self.role = role
        self.name = name
        self.worktree = worktree
        self.session = session
        self.view = TerminalView(session: session)
    }

    var displayTitle: String {
        switch role {
        case .orchestrator: return "orchestrator"
        case .delegate: return "delegate: \(name)"
        case .shell: return name
        }
    }

    /// Types `text` into the pane as if the user had (spec §4.1 item 7).
    /// This is how Gater wakes the orchestrator.
    func inject(text: String, submit: Bool = true) {
        session.inject(text: text, submit: submit)
    }
}
