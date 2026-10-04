import Foundation

/// #0195 — what the window says while an agent is driving.
///
/// `changeoverctl watch` has suspended the app's own automation since #0189,
/// and the app said nothing about it. Reported while an agent was importing
/// bonus features from another session: "the Mac app does not reflect what is
/// happening." From the user's side an app that has gone quiet because
/// something else is in charge is indistinguishable from an app that has gone
/// wrong — the same fault as #0153's silent eject and #0171's unreachable
/// rung, arriving a fourth time in a fourth place.
///
/// Two things have to be visible, and they are different questions:
///
/// 1. **Who is in charge.** The app is not idle; it is deliberately standing
///    back. That is a state, it has a cause, and it ends when the last session
///    detaches — which is also the thing a worried user needs to know they can
///    do something about.
/// 2. **What was last asked.** A session count alone is a light that is on. An
///    agent that asked for something twenty minutes ago and an agent that is
///    working now look identical, and only one of them is a problem.
///
/// Pure, so both sentences are tested rather than merely compiled — UI tests
/// are forbidden in this project.
nonisolated enum AgentMode {

    /// The most recent thing a CLI session asked the app to do.
    nonisolated struct Activity: Equatable, Sendable {
        /// The verb, as `BridgeRequest.Action` spells it.
        var action: String
        var at: Date
        /// What the app made of it, when that is worth saying.
        var detail: String?

        init(action: String, at: Date, detail: String? = nil) {
            self.action = action
            self.at = at
            self.detail = detail
        }
    }

    /// Whether the window should show the agent banner at all.
    ///
    /// Scoped to the session count, exactly as the automation suspension is
    /// (`AutomationSuspension`): the banner appears and disappears with the
    /// thing it is describing, and a crashed agent cannot leave it on screen.
    static func isActive(attachedSessions: Int) -> Bool { attachedSessions > 0 }

    /// The headline. Says what is true rather than what is wrong, because
    /// nothing is wrong.
    static func headline(attachedSessions: Int) -> String {
        attachedSessions == 1
            ? "An agent is in control"
            : "\(attachedSessions) agents are in control"
    }

    /// The sentence under it: what the app is not doing, and why.
    ///
    /// Names `changeoverctl` because that is the thing the user would go and
    /// stop, and says the automation is suspended rather than broken, because
    /// the next disc sitting still is the symptom they will otherwise be
    /// trying to diagnose.
    static let explanation =
        "Changeover will not choose a movie or start a rip by itself while "
        + "changeoverctl is watching. It hands back as soon as the last "
        + "session disconnects."

    /// "Asked to import · 2 minutes ago", or `nil` when nothing has been asked
    /// yet in this session.
    ///
    /// Relative rather than absolute, because the question the user is really
    /// asking is "is this thing still doing something" and a wall-clock time
    /// makes them do the arithmetic.
    static func activityLine(_ activity: Activity?, now: Date = Date()) -> String? {
        guard let activity else { return nil }
        let verb = phrase(forAction: activity.action)
        let elapsed = max(0, now.timeIntervalSince(activity.at))
        var line = "\(verb) · \(ago(elapsed))"
        if let detail = activity.detail, !detail.isEmpty { line += " — \(detail)" }
        return line
    }

    /// The CLI's verb, as a sentence a person reads. An action this build does
    /// not know is shown verbatim rather than hidden: a newer `changeoverctl`
    /// talking to an older app is exactly when the user most needs to see what
    /// was asked for.
    static func phrase(forAction action: String) -> String {
        switch action {
        case "status":  return "Read the status"
        case "watch":   return "Watching"
        case "assets":  return "Gathered the disc's details"
        case "library": return "Checked the library"
        case "search":  return "Searched for a film"
        case "select":  return "Chose what to import"
        case "import":  return "Started an import"
        case "cancel":  return "Cancelled the job"
        case "eject":   return "Ejected the disc"
        case "report":  return "Read the report"
        default:        return "Asked for “\(action)”"
        }
    }

    /// Whole units, largest that fits. "just now" under five seconds, because
    /// "0 seconds ago" is noise and the thing it is describing is live.
    static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<5:     return "just now"
        case ..<60:    return "\(Int(seconds))s ago"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        default:       return "\(Int(seconds / 3_600))h ago"
        }
    }
}
