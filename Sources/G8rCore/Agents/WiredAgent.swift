import Foundation

/// The agent the Build button uses: the one most recently started through
/// a shim, in a pane of this run of the app. Until someone starts `claude`
/// or `codex` in a pane there is none, and building is refused.
///
/// An `agent_started` from before `since` (an earlier run, replayed from
/// the log) doesn't count: that agent may not even be installed any more.
public struct WiredAgent: Equatable, Sendable {
    /// When this run of the app started. Event times are whole seconds, so
    /// anything in the second the app started counts.
    public let since: Date
    public private(set) var agent: Agent?
    /// The pane it was started in.
    public private(set) var pane: String?

    public init(since: Date) {
        self.since = Date(timeIntervalSince1970: floor(since.timeIntervalSince1970))
    }

    /// It was given something to do and hasn't gone idle since: its pane
    /// has had an edit, a command, a typed line or a change request after
    /// its last `stop`. Both agents queue what is typed while they work.
    public private(set) var busy = false

    /// Takes in one event; true when it changed the agent.
    @discardableResult
    public mutating func note(_ event: G8rEvent) -> Bool {
        guard event.kind == "agent_started" else {
            noteActivity(event)
            return false
        }
        guard let agent = event["agent"]?.stringValue.flatMap(Agent.init(name:)),
              let ts = event.ts.flatMap({ ISO8601DateFormatter().date(from: $0) }), ts >= since
        else { return false }
        let changed = agent != self.agent
        self.agent = agent
        pane = event.pane
        // A freshly started agent waits at its prompt.
        busy = false
        return changed
    }

    private mutating func noteActivity(_ event: G8rEvent) {
        guard let pane, event.pane == pane else { return }
        switch event.kind {
        case "stop": busy = false
        case "edit", "command", "human_intervention", ChangeRequest.eventKind: busy = true
        default: break
        }
    }

    /// Why Build is off while there is no agent, for the map to show.
    public static let missing = "Start claude or codex in a shell to build."
}
