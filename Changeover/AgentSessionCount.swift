import Foundation

/// #0203 — how many agents are driving the app, as distinct from how many
/// sessions are open.
///
/// The user, looking at the window while one agent worked a disc: "I still see
/// 2 agents." There was one. It was running `changeoverctl watch` to receive
/// events and `changeoverctl wait --for job-done` to block until the encode
/// finished, and `wait` holds a session of its own — so the banner counted the
/// agent twice and `status` reported `heldBySessions: 2`.
///
/// The user's model of the tool is the right one, and it is the one
/// `docs/cli-for-agents.md` describes: **one watcher stays attached and
/// receives events; every other command is brief — connect, act, disconnect —
/// and is not an agent.** `wait` was the only verb that broke it, and only
/// because it needs a session for a reason that has nothing to do with being
/// counted: it reads the event stream rather than polling `status`.
///
/// So a waiting session **sustains** the count and never **adds** to it:
///
/// | watch | wait | agents |
/// |---|---|---|
/// | 1 | 0 | 1 |
/// | 1 | 1 | 1 — one agent watching and waiting |
/// | 1 | 3 | 1 |
/// | 2 | 1 | 2 — the wait belongs to one of them |
/// | 0 | 1 | 1 — `wait` alone still suspends automation |
/// | 0 | 2 | 2 — two agents, each only waiting |
/// | 0 | 0 | 0 |
///
/// The `0 watch` rows are what keeps `wait` usable on its own. An agent that
/// only ever calls `wait` still suspends the app's automation and still passes
/// `AgentAuthorization`, exactly as before — which matters because the app
/// must not start a job underneath something that is waiting for a different
/// one.
///
/// Where it is imprecise, it undercounts rather than over: one watcher plus a
/// `wait` belonging to a *second* agent reads as one agent. That is not
/// knowable from this side — two sessions from two processes are two processes
/// whether or not one program spawned both — and of the two errors, a banner
/// that says "1 agent" while two are attached is better than one that says "2"
/// when the user can see only one. The honest count of sessions is still
/// reported under `app.sessions`.
nonisolated enum AgentSessionCount {

    /// The number to show the user and to suspend automation on.
    static func agents(watching: Int, waiting: Int) -> Int {
        precondition(watching >= 0 && waiting >= 0)
        return watching > 0 ? watching : waiting
    }

    /// What a session was opened for.
    ///
    /// On the wire as a plain action name, so an older CLI that only knows
    /// `watch` keeps working and is simply counted as a watcher — which is what
    /// it is.
    nonisolated enum Purpose: String, Equatable, Sendable, CaseIterable {
        /// `changeoverctl watch` — attached indefinitely, receiving events.
        case watching
        /// `changeoverctl wait` — attached only until its condition is met.
        case waiting

        /// The `BridgeRequest.Action` that opens a session of this purpose.
        var action: String {
            switch self {
            case .watching: return "watch"
            case .waiting:  return "wait"
            }
        }

        /// `nil` for an action that does not open a session at all.
        init?(action: String) {
            guard let match = Purpose.allCases.first(where: { $0.action == action }) else {
                return nil
            }
            self = match
        }
    }
}
