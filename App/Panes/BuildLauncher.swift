import AppKit
import G8rCore
import G8rSymbols

/// Click to build, in the app. `BuildCoordinator` makes the decisions and
/// does the git work; this lends it the window's panes to run sessions in,
/// and moves its checks and merges off the main thread.
final class BuildLauncher: BuildHost {
    private let paneManager: PaneManager
    private let record: (G8rEvent) -> Void
    private var coordinator: BuildCoordinator!

    init(paneManager: PaneManager, planRoot: String, record: @escaping (G8rEvent) -> Void) {
        self.paneManager = paneManager
        self.record = record
        coordinator = BuildCoordinator(
            planRoot: planRoot, agent: paneManager.agent, agentCommand: paneManager.agentCommand,
            hookBinary: paneManager.hookBinaryPath(), host: self, record: record,
            scanner: TreeSitterScanner(),
            background: { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
            main: { DispatchQueue.main.async(execute: $0) })
    }

    func build(_ component: String, in map: LivingMap) throws {
        try coordinator.build(component, in: map)
    }

    /// Every event, from the hooks and from the app. A `stop` from a
    /// `build-<id>` pane runs that session's checks; a closed build pane
    /// ends its session.
    func handle(_ event: G8rEvent) {
        coordinator.handle(event)
    }

    /// Closes the open build panes, so the log says their sessions ended.
    /// Their worktrees and branches stay for the next build.
    func closeAll() {
        for pane in coordinator.openPanes { close(pane: pane) }
    }

    // MARK: - BuildHost

    func open(_ launch: BuildLaunch) throws {
        let pane = try paneManager.spawnBuild(launch)
        guard launch.idleOnExit else { return }
        // Nothing reports this agent going idle: its command exiting,
        // which ends the pane's shell, is its going idle.
        pane.session.onExit = { [weak self] _ in
            self?.record(G8rEvent(kind: "stop", extra: [
                "pane": .string(launch.pane), "component": .string(launch.component),
            ]))
        }
    }

    func tell(_ text: String, pane: String) {
        paneManager.pane(id: pane)?.inject(text: text)
    }

    func close(pane id: String) {
        guard let pane = paneManager.pane(id: id) else { return }
        paneManager.close(pane)
    }
}
