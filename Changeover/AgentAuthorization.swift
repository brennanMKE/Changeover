import ChangeoverBridge
import Foundation

/// #0196 — who may tell the app to *do* something.
///
/// ## The problem this is answering, stated honestly
///
/// `AppXPCServer` has no authentication of any kind. The listener is anonymous,
/// but the endpoint is handed to anything that asks the broker for it, and the
/// broker asks nothing of its caller. Any process running as this user can open
/// the connection and call every method the protocol exposes. That was acceptable
/// for the whole of #0189, because every verb only read. It stops being
/// acceptable the moment a verb can eject a disc mid-session or start an encode
/// that writes into a Plex library.
///
/// It is worth being precise about what the remaining exposure is, because a
/// mitigation described as more than it is, is worse than none. A process running
/// as this user can already run `osascript`, write to `~/Library`, and launch
/// `HandBrakeCLI` itself. The bridge does not grant it a new *privilege*. What it
/// grants is **reach into a running app's state** — the ability to make
/// Changeover act, attributed to Changeover, with Changeover's own file access,
/// and with no trace that anything else was involved. That is the thing worth
/// closing.
///
/// ## What was chosen
///
/// **Every acting verb is refused unless a `changeoverctl watch` session is
/// attached.** Not a token, not a mode, not a flag — the same live session count
/// that `AutomationSuspension` is already scoped to.
///
/// Four reasons, in the order they weighed:
///
/// 1. **It makes acting visible by construction.** #0195 draws the agent banner
///    from the session count, and names the last verb asked for. Tie acting to a
///    session and the banner is on screen for the whole of every act — there is
///    no arrangement of calls that ejects a disc while the window still looks
///    idle. Making a destructive act *visible* is worth more here than making it
///    hard, because the realistic threat is not an attacker: it is a confused
///    script, a second agent session, or a stale `import` fired after the user
///    changed their mind. All three are things a person can see and stop.
/// 2. **It is a capability, not a secret.** There is nothing to leak and nothing
///    to rotate. The thing that authorises is the thing the user can kill, and
///    killing it is already the documented way to hand the app back.
/// 3. **It closes the race as a side effect.** The app suspends its own
///    automation only while a session is attached. An acting verb with no session
///    would be acting *against* an app that is still choosing films and starting
///    countdowns of its own — two deciders, which is exactly what #0189's
///    suspension exists to prevent. Allowing it would have been incoherent, not
///    merely insecure.
/// 4. **It cannot be bypassed by a flag.** `eject --force` overrides the
///    *job-running* refusal and nothing else. There is deliberately no flag that
///    overrides this one, because a flag that waives authorisation is
///    authorisation that does not exist.
///
/// `--session <id>` is accepted and checked when given. It is not required,
/// because `changeoverctl watch` and `changeoverctl eject` are separate processes
/// and the second cannot know the first's id without being told. Supplying it is
/// how a careful agent binds its acts to *its own* watcher instead of to whatever
/// happens to be attached — and a stale id is refused rather than silently
/// falling back, so an agent whose watcher died learns that from the refusal
/// rather than from a disc that came out of the drive during somebody else's job.
///
/// ## What this is NOT, and what is left open
///
/// It is **not** authentication. The acting client is not identified; nothing
/// proves the process that called `eject` is the process that holds the session,
/// and a hostile local process can trivially open its own `watch` session and
/// then act. That hole is not closable from here: the only real fix is verifying
/// the *peer* at connection-accept time — `SecCodeCopyGuestWithAttributes` on the
/// connection's pid, checked against a `SecRequirement` naming this project's
/// Team ID and the `changeoverctl` identifier — which is a Phase 3 change to
/// `BridgeListenerDelegate.listener(_:shouldAcceptNewConnection:)` and was
/// deliberately not attempted on this ticket. Two reasons, both about risk rather
/// than effort: an unsigned development build satisfies no requirement, so the
/// check has to be conditional on the host being signed, and getting that
/// condition wrong refuses *every* connection — breaking the working CLI on the
/// user's machine, which is being used for real imports right now. A refusal at
/// accept time is also silent, which is the single worst failure shape this
/// transport has.
///
/// Pure and `nonisolated` for the reason `StartGate`, `EjectPolicy` and
/// `AutomationSuspension` are: the refusals are the entire user-visible behaviour
/// of the rule, UI tests are forbidden in this project, and a decision that can
/// only be exercised with a live XPC connection is a decision with no coverage.
nonisolated enum AgentAuthorization {

    /// Whether a verb may run, and what to say when it may not.
    nonisolated enum Decision: Equatable, Sendable {
        case allow
        /// An ``ActionOutcome`` identifier and the sentence to report.
        case refuse(outcome: String, reason: String)

        var refusal: (outcome: String, reason: String)? {
            if case .refuse(let outcome, let reason) = self { return (outcome, reason) }
            return nil
        }
    }

    /// The sentence a verb with no session attached is refused with.
    ///
    /// Names the remedy, because the remedy is not guessable: an agent reading
    /// "refused" has no way to know that the fix is a *different command* it has
    /// not run yet.
    static let noSessionReason =
        "no changeoverctl watch session is attached, so Changeover will not act on an "
        + "agent's behalf. A watch session is what suspends the app's own automation and "
        + "what tells the user an agent is in control, so an acting verb without one "
        + "would be both racing the app and invisible. Run "
        + "`changeoverctl watch --json > events.jsonl &` first, and keep it attached."

    /// - Parameters:
    ///   - action: the ``BridgeRequest/Action`` name. A verb that is not in
    ///     ``BridgeRequest/Action/acting`` is allowed unconditionally — `status`,
    ///     `watch` and `report` only read.
    ///   - attachedSessions: the live session count.
    ///   - requestedSessionID: `--session`, when the caller named one.
    ///   - liveSessionIDs: the ids the server currently holds.
    static func decide(
        action: String,
        attachedSessions: Int,
        requestedSessionID: String? = nil,
        liveSessionIDs: Set<String> = []
    ) -> Decision {
        // A reading verb needs nothing. Checked first so `report` — which an
        // agent will want *after* its watcher has gone, to find out what
        // happened — is never gated on the thing that has ended.
        guard BridgeRequest.Action.acting.contains(action) else { return .allow }

        // The count, not the id set, is the authority on whether anything is
        // attached. They cannot disagree in the server, but reading the count is
        // what `AutomationSuspension` and the #0195 banner read, and three
        // readers of one fact must not become three definitions of it.
        guard AutomationSuspension.isSuspended(attachedSessions: attachedSessions) else {
            return .refuse(outcome: ActionOutcome.refusedNoSession, reason: noSessionReason)
        }

        // An id that names nothing is refused rather than ignored. An agent whose
        // watcher died and whose `--session` is now stale is in a state it needs
        // told about: its events are going nowhere, and the next thing it would
        // do is act blind.
        if let requestedSessionID, !liveSessionIDs.contains(requestedSessionID) {
            return .refuse(
                outcome: ActionOutcome.refusedUnknownSession,
                reason: "session '\(requestedSessionID)' is not attached"
                    + (liveSessionIDs.isEmpty
                        ? "."
                        : " — the attached ones are \(liveSessionIDs.sorted().joined(separator: ", "))."
                    )
                    + " Your watcher may have exited; its events are going nowhere."
            )
        }

        return .allow
    }
}
