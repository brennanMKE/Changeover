import Foundation
import Testing
@testable import Changeover

/// #0165 — the five-phase indicator's own coverage.
///
/// `DiscPhaseTests` pins `DiscPhase.derive` against the app's state. This pins
/// the view's half: the mapping from the screen actually on the window to the
/// phase drawn above it. A phase that could disagree with the screen under it
/// would be worse than no phase at all, so the mapping is a pure function and
/// every `FlowStep` is asserted.
///
/// Pure seams only. No view is tested and no UI test is written or run
/// (`docs/ui-test-crash-prevention.md`).
@Suite struct DiscPhaseIndicatorTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
        deviceNode: "disk4", discID: "disc-ub")

    private static func plan(secondWaiting: Bool) -> DiscRipPlan {
        var plan = DiscRipPlan.make(disc: disc, films: [
            (feature: 1, metadata: MovieMetadata(title: "The Great Outdoors", year: "1988", tmdbID: "2617")),
            (feature: 2, metadata: MovieMetadata(title: "Uncle Buck", year: "1989", tmdbID: "2616")),
        ])!
        let first = JobID.make()
        plan.markRunning(1, jobID: first)
        plan.settle(jobID: first, succeeded: true)
        if !secondWaiting {
            let second = JobID.make()
            plan.markRunning(2, jobID: second)
            plan.settle(jobID: second, succeeded: true)
        }
        return plan
    }

    // MARK: - The mapping

    /// The Choose step is on screen from the moment a disc mounts, long
    /// before anything is known about what is on it — so the screen alone
    /// cannot tell phase 1 from phase 2, and the scan is what does.
    @Test func chooseIsStillReadingUntilTheScanFinishes() {
        #expect(DiscPhaseIndicator.phase(step: .chooseMovie, scanned: false) == .discovering)
        #expect(DiscPhaseIndicator.phase(step: .chooseMovie, scanned: true) == .selecting)
    }

    @Test func everyOtherStepMapsToOnePhase() {
        #expect(DiscPhaseIndicator.phase(step: .insertDisc(.noDisc), scanned: false) == .discovering)
        #expect(DiscPhaseIndicator.phase(step: .confirm, scanned: true) == .selecting)
        #expect(DiscPhaseIndicator.phase(step: .ripping(JobID.make()), scanned: true) == .importing)
        #expect(DiscPhaseIndicator.phase(step: .ejected(EjectExplanation(cause: .alreadyInPlex)),
                                         scanned: true) == .ejecting)
    }

    /// A one-film disc reaching Done is the report, exactly as it always was.
    @Test func doneIsTheReport() {
        #expect(DiscPhaseIndicator.phase(step: .done(JobID.make()), scanned: true) == .reporting)
        #expect(DiscPhaseIndicator.phase(step: .done(JobID.make()), scanned: true,
                                         plan: Self.plan(secondWaiting: false)) == .reporting)
    }

    /// The whole point of the indicator on a two-film disc: the Done step
    /// between two encodes is not the end of the disc, it is the middle of
    /// phase 3.
    @Test func doneWithFilmsLeftIsStillImporting() {
        #expect(DiscPhaseIndicator.phase(step: .done(JobID.make()), scanned: true,
                                         plan: Self.plan(secondWaiting: true)) == .importing)
    }

    // MARK: - The row

    @Test func theRowIsAlwaysFivePhasesInOrder() {
        let steps = DiscPhaseIndicator.steps(current: .importing)
        #expect(steps.map(\.phase) == [.discovering, .selecting, .importing, .reporting, .ejecting])
        #expect(steps.count == DiscPhase.count)
    }

    @Test func everythingBeforeTheCurrentPhaseIsDoneAndEverythingAfterIsNot() {
        let marks = DiscPhaseIndicator.steps(current: .importing).map(\.mark)
        #expect(marks == [.done, .done, .current, .upcoming, .upcoming])
        #expect(DiscPhaseIndicator.steps(current: .discovering).map(\.mark)
            == [.current, .upcoming, .upcoming, .upcoming, .upcoming])
        #expect(DiscPhaseIndicator.steps(current: .ejecting).map(\.mark)
            == [.done, .done, .done, .done, .current])
    }

    /// Exactly one phase is ever current, whichever it is.
    @Test func exactlyOnePhaseIsCurrent() {
        for phase in DiscPhase.allCases {
            let current = DiscPhaseIndicator.steps(current: phase).filter { $0.mark == .current }
            #expect(current.map(\.phase) == [phase])
        }
    }

    // MARK: - What it says

    @Test func theCaptionNumbersThePhaseInTheDetailRegister() {
        let caption = DiscPhaseIndicator.caption(.importing)
        #expect(caption.plain == "Copying the movies into Plex.")
        #expect(caption.detail == "Step 3 of 5 — Importing")
    }

    /// `docs/plain-language-ui.md` §1.2 — the labels and the plain captions
    /// are the default view, so no tool names and no disc vocabulary.
    @Test func everyPhaseLabelAndCaptionIsPlain() {
        for phase in DiscPhase.allCases {
            #expect(PlainLanguage.violations(in: phase.title).isEmpty, "\(phase.title)")
            #expect(PlainLanguage.violations(in: DiscPhaseIndicator.caption(phase).plain).isEmpty,
                    "\(phase.plainDescription)")
            // Rule 6: five of these sit in one row at the 560-point minimum.
            #expect(phase.title.count <= 20, "\(phase.title) is \(phase.title.count) characters")
        }
    }
}
