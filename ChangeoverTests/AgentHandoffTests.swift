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

    /// Set while a session is attached — not at termination.
    ///
    /// #0210 first wrote this from `applicationWillTerminate`, which covers a
    /// graceful quit and nothing else. A crash, a `kill`, and the install
    /// script's own `pkill` fallback all skip that callback, and those are
    /// exactly the endings an agent is most likely to be attached for. A flag
    /// that is set *while true* survives all of them, because its absence is
    /// what has to be earned.
    @Test func attachingRecordsIt() throws {
        let store = try defaults()
        AgentHandoff.noteAttached(defaults: store)
        #expect(AgentHandoff.takeInterruption(defaults: store))
    }

    /// A clean goodbye leaves nothing to recover, so the user is charged no
    /// grace period for it.
    @Test func acleanDetachClearsIt() throws {
        let store = try defaults()
        AgentHandoff.noteAttached(defaults: store)
        AgentHandoff.noteAllDetached(defaults: store)
        #expect(!AgentHandoff.takeInterruption(defaults: store))
    }

    /// Read once and cleared in the same breath, so a flag cannot outlive the
    /// launch it describes. Each launch earns its own grace period or none.
    @Test func theFlagIsClearedAsItIsRead() throws {
        let store = try defaults()
        AgentHandoff.noteAttached(defaults: store)
        #expect(AgentHandoff.takeInterruption(defaults: store))
        #expect(!AgentHandoff.takeInterruption(defaults: store), "it must not persist")
    }

    /// A fresh profile has nothing to recover, so a first launch is never
    /// suspended.
    @Test func afreshProfileRecoversNothing() throws {
        #expect(!AgentHandoff.takeInterruption(defaults: try defaults()))
    }

    /// The whole sequence the install does: an agent attaches, the app is
    /// killed without ever reaching its terminate callback, and the next launch
    /// holds automation back from the moment it starts.
    @Test func akilledAppStillHandsOverOnTheNextLaunch() throws {
        let store = try defaults()
        AgentHandoff.noteAttached(defaults: store)
        // No clean detach, no terminate callback — the process simply ends.

        let launchedAt = Date()
        let recovered = AgentHandoff.takeInterruption(defaults: store)
        #expect(recovered)
        let interruptedAt = recovered ? launchedAt : nil
        #expect(AutomationSuspension.isSuspended(
            attachedSessions: 0, interruptedAt: interruptedAt,
            now: launchedAt.addingTimeInterval(39)),
            "39 seconds after launch is inside the window that nearly started a rip")
        #expect(!AutomationSuspension.isSuspended(
            attachedSessions: 0, interruptedAt: interruptedAt,
            now: launchedAt.addingTimeInterval(AutomationSuspension.handoffGrace + 1)))
    }
}
