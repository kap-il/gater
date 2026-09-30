import Foundation

/// One build session's progress, from the prompt to the merge. Pure: it
/// decides what to do next and leaves the doing to whoever holds it.
///
///     working ──idle──► checking(1) ──passed──► (merge) ──merged──► merged
///        ▲                  │                      └──mergeFailed──► needsHuman
///        └──── tell ◄──failed (round < 3)
///                           └──failed (round 3)──► needsHuman
public struct BuildSession: Equatable {
    public enum State: Equatable {
        case working, checking(round: Int), merged(commit: String), needsHuman(reason: String)
    }

    public enum Input: Equatable {
        /// The session stopped and is waiting.
        case wentIdle
        case checked(passed: Bool, tail: String)
        case merged(commit: String)
        case mergeFailed(reason: String)
    }

    public enum Action: Equatable {
        case runChecks(round: Int)
        case merge
        /// Type this into the session.
        case tell(text: String)
        /// Close the pane and remove the worktree.
        case close
        case none
    }

    public let component: String
    public private(set) var state: State
    /// Rounds of checks that failed so far.
    public private(set) var failedRounds = 0
    /// After this many failed rounds g8r stops typing and leaves the
    /// session to a person.
    public static let maxRounds = 3

    public init(component: String) {
        self.component = component
        self.state = .working
    }

    /// Moves on from `input`. An input the state isn't waiting for, such as
    /// the session going idle while its checks run, changes nothing.
    public mutating func handle(_ input: Input) -> Action {
        switch (state, input) {
        case (.working, .wentIdle):
            let round = failedRounds + 1
            state = .checking(round: round)
            return .runChecks(round: round)

        case (.checking, .checked(passed: true, _)):
            return .merge

        case let (.checking(round), .checked(passed: false, tail)):
            failedRounds = round
            if round >= Self.maxRounds {
                state = .needsHuman(reason: "The checks failed \(round) times. Last failure:\n\(tail)")
                return .none
            }
            state = .working
            return .tell(text: Self.failure(round: round, tail: tail))

        case let (.checking, .merged(commit)):
            state = .merged(commit: commit)
            return .close

        case let (.checking, .mergeFailed(reason)):
            state = .needsHuman(reason: "Couldn't merge into \(Integrator.branch): \(reason)")
            return .none

        default:
            return .none
        }
    }

    /// What a session is told when its checks fail.
    static func failure(round: Int, tail: String) -> String {
        """
        g8r checked this worktree and it isn't done (round \(round) of \(maxRounds)):

        \(tail)

        Fix it, commit, and stop again when the done-when holds.
        """
    }
}
