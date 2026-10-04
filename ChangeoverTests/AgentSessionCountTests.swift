import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0203 — one agent running a watcher and a wait is one agent.
///
/// The user, watching the window while a single agent worked a bonus disc: "I
/// still see 2 agents." There was one. It held `changeoverctl watch` for the
/// event stream and `changeoverctl wait --for job-done` to block on the encode,
/// and `wait` opened a session of its own — so the banner counted the agent
/// twice and `status` said `heldBySessions: 2`.
struct AgentSessionCountTests {

    /// The bug, as the numbers that produced it.
    @Test func aWatcherAndAWaitAreOneAgent() {
        #expect(AgentSessionCount.agents(watching: 1, waiting: 1) == 1)
        #expect(AgentSessionCount.agents(watching: 1, waiting: 3) == 1)
    }

    /// And `wait` on its own still counts, which is what keeps it usable
    /// alone: the app must not start a job underneath something waiting for a
    /// different one, so a lone `wait` still suspends automation and still
    /// passes `AgentAuthorization`.
    @Test func waitingAloneStillCounts() {
        #expect(AgentSessionCount.agents(watching: 0, waiting: 1) == 1)
        #expect(AgentSessionCount.agents(watching: 0, waiting: 2) == 2)
    }

    @Test func watchersAreCountedAsThemselves() {
        #expect(AgentSessionCount.agents(watching: 1, waiting: 0) == 1)
        #expect(AgentSessionCount.agents(watching: 2, waiting: 0) == 2)
        #expect(AgentSessionCount.agents(watching: 2, waiting: 1) == 2)
    }

    @Test func nothingAttachedIsZero() {
        #expect(AgentSessionCount.agents(watching: 0, waiting: 0) == 0)
    }

    /// A waiting session can never **raise** the count above the watchers —
    /// that is the whole property, stated independently of the table.
    @Test func waitingNeverAddsToTheWatcherCount() {
        for watching in 1...4 {
            for waiting in 0...4 {
                #expect(AgentSessionCount.agents(watching: watching, waiting: waiting) == watching)
            }
        }
    }

    /// And the count is never zero while anything is attached, because zero is
    /// what releases automation and ejects discs (#0199).
    @Test func anythingAttachedIsNeverZero() {
        for watching in 0...3 {
            for waiting in 0...3 where watching + waiting > 0 {
                #expect(AgentSessionCount.agents(watching: watching, waiting: waiting) > 0)
            }
        }
    }

    // MARK: - The purpose, on the wire

    /// The action names are the contract between the CLI and the app, so they
    /// are asserted against the bridge's own constants rather than retyped.
    @Test func thePurposesMatchTheWireActions() {
        #expect(AgentSessionCount.Purpose.watching.action == BridgeRequest.Action.watch)
        #expect(AgentSessionCount.Purpose.waiting.action == BridgeRequest.Action.waitSession)
    }

    @Test func aKnownActionResolvesToItsPurpose() {
        #expect(AgentSessionCount.Purpose(action: BridgeRequest.Action.watch) == .watching)
        #expect(AgentSessionCount.Purpose(action: BridgeRequest.Action.waitSession) == .waiting)
    }

    /// An action that does not open a session is refused rather than defaulted.
    /// `startSession` returns an empty id on `nil`, which is the refusal the
    /// CLI reports — so a typo must not quietly open a watch session.
    @Test func anActionThatOpensNoSessionIsRefused() {
        for action in [BridgeRequest.Action.status, BridgeRequest.Action.eject, "nonsense", ""] {
            #expect(AgentSessionCount.Purpose(action: action) == nil, "'\(action)' should open no session")
        }
    }

    /// Every purpose round-trips through its action name, so a third one added
    /// later cannot resolve to the wrong case.
    @Test func everyPurposeRoundTrips() {
        for purpose in AgentSessionCount.Purpose.allCases {
            #expect(AgentSessionCount.Purpose(action: purpose.action) == purpose)
        }
    }
}
