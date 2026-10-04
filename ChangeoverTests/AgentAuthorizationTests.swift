import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0196 — who may tell the app to *do* something.
///
/// `AppXPCServer` authenticates nothing: the broker hands the app's endpoint to
/// whoever asks, and asks nothing of them. That was fine while every verb read.
/// The mitigation chosen for the verbs that act is that **an acting verb is refused
/// unless a `changeoverctl watch` session is attached** — the same live session
/// count `AutomationSuspension` is scoped to and the #0195 banner is drawn from, so
/// nothing can eject a disc or start an encode without the person at the machine
/// being able to see that something else is in charge.
///
/// The rule's whole externally visible behaviour is its refusals, and UI tests are
/// forbidden here, so this file is the coverage. The case that matters most is the
/// last one: there is deliberately no flag that waives it.
@Suite struct AgentAuthorizationTests {

    // MARK: - Reading verbs need nothing

    /// `status`, `watch` and `report` observe, so they are allowed with nothing
    /// attached. `report` in particular: an agent asks it *after* its watcher has
    /// gone, to find out what happened, and gating it on the thing that has ended
    /// would make it useless exactly when it is wanted.
    @Test(arguments: ["status", "watch", "report", "ping", "help"])
    func areadingVerbIsAllowedWithNothingAttached(_ action: String) {
        #expect(AgentAuthorization.decide(action: action, attachedSessions: 0) == .allow)
    }

    // MARK: - Acting verbs need a session

    @Test(arguments: Array(BridgeRequest.Action.acting).sorted())
    func anActingVerbIsRefusedWithNothingAttached(_ action: String) {
        let decision = AgentAuthorization.decide(action: action, attachedSessions: 0)
        #expect(decision.refusal?.outcome == ActionOutcome.refusedNoSession)
    }

    @Test(arguments: Array(BridgeRequest.Action.acting).sorted())
    func anActingVerbIsAllowedWithOneAttached(_ action: String) {
        #expect(AgentAuthorization.decide(action: action, attachedSessions: 1) == .allow)
    }

    /// The four verbs that act are exactly the four that change something. A verb
    /// added to the dispatch switch and forgotten here would act unauthorised, and
    /// the failure would be silent — so the **set** is what is asserted, not the
    /// switch.
    @Test func theActingSetIsTheFourVerbsThatChangeSomething() {
        #expect(BridgeRequest.Action.acting == ["eject", "cancel", "select", "import"])
    }

    /// Named, because the remedy is a *different command* the agent has not run —
    /// not something it can work out from "refused".
    @Test func theRefusalNamesTheRemedy() {
        let decision = AgentAuthorization.decide(action: "eject", attachedSessions: 0)
        let reason = decision.refusal?.reason ?? ""
        #expect(reason.contains("changeoverctl watch"))
    }

    /// A negative count cannot happen — the registry only adds and removes — but it
    /// must not be read as "suspended", because the one thing this must never do is
    /// act for a user with no agent anywhere near their machine.
    @Test func anImpossibleNegativeCountIsStillARefusal() {
        #expect(
            AgentAuthorization.decide(action: "import", attachedSessions: -1).refusal?.outcome
                == ActionOutcome.refusedNoSession
        )
    }

    // MARK: - --session

    /// Optional, because `changeoverctl watch` and `changeoverctl eject` are
    /// separate processes and the second cannot know the first's id without being
    /// told.
    @Test func anActingVerbWithoutASessionIDIsAllowedWhenSomethingIsAttached() {
        #expect(
            AgentAuthorization.decide(
                action: "eject",
                attachedSessions: 1,
                requestedSessionID: nil,
                liveSessionIDs: ["s1"]
            ) == .allow
        )
    }

    @Test func aNamedSessionThatIsAttachedIsAllowed() {
        #expect(
            AgentAuthorization.decide(
                action: "import",
                attachedSessions: 2,
                requestedSessionID: "s2",
                liveSessionIDs: ["s1", "s2"]
            ) == .allow
        )
    }

    /// Refused rather than quietly falling back to "whatever is attached". An agent
    /// whose watcher died is in a state it needs told about: its events are going
    /// nowhere, and the next thing it would do is act blind — possibly during
    /// somebody else's job.
    @Test func aStaleSessionIDIsRefusedRatherThanIgnored() {
        let decision = AgentAuthorization.decide(
            action: "eject",
            attachedSessions: 1,
            requestedSessionID: "s9",
            liveSessionIDs: ["s1"]
        )
        #expect(decision.refusal?.outcome == ActionOutcome.refusedUnknownSession)
        let reason = decision.refusal?.reason ?? ""
        #expect(reason.contains("s9"))
        // Lists the real ones, so the agent can correct itself in one step.
        #expect(reason.contains("s1"))
    }

    /// The no-session refusal is checked before the id, so an agent with nothing
    /// attached is told the useful thing rather than that its id is unknown.
    @Test func noSessionBeatsAnUnknownSessionID() {
        #expect(
            AgentAuthorization.decide(
                action: "cancel",
                attachedSessions: 0,
                requestedSessionID: "s9",
                liveSessionIDs: []
            ).refusal?.outcome == ActionOutcome.refusedNoSession
        )
    }

    // MARK: - The rule agrees with the suspension it is scoped to

    /// One definition of "an agent is attached", read by three things: the
    /// automation suspension, the #0195 banner, and this. Three readers of one fact
    /// must not become three definitions of it.
    @Test(arguments: [0, 1, 2, 7])
    func authorisationTracksTheAutomationSuspension(_ sessions: Int) {
        let allowed = AgentAuthorization.decide(action: "eject", attachedSessions: sessions) == .allow
        #expect(allowed == AutomationSuspension.isSuspended(attachedSessions: sessions))
        #expect(allowed == AgentMode.isActive(attachedSessions: sessions))
    }
}
