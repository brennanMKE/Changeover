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

    /// Records that an agent is attached **now**.
    ///
    /// Called when a session opens, not when the app quits. #0210 first wrote
    /// this at `applicationWillTerminate`, which covers a graceful quit and
    /// nothing else: a `kill`, a crash, or the install script's own `pkill`
    /// fallback all skip it, and those are exactly the endings an agent is most
    /// likely to be attached for. A flag that is *set while true* survives any
    /// of them, because its absence is what has to be earned.
    static func noteAttached(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }

    /// Records that the last session detached cleanly, so the next launch has
    /// nothing to recover. This is the only thing that clears the flag during a
    /// run, and it is why a clean goodbye costs the user no grace period.
    static func noteAllDetached(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Whether the previous run ended with an agent still attached — read once
    /// at launch, and cleared in the same breath.
    ///
    /// Cleared on read so the flag cannot outlive the launch it describes. Each
    /// launch gets its own grace period or none; a stale flag must never make
    /// an app that is working normally look wedged.
    ///
    /// The grace is measured from **launch**, not from when the flag was
    /// written. An app that ran for two hours with an agent attached and was
    /// then killed would otherwise come back with a two-hour-old timestamp and
    /// no grace at all, which is the case that most needs one.
    static func takeInterruption(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return false }
        defaults.removeObject(forKey: defaultsKey)
        return true
    }
}
