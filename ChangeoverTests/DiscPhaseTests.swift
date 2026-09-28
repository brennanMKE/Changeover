import Foundation
import Testing
@testable import Changeover

/// #0165 — the five phases of a disc's visit, derived from what the app is
/// actually doing.
///
/// `FlowStep` answers "which screen", and `.ripping(JobID)`/`.done(JobID)`
/// name a *job* — a disc holding two films has two of those inside one visit,
/// so neither can say where the disc itself has got to.
@Suite struct DiscPhaseTests {

    /// A disc just inserted: evidence is still being gathered.
    @Test func aFreshDiscIsDiscovering() {
        #expect(DiscPhase.derive(.init(hasDisc: true)) == .discovering)
    }

    /// The scan finishing is what moves it on, whether or not a film is named
    /// yet — both are "choosing".
    @Test func afinishedScanIsSelecting() {
        #expect(DiscPhase.derive(.init(hasDisc: true, discoveryFinished: true)) == .selecting)
        #expect(DiscPhase.derive(.init(hasDisc: true, discoveryFinished: true,
                                       anyFilmNamed: true)) == .selecting)
    }

    /// A film named before the scan is declared finished still counts — on a
    /// disc the app cannot identify, the user may type a title first.
    @Test func afilmNamedEarlyIsAlreadySelecting() {
        #expect(DiscPhase.derive(.init(hasDisc: true, anyFilmNamed: true)) == .selecting)
    }

    @Test func astartedPlanIsImporting() {
        #expect(DiscPhase.derive(.init(hasDisc: true, discoveryFinished: true,
                                       anyFilmNamed: true, planStarted: true)) == .importing)
    }

    /// The headline for the John Candy disc: once BOTH films have settled the
    /// phase is the report, and the disc is still in the drive while it is
    /// read.
    @Test func afinishedPlanIsTheReportBeforeTheDiscComesOut() {
        let phase = DiscPhase.derive(.init(
            hasDisc: true, discoveryFinished: true, anyFilmNamed: true,
            planStarted: true, planFinished: true))
        #expect(phase == .reporting)
    }

    /// A finished plan is not the report until it was actually started —
    /// `isFinished` is false on an empty plan, but a disc with no plan at all
    /// must not jump to a report.
    @Test func anUnstartedDiscIsNeverReporting() {
        #expect(DiscPhase.derive(.init(hasDisc: true, discoveryFinished: true,
                                       planFinished: true)) == .selecting)
    }

    @Test func ejectingWinsOverEverything() {
        #expect(DiscPhase.derive(.init(
            hasDisc: true, discoveryFinished: true, anyFilmNamed: true,
            planStarted: true, planFinished: true, ejecting: true)) == .ejecting)
    }

    // MARK: - The indicator

    /// Exactly five, numbered 1...5, so "Step 3 of 5" is always true.
    @Test func thereAreFivePhasesNumberedInOrder() {
        #expect(DiscPhase.count == 5)
        #expect(DiscPhase.allCases.map(\.number) == [1, 2, 3, 4, 5])
        #expect(DiscPhase.importing.number == 3)
    }

    /// Every phase has a short label and a plain sentence — a row of five on a
    /// 620-point window has no room for prose, and the plain register is
    /// required everywhere (`PlainLanguageTests`).
    @Test func everyPhaseNamesItselfTwice() {
        for phase in DiscPhase.allCases {
            #expect(!phase.title.isEmpty)
            #expect(phase.title.count <= 18, "\(phase) label too long for the indicator")
            #expect(phase.plainDescription.hasSuffix("."))
        }
    }

    /// It survives the wire, like `FlowStep`, so a Phase 4 client can draw the
    /// same indicator from the same inputs.
    @Test func itRoundTripsThroughJSON() throws {
        for phase in DiscPhase.allCases {
            let data = try JSONEncoder().encode(phase)
            #expect(try JSONDecoder().decode(DiscPhase.self, from: data) == phase)
        }
    }

    /// The phases only move forward within one visit.
    @Test func theOrderIsMonotonic() {
        var inputs = DiscPhase.Inputs(hasDisc: true)
        var seen: [Int] = [DiscPhase.derive(inputs).number]
        inputs.discoveryFinished = true; seen.append(DiscPhase.derive(inputs).number)
        inputs.anyFilmNamed = true;      seen.append(DiscPhase.derive(inputs).number)
        inputs.planStarted = true;       seen.append(DiscPhase.derive(inputs).number)
        inputs.planFinished = true;      seen.append(DiscPhase.derive(inputs).number)
        inputs.ejecting = true;          seen.append(DiscPhase.derive(inputs).number)
        #expect(seen == seen.sorted(), "a disc's phase must never run backwards: \(seen)")
    }
}
