import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0203 — the two session counts in a snapshot are different numbers, and
/// `status` has to report each in its own place.
///
/// This file exists because the first attempt at #0203 shipped half-working and
/// the peer session caught it on the installed build. `AgentSessionCount` was
/// right, the registry's count was right, the window's banner was right — and
/// `status` still said `heldBySessions: 2` for one agent, because
/// `BridgeStatusReader.snapshot` had a single `sessions: Int` parameter feeding
/// both `app.sessions` and `automationStatus(attachedSessions:)`.
///
/// Nothing failed. The #0203 tests covered the pure function and stopped there,
/// so the one wire that still carried the old number was the one wire nothing
/// looked at. `snapshot` had never been called from a test at all — it is
/// `@MainActor` and wants three controllers, which is exactly the kind of
/// friction that leaves a projection unverified while the seam beneath it is
/// covered twice over.
@MainActor
struct SnapshotSessionCountTests {

    private func snapshot(sessions: Int, agents: Int) -> BridgeStatus {
        BridgeStatusReader.snapshot(
            jobs: JobController(runner: { _, _ in .failed(JobFailure(stage: .encode, reason: .toolExited(code: 1))) }),
            flow: RipFlowController(),
            settings: AppSettings(),
            launchDate: Date(),
            clients: 1,
            sessions: sessions,
            agents: agents,
            brokerRegistered: true
        )
    }

    /// The reported bug, as the two numbers it confused.
    @Test func oneAgentHoldingTwoSessionsReportsOneAgent() {
        let status = snapshot(sessions: 2, agents: 1)
        #expect(status.automation.heldBySessions == 1, "this said 2 on build 20261004083334")
        #expect(status.app.sessions == 2, "the literal count is still reported, deliberately")
    }

    /// And the reason text is built from the same number, so it cannot say
    /// "2 sessions" while the field says 1. That sentence is what the peer
    /// actually quoted back, which makes it part of the contract.
    @Test func theReasonTextAgreesWithTheCount() throws {
        let automation = snapshot(sessions: 2, agents: 1).automation
        let reason = try #require(automation.reason)
        #expect(!reason.contains("2 "), "reason disagreed with heldBySessions: \(reason)")
        #expect(automation.suspended)
    }

    /// Nothing attached suspends nothing — the case that releases the #0199
    /// eject hold, so it is worth pinning rather than assuming.
    @Test func noSessionsSuspendsNothing() {
        let status = snapshot(sessions: 0, agents: 0)
        #expect(status.automation.heldBySessions == 0)
        #expect(!status.automation.suspended)
        #expect(status.app.sessions == 0)
    }

    /// Two genuine agents still read as two.
    @Test func twoAgentsAreReportedAsTwo() {
        let status = snapshot(sessions: 3, agents: 2)
        #expect(status.automation.heldBySessions == 2)
        #expect(status.app.sessions == 3)
    }

    /// The property that failed: the agent-facing count never comes from the
    /// open-session count. Swept across the pairs the app can actually produce
    /// — `agents` is never above `sessions`, since every agent holds at least
    /// one session.
    @Test func theAgentCountIsNeverTheSessionCount() {
        for sessions in 0...4 {
            for agents in 0...sessions {
                let status = snapshot(sessions: sessions, agents: agents)
                #expect(status.automation.heldBySessions == agents)
                #expect(status.app.sessions == sessions)
            }
        }
    }
}
