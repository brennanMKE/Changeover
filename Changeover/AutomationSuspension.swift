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

    // MARK: - #0210: across a quit

    /// How long automation stays suspended after the app quits with an agent
    /// attached.
    ///
    /// Reported on joe: an install quit the app mid-import, and when it came
    /// back the session count was zero, so automation was live — on a disc an
    /// agent had been working forty seconds earlier. Within a minute the app
    /// had auto-selected a film and run the start gate through
    /// `runtimeLookupLoading` and `libraryCheckInProgress`. Only the countdown
    /// not finishing before the agent reattached stopped it starting a rip by
    /// itself, on a disc whose decider had been killed rather than having
    /// finished.
    ///
    /// Five minutes: long enough for a CLI to notice its connection dropped and
    /// reattach, short enough that a user whose agent is never coming back is
    /// not left with an app that refuses to do anything. It is a grace period
    /// and not a lock, which is the same reasoning as `watch` having no mode
    /// flag — nothing an agent can crash while holding.
    static let handoffGrace: TimeInterval = 300

    /// Whether automation is suspended, counting a quit that interrupted an
    /// agent.
    ///
    /// - Parameter interruptedAt: when the app last quit **while** a session
    ///   was attached, or `nil` if its last exit was clean. A clean detach while
    ///   the app keeps running is deliberately not recorded: the count drops to
    ///   zero, automation resumes, and that has always been right. What is being
    ///   recovered here is specifically the agent that never got to say goodbye.
    static func isSuspended(
        attachedSessions: Int,
        interruptedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        if isSuspended(attachedSessions: attachedSessions) { return true }
        guard let interruptedAt else { return false }
        let elapsed = now.timeIntervalSince(interruptedAt)
        // A marker from the future is a clock change, not a handoff. Treated as
        // expired rather than trusted: the failure it would otherwise cause is
        // an app that will not start a job and cannot say why.
        guard elapsed >= 0 else { return false }
        return elapsed < handoffGrace
    }

    /// What to tell a user whose app is holding back after a restart.
    static func interruptedReason(interruptedAt: Date?, now: Date = Date()) -> String? {
        guard isSuspended(attachedSessions: 0, interruptedAt: interruptedAt, now: now),
              let interruptedAt
        else { return nil }
        let left = Int((handoffGrace - now.timeIntervalSince(interruptedAt)).rounded())
        return "Changeover quit while an agent was working this disc, so it is not "
            + "choosing a film or starting a job by itself for another "
            + "\(max(1, left / 60)) minute(s) — in case the agent comes back."
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
