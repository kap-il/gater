import AppKit
import G8rTerminal

enum PaneRole: String {
    /// One per worktree; runs a working `claude`.
    case delegate
    /// One per component being built from the map; ends with the build.
    case build
    /// Plain shell, not tracked.
    case shell
}

/// A terminal pane: its identity in the event log, where it runs, and the
/// live session + view.
final class Pane {
    /// Written to G8R_PANE_ID, so it's what hook events carry as "pane".
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
        case .delegate: return "delegate: \(name)"
        case .build: return "build: \(name)"
        case .shell: return name
        }
    }

    /// Types `text` into the pane as if the user had.
    func inject(text: String, submit: Bool = true) {
        session.inject(text: text, submit: submit)
    }
}
