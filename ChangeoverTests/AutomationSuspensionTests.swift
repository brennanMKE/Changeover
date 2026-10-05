import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0189 — whether the app should be deciding things for itself.
///
/// The rule is one comparison, and the reason it has a type and a test file of its
/// own is the transition rather than the state. An agent that suspends the app's
/// automation and then dies must not leave the user's next disc sitting there
/// doing nothing — so "the count dropped to zero" is the case that matters, and
/// the one a flag-based design could not get right at all.
struct AutomationSuspensionTests {

    @Test func nothingAttachedMeansTheAppDecidesAsItAlwaysHas() {
        #expect(!AutomationSuspension.isSuspended(attachedSessions: 0))
        #expect(AutomationSuspension.reason(attachedSessions: 0) == nil)
    }

    @Test func oneWatcherSuspends() {
        #expect(AutomationSuspension.isSuspended(attachedSessions: 1))
    }

    /// Scoped to the count, not to a toggle. Two watchers attached and one
    /// detaching must leave automation suspended — otherwise an agent's own second
    /// terminal window ending a session would hand control back mid-decision.
    @Test func twoWatchersWithOneLeavingStaysSuspended() {
        #expect(AutomationSuspension.isSuspended(attachedSessions: 2))
        #expect(AutomationSuspension.isSuspended(attachedSessions: 1))
        #expect(!AutomationSuspension.didResume(from: 2, to: 1))
    }

    /// The transition the whole design rests on. This is what a `kill -9` of the
    /// CLI produces: the connection invalidates, the app reaps the session from
    /// the invalidation handler — the only signal it gets — and the count falls to
    /// zero with nothing to clean up.
    @Test func theLastWatcherLeavingResumes() {
        #expect(AutomationSuspension.didResume(from: 1, to: 0))
        #expect(!AutomationSuspension.isSuspended(attachedSessions: 0))
    }

    @Test func theLastOfSeveralLeavingResumes() {
        #expect(AutomationSuspension.didResume(from: 3, to: 0))
    }

    /// Attaching is not resuming. A caller that acts on the edge must not be
    /// triggered by the opposite one.
    @Test func attachingIsNotAResumption() {
        #expect(!AutomationSuspension.didResume(from: 0, to: 1))
        #expect(!AutomationSuspension.didResume(from: 0, to: 0))
    }

    /// A negative count cannot happen — the registry only adds and removes — but
    /// is treated as zero rather than trusted. The one thing this must never do is
    /// suspend automation for a user with no agent anywhere near their machine.
    @Test func aNonsensicalCountNeverSuspends() {
        #expect(!AutomationSuspension.isSuspended(attachedSessions: -1))
        #expect(AutomationSuspension.reason(attachedSessions: -1) == nil)
    }

    // MARK: - The sentence a user reads

    /// The count is in the sentence because "something is watching" is not
    /// actionable and "2 sessions are watching" tells a person there is more than
    /// one thing to go and stop.
    @Test func theReasonNamesTheCountAndTheCommand() throws {
        let one = try #require(AutomationSuspension.reason(attachedSessions: 1))
        #expect(one.contains("1 changeoverctl watch session is"))
        #expect(one.contains("not choosing a film"))

        let two = try #require(AutomationSuspension.reason(attachedSessions: 2))
        #expect(two.contains("2 changeoverctl watch sessions are"))
    }

    // MARK: - The wire shape

    @Test func theStatusProjectionAgrees() {
        let idle = BridgeStatusReader.automationStatus(attachedSessions: 0, interruptedAt: nil)
        #expect(!idle.suspended)
        #expect(idle.heldBySessions == 0)
        #expect(idle.reason == nil)

        let held = BridgeStatusReader.automationStatus(attachedSessions: 2, interruptedAt: nil)
        #expect(held.suspended)
        #expect(held.heldBySessions == 2)
        #expect(held.reason != nil)
    }

    /// A nonsensical count must not be reported as a negative number of sessions
    /// holding a suspension that is not in force.
    @Test func theStatusProjectionClampsANonsensicalCount() {
        let status = BridgeStatusReader.automationStatus(attachedSessions: -3, interruptedAt: nil)
        #expect(!status.suspended)
        #expect(status.heldBySessions == 0)
    }
}

// MARK: - The flow's own view of it

/// #0189 — `RipFlowController` asks how many sessions are attached through a
/// closure defaulted to zero, so the flow knows nothing about XPC and every
/// existing construction site keeps today's behaviour.
///
/// These assert the default and the wiring, not the automation itself: whether a
/// countdown actually starts is `AutoStartPolicy`'s question and has its own
/// tests.
@MainActor
struct RipFlowAutomationSuspensionTests {

    @Test func aFreshControllerIsNotSuspended() {
        let flow = RipFlowController()
        #expect(flow.attachedAgentSessions() == 0)
        #expect(!flow.isAutomationSuspended)
    }

    @Test func theProviderDecidesSuspension() {
        let flow = RipFlowController()
        flow.attachedAgentSessions = { 1 }
        #expect(flow.isAutomationSuspended)

        flow.attachedAgentSessions = { 0 }
        #expect(!flow.isAutomationSuspended)
    }

    /// The provider is read every time, not cached. A watcher can attach or die at
    /// any point during a countdown, and a cached answer would let the app start a
    /// job a second after an agent took control.
    @Test func theProviderIsReadEveryTime() {
        let flow = RipFlowController()
        var attached = 0
        flow.attachedAgentSessions = { attached }

        #expect(!flow.isAutomationSuspended)
        attached = 1
        #expect(flow.isAutomationSuspended)
        attached = 0
        #expect(!flow.isAutomationSuspended)
    }
}
