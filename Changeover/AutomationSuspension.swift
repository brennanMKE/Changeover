import Foundation

/// #0189 — whether the app should make decisions of its own right now.
///
/// Changeover automates two things without being asked: it pre-selects a film
/// from TMDB when the runtime matches (`RipFlowController.attemptAutoSelect`),
/// and it starts the job after a countdown (`AutoStartPolicy`). Both are right
/// when a person is standing at the machine feeding it discs. Both are wrong
/// when an agent is driving, because **two deciders race**: the agent reads the
/// scan, thinks about what the disc is, and by the time it answers the app has
/// already picked something else and started encoding it.
///
/// So automation is suspended while an agent is attached. The question is what
/// "attached" should be scoped to, and the answer is the only part of this worth
/// arguing about.
///
/// **Not a mode, and not a flag.** The obvious design is a command that switches
/// the app into agent mode and another that switches it back. That design has a
/// failure mode it cannot avoid: an agent that crashes — or is killed, or loses
/// its connection — while holding the flag leaves the app permanently passive,
/// and the next person to put a disc in gets a window that sits there doing
/// nothing with no explanation of why. There is no timeout that fixes this
/// honestly, because "the agent is thinking" and "the agent is dead" look
/// identical from here.
///
/// **Scoped to live `watch` sessions instead.** The thing that suspends the app's
/// decisions is the same thing whose death restores them. A `kill -9` of the CLI
/// invalidates its XPC connection, the app reaps the session from the connection's
/// invalidation handler — the only signal it gets — the count drops to zero, and
/// automation resumes with nothing to clean up. That is the case that matters:
/// the RemoteControl prototype's manual test script singles out "CLI killed
/// mid-session" as the variant worth getting right, because Ctrl-C exercises the
/// *clean* path instead and the clean path was never the risk.
///
/// A count, not a boolean, because two watchers can be attached and one
/// detaching must leave automation suspended. Pure and `nonisolated` so the
/// transition that matters — the drop to zero — can be asserted without an app,
/// a disc, or an XPC connection, the convention `StartGate` and `AutoStartPolicy`
/// already follow.
nonisolated enum AutomationSuspension {

    /// Whether the app's own automation is suspended.
    ///
    /// Any attached session suspends. A negative count cannot happen — the
    /// session registry only ever adds and removes — but is treated as zero
    /// rather than trusted, because the one thing this must never do is suspend
    /// automation for a user with no agent anywhere near their machine.
    static func isSuspended(attachedSessions: Int) -> Bool {
        attachedSessions > 0
    }

    /// What to tell a user looking at an idle disc.
    ///
    /// `nil` when nothing is suspended, so a caller can treat the presence of a
    /// reason as the condition. The count is in the sentence because "something
    /// is watching" is not actionable and "2 sessions are watching" tells a
    /// person there is more than one thing to go and stop.
    static func reason(attachedSessions: Int) -> String? {
        guard isSuspended(attachedSessions: attachedSessions) else { return nil }
        let count = attachedSessions
        let plural = count == 1 ? "session is" : "sessions are"
        return "\(count) changeoverctl watch \(plural) attached, "
            + "so Changeover is not choosing a film or starting a job by itself."
    }

    /// Whether automation just became available again.
    ///
    /// The transition, not the state: a caller that resumes work needs to act
    /// once, on the edge, rather than every time it happens to look. This is the
    /// drop-to-zero the kill-9 path produces.
    static func didResume(from previousSessions: Int, to currentSessions: Int) -> Bool {
        isSuspended(attachedSessions: previousSessions)
            && !isSuspended(attachedSessions: currentSessions)
    }
}
