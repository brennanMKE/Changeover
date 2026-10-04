import Foundation

/// #0210 — the record that the app quit while an agent was in the middle of
/// something.
///
/// `AutomationSuspension` is scoped to the live session count, deliberately:
/// there is no mode flag an agent can crash while holding, and a dead CLI
/// cannot leave the app wedged. That is right while the app is running and
/// wrong across a restart, because a restart resets the count to zero without
/// anything having finished.
///
/// What it cost, on joe: an install quit the app with an import running and a
/// `watch` session attached. On relaunch the count was zero, automation was
/// live, and within a minute the app had auto-selected a film and taken the
/// start gate through `runtimeLookupLoading` and `libraryCheckInProgress` — on
/// a disc whose agent had been killed rather than having finished. Only the
/// countdown failing to complete before the agent reattached stopped it
/// starting a rip of its own choosing.
///
/// Stored in `UserDefaults` as a single date, and only ever written when the
/// app terminates **with a session attached**. A clean detach from a running
/// app writes nothing: the count drops, automation resumes, and that has always
/// been correct. What is being recovered is the agent that never got to say
/// goodbye.
/// `nonisolated` because it touches nothing but `UserDefaults`, which is
/// thread-safe. The project is MainActor-by-default (`CLAUDE.md`), and a type
/// with no reason to be on the main actor should say so — this one is read from
/// `RipFlowController`'s gate and written from `applicationWillTerminate`, and
/// neither wants a hop.
nonisolated enum AgentHandoff {

    /// Where the marker lives. A plain `UserDefaults` key rather than an
    /// `AppSettings` property, because nothing derives from it and nothing in
    /// the app but this type reads it — the one use `docs/settings-screen.md`
    /// endorses for a standalone value.
    static let defaultsKey = "agentInterruptedAt"

    /// Records that the app is quitting while `attachedSessions` agents were
    /// attached. A no-op at zero, which is the ordinary quit.
    static func noteQuit(attachedSessions: Int, at date: Date = Date(),
                         defaults: UserDefaults = .standard) {
        guard attachedSessions > 0 else {
            // An ordinary quit clears any stale marker, so a restart after a
            // normal session cannot inherit a suspension from an earlier one.
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        defaults.set(date, forKey: defaultsKey)
    }

    /// When the app last quit with an agent attached, or `nil`.
    static func interruptedAt(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: defaultsKey) as? Date
    }

    /// Forgets the marker.
    ///
    /// Called when an agent reattaches — the handoff has happened, so the grace
    /// period has done its job and must not outlive it — and when the grace
    /// expires, so the key does not sit in defaults forever.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
