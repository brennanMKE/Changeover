import Foundation
import Testing
@testable import Changeover

/// #0153 — why a disc came out, said out loud.
///
/// On 2026-09-26 two discs were ejected ten minutes apart because their films
/// were already in the Plex library. Both decisions were correct. Neither was
/// explained anywhere the user could see: the only record was one line in
/// `flow.log`, which is `FlowDiagnostics`, a debug file. The tray just opened.
///
/// The second disc was Knowing, and the silence cost real time — the user
/// concluded Changeover was broken, when the file genuinely was on the volume
/// under the right name and tag, and the actual fault was that Plex had matched
/// that file to a different film ("Groove") so Plex never listed Knowing. A
/// correct automatic action with no stated reason is indistinguishable from a
/// malfunction.
@Suite struct EjectExplanationTests {

    private static let knowing = EjectExplanation(
        cause: .alreadyInPlex,
        movie: "Knowing (2009)",
        existingFile: "Knowing (2009).mp4",
        existingSize: "601 MB")

    // MARK: - The sentence

    /// The headline names the film. "A disc was ejected" is not the thing the
    /// user is trying to find out.
    @Test func theHeadlineNamesTheFilmAndTheReason() {
        #expect(Self.knowing.headline == "Ejected — Knowing (2009) is already in Plex")
    }

    /// The detail names the *file*, so the claim is checkable rather than
    /// something the user has to take on faith. This is the part that would
    /// have sent them straight to the real problem.
    @Test func theDetailNamesTheFileItWasMatchedAgainst() {
        let detail = Self.knowing.detail
        #expect(detail.contains("Knowing (2009).mp4"))
        #expect(detail.contains("601 MB"))
        #expect(detail.contains("not ripped"))
    }

    /// And the advice covers the case where the app is wrong — including the
    /// exact divergence that actually happened, a file on disk that Plex does
    /// not list.
    @Test func theAdviceCoversBothOverridingItAndPlexBeingWrong() {
        let advice = Self.knowing.advice
        #expect(advice.contains("Replace the Existing File"))
        #expect(advice.lowercased().contains("plex does not list"))
    }

    /// Every field is optional, so a missing title must not produce "Ejected —
    /// nil is already in Plex" or an empty sentence.
    @Test func theSentencesSurviveWithNoDetailsAtAll() {
        let bare = EjectExplanation(cause: .alreadyInPlex)
        #expect(bare.headline == "Ejected — that film is already in Plex")
        #expect(!bare.headline.contains("nil"))
        #expect(!bare.detail.contains("nil"))
        #expect(!bare.detail.contains("as ,"))
        #expect(!bare.advice.isEmpty)
    }

    /// A size with no filename, and the reverse, both have to read.
    @Test func aPartialFileDescriptionStillReads() {
        let noSize = EjectExplanation(cause: .alreadyInPlex, movie: "X (2000)", existingFile: "X.mp4")
        #expect(noSize.detail.contains("X.mp4"))
        #expect(!noSize.detail.contains(" · "))
    }

    /// Every cause must produce a non-empty sentence, so a case added later
    /// cannot ship with blank UI.
    @Test func everyCauseSaysSomething() {
        for cause in EjectExplanation.Cause.allCases {
            let e = EjectExplanation(cause: cause, movie: "M (1931)")
            #expect(!e.headline.isEmpty)
            #expect(!e.detail.isEmpty)
            #expect(!e.advice.isEmpty)
            #expect(!e.logLine.isEmpty)
        }
    }

    // MARK: - The log line

    /// The visible log gets a line too. The whole defect was that nothing was
    /// written anywhere the user could look.
    @Test func theLogLineIsMarkedAndNamesTheFilm() {
        let line = Self.knowing.logLine
        #expect(line.hasPrefix("⏏ "))
        #expect(line.contains("Knowing (2009)"))
        #expect(!line.contains("—"), "the log is plain; the em dash belongs to the screen")
    }

    // MARK: - Sizes

    @Test func sizesFormatAsFileSizes() {
        #expect(EjectExplanation.formatSize(630_421_198)?.contains("MB") == true)
        #expect(EjectExplanation.formatSize(nil) == nil)
        #expect(EjectExplanation.formatSize(0) == nil)
        #expect(EjectExplanation.formatSize(-1) == nil)
    }

    // MARK: - It has to survive the wire

    /// `FlowStep` is `Codable` so a Phase 4 client derives the same screen.
    @Test func itRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Self.knowing)
        #expect(try JSONDecoder().decode(EjectExplanation.self, from: data) == Self.knowing)
    }
}

/// #0153 — the `.ejected` step, in the priority table.
@Suite struct EjectedStepTests {

    private static let explanation = EjectExplanation(cause: .alreadyInPlex, movie: "Knowing (2009)")

    private static func disc(_ name: String = "DISC") -> DiscInsertion {
        DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/\(name)"),
                      deviceNode: "disk4", discID: name)
    }

    /// The headline case: empty drive, and the app emptied it.
    @Test func anUnexplainedEjectionWithNoDiscShowsTheEjectedScreen() {
        let step = FlowStep.derive(.init(unexplainedEjection: Self.explanation))
        #expect(step == .ejected(Self.explanation))
    }

    /// An empty drive that was always empty is still the plain insert screen —
    /// this screen must not appear on launch.
    @Test func anOrdinaryEmptyDriveIsUnchanged() {
        #expect(FlowStep.derive(.init()) == .insertDisc(.noDisc))
    }

    /// The next disc supersedes it without a click, exactly as the outcome
    /// card does. Nobody should have to dismiss an explanation.
    @Test func insertingAnotherDiscLeavesTheScreen() {
        let step = FlowStep.derive(.init(
            insertedDisc: Self.disc(), unexplainedEjection: Self.explanation))
        #expect(step == .chooseMovie)
    }

    /// While the eject is still in flight the outcome is not yet a fact, so
    /// the transient rows still win. Otherwise the screen would claim the disc
    /// was out while the ladder was still arguing with `loginwindow` — which on
    /// this drive took six attempts over three minutes.
    @Test func anEjectInFlightStillOutranksTheExplanation() {
        let step = FlowStep.derive(.init(
            isEjecting: true, unexplainedEjection: Self.explanation))
        #expect(step == .insertDisc(.ejecting))
    }

    @Test func aDiscThatWillNotEjectStillOutranksTheExplanation() {
        let step = FlowStep.derive(.init(
            discUnavailable: true, unexplainedEjection: Self.explanation))
        #expect(step == .insertDisc(.discUnavailable))
    }

    /// A running job outranks everything, as row 1 says.
    @Test func aRunningJobStillWins() {
        let id = JobID.make()
        let step = FlowStep.derive(.init(
            currentJobID: id, unexplainedEjection: Self.explanation))
        #expect(step == .ripping(id))
    }

    /// A finished rip explains itself on the Done card, so this screen must
    /// never preempt it — "your rip finished" is not an unexplained eject.
    @Test func afinishedJobsOutcomeCardStillWins() {
        let id = JobID.make()
        let step = FlowStep.derive(.init(
            lastJob: .init(id: id), unexplainedEjection: Self.explanation))
        #expect(step == .done(id))
    }

    /// Every step needs a window title; a step added later must not forget one.
    @Test func theStepHasATitle() {
        #expect(FlowStep.ejected(Self.explanation).title == "Disc ejected")
    }

    /// It is a compact screen — a few short paragraphs, no list, no table.
    @Test func theStepIsCompact() {
        #expect(WindowSizing.heightClass(for: .ejected(Self.explanation)) == .compact)
    }

    /// And it survives the wire with its payload intact.
    @Test func theStepRoundTripsThroughJSON() throws {
        let step = FlowStep.ejected(Self.explanation)
        let data = try JSONEncoder().encode(step)
        #expect(try JSONDecoder().decode(FlowStep.self, from: data) == step)
    }
}
