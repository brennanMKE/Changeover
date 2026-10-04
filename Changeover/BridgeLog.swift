import ChangeoverBridge
import Foundation
import OSLog

/// #0189 — where the CLI bridge writes what it did.
///
/// Both destinations, deliberately, because each one is the only one that works
/// somewhere that matters:
///
/// - **`FlowDiagnostics`** — a plain text file under Application Support. This is
///   the one that works on the Plex host. `NSLog` from this app does not reach
///   `log show` there; nothing written through it was findable by any predicate,
///   including lines that certainly ran. A file needs nothing and is trivial to
///   read from a session with no access to the window server, which is every
///   session that debugs this.
/// - **`os.Logger`** — the unified log, on the subsystem the broker agent and the
///   CLI also use. Four processes end up involved in a single endpoint handoff
///   and they cannot all be held in a debugger at once, so
///   `log stream --predicate 'subsystem == "co.sstools.Changeover"'` is the only
///   practical way to watch one end to end on a machine where it does work.
///
/// `nonisolated` because the XPC listener delegate and the connection handlers
/// call it from XPC's own queues, and under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` it would otherwise be main-actor
/// isolated and unreachable from them.
nonisolated enum BridgeLog {
    private static let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "bridge")

    static func note(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FlowDiagnostics.note("bridge: \(message)")
    }
}
