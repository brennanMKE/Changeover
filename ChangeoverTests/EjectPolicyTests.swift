import Testing
@testable import Changeover

/// Covers #0045's manual "Eject Disc" decision — pure, no `JobController`, no
/// `DiscEjector`, no drive.
struct EjectPolicyTests {

    // MARK: - decide(isRunning:hasDisc:) — full truth table

    @Test func noDiscAndIdleRefusesForNoDisc() {
        let decision = EjectPolicy.decide(isRunning: false, hasDisc: false)
        #expect(decision == .refuse(reason: "No disc is mounted."))
    }

    @Test func discMountedAndIdleEjects() {
        let decision = EjectPolicy.decide(isRunning: false, hasDisc: true)
        #expect(decision == .eject)
    }

    @Test func noDiscButRunningStillRefusesForNoDisc() {
        // "No disc" wins even if `isRunning` is somehow true — a job can't
        // really be running with no disc mounted, but the truth table must
        // still resolve, and the no-disc reason is the more specific one.
        let decision = EjectPolicy.decide(isRunning: true, hasDisc: false)
        #expect(decision == .refuse(reason: "No disc is mounted."))
    }

    @Test func discMountedAndRunningRefusesForTheRunningJob() {
        let decision = EjectPolicy.decide(isRunning: true, hasDisc: true)
        #expect(decision == .refuse(reason: "A job is running — wait for it to finish before ejecting."))
    }

    // MARK: - canEjectManually(isRunning:hasDisc:) — full truth table

    @Test func canEjectManuallyTruthTable() {
        #expect(EjectPolicy.canEjectManually(isRunning: false, hasDisc: false) == false)
        #expect(EjectPolicy.canEjectManually(isRunning: false, hasDisc: true) == true)
        #expect(EjectPolicy.canEjectManually(isRunning: true, hasDisc: false) == false)
        #expect(EjectPolicy.canEjectManually(isRunning: true, hasDisc: true) == false)
    }
}
