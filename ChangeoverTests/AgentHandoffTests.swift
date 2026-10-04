import Foundation
import Testing
@testable import Changeover

/// #0210 — a restart must not hand the disc back to the app.
///
/// `AutomationSuspension` is scoped to the live session count on purpose: no
/// mode flag an agent can crash while holding, and a dead CLI cannot wedge the
/// app. That is right while the app runs and wrong across a restart, because a
/// restart resets the count to zero without anything having finished.
///
/// Seen twice on joe. An install quit the app with an import running and a
/// `watch` session attached; on relaunch the count was zero, automation was
/// live, and within a minute the app had auto-selected a film and taken the
/// start gate through `runtimeLookupLoading` and `libraryCheckInProgress` — on
/// a disc whose agent had been killed rather than having finished. The second
/// time the window was 39 seconds, and nothing happened only because the scan
/// had not finished yet. Neither was a near miss by design.
struct AgentHandoffTests {

    private static let quitAt = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - The rule

    /// The bug: no live session, so nothing was suspended.
    @Test func aRestartAfterAnInterruptedAgentStaysSuspended() {
        #expect(AutomationSuspension.isSuspended(
            attachedSessions: 0,
            interruptedAt: Self.quitAt,
            now: Self.quitAt.addingTimeInterval(39)))
    }

    /// And it is a grace period, not a lock. A user whose agent is never coming
    /// back must not be left with an app that refuses to do anything — the same
    /// reasoning that keeps `watch` from having a mode flag.
    @Test func theGraceExpires() {
        let after = Self.quitAt.addingTimeInterval(AutomationSuspension.handoffGrace + 1)
        #expect(!AutomationSuspension.isSuspended(
            attachedSessions: 0, interruptedAt: Self.quitAt, now: after))
    }

    /// A clean previous exit suspends nothing, which is every ordinary launch.
    @Test func anOrdinaryLaunchIsNotSuspended() {
        #expect(!AutomationSuspension.isSuspended(attachedSessions: 0, interruptedAt: nil))
    }

    /// A live session still suspends regardless, and outlasts the grace.
    @Test func aliveSessionStillSuspends() {
        let longAfter = Self.quitAt.addingTimeInterval(AutomationSuspension.handoffGrace * 10)
        #expect(AutomationSuspension.isSuspended(
            attachedSessions: 1, interruptedAt: nil, now: longAfter))
        #expect(AutomationSuspension.isSuspended(
            attachedSessions: 1, interruptedAt: Self.quitAt, now: longAfter))
    }

    /// A marker from the future is a clock change, not a handoff. Trusting it
    /// would be an app that will not start a job and cannot say why.
    @Test func amarkerFromTheFutureIsIgnored() {
        #expect(!AutomationSuspension.isSuspended(
            attachedSessions: 0,
            interruptedAt: Self.quitAt.addingTimeInterval(60),
            now: Self.quitAt))
    }

    /// The user is told why the app is holding back, since an app that has gone
    /// quiet for a reason is otherwise indistinguishable from one gone wrong —
    /// the fault #0195 exists to prevent, arriving in a new place.
    @Test func thereIsASentenceForIt() throws {
        let reason = try #require(AutomationSuspension.interruptedReason(
            interruptedAt: Self.quitAt, now: Self.quitAt.addingTimeInterval(30)))
        #expect(reason.contains("agent"))
        #expect(reason.contains("quit"))
        #expect(AutomationSuspension.interruptedReason(interruptedAt: nil) == nil)
    }

    // MARK: - The marker

    private func defaults() throws -> UserDefaults {
        let suite = "AgentHandoffTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    /// Written only when the app quits *with* an agent attached.
    @Test func quittingWithAnAgentAttachedIsRecorded() throws {
        let store = try defaults()
        AgentHandoff.noteQuit(attachedSessions: 1, at: Self.quitAt, defaults: store)
        #expect(AgentHandoff.interruptedAt(defaults: store) == Self.quitAt)
    }

    /// An ordinary quit records nothing — and clears any earlier marker, so a
    /// restart after a normal session cannot inherit a suspension from one
    /// before it.
    @Test func anOrdinaryQuitClearsTheMarker() throws {
        let store = try defaults()
        AgentHandoff.noteQuit(attachedSessions: 2, at: Self.quitAt, defaults: store)
        AgentHandoff.noteQuit(attachedSessions: 0, at: Self.quitAt, defaults: store)
        #expect(AgentHandoff.interruptedAt(defaults: store) == nil)
    }

    /// Clearing is what an agent reattaching does: the handoff has happened, so
    /// the grace must not outlive it.
    @Test func clearingForgetsIt() throws {
        let store = try defaults()
        AgentHandoff.noteQuit(attachedSessions: 1, at: Self.quitAt, defaults: store)
        AgentHandoff.clear(defaults: store)
        #expect(AgentHandoff.interruptedAt(defaults: store) == nil)
        #expect(!AutomationSuspension.isSuspended(
            attachedSessions: 0, interruptedAt: AgentHandoff.interruptedAt(defaults: store)))
    }

    /// A fresh profile has no marker, so a first launch is never suspended.
    @Test func afreshProfileHasNoMarker() throws {
        #expect(AgentHandoff.interruptedAt(defaults: try defaults()) == nil)
    }
}
