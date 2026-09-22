import Foundation
import Testing
@testable import Changeover

/// #0061 — what the Ripping and Done steps show
/// (`docs/ux-step-flow.md` §3.3). Pure, driven off `JobSnapshot` with no view
/// and no job: since UI tests are forbidden here, this is the coverage for
/// two of the five screens.
struct JobPresentationStepsTests {

    // MARK: - Fixtures

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 275, "title": "Fargo", "release_date": "1996-04-05", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static func progress(
        _ fraction: Double,
        unit: JobProgress.Unit = .feature,
        stage: HandBrakeProgress.Stage = .encoding,
        eta: Int? = 2729,
        averageFPS: Double? = 56.07
    ) -> JobProgress {
        JobProgress(
            unit: unit,
            encode: HandBrakeProgress(
                stage: stage, fraction: fraction, task: 1, taskCount: 1,
                fps: 66.32, averageFPS: averageFPS, etaSeconds: eta
            ),
            receivedAt: start
        )
    }

    /// A snapshot at a non-terminal phase, reached the way production reaches
    /// one — `JobState.advancing(to:)` — so no fixture here is a hand-forged
    /// invariant violation.
    private static func running(phase: JobPhase, progress: JobProgress? = nil) throws -> JobSnapshot {
        var state = JobState.initial
        for step in try path(to: phase) {
            state = try #require(state.advancing(to: step))
        }
        return JobSnapshot(
            id: JobID.make(), metadata: try metadata(), state: state,
            outcome: nil, startDate: start, endDate: nil, progress: progress
        )
    }

    private static func path(to phase: JobPhase) throws -> [JobPhase] {
        switch phase {
        case .starting:   return []
        case .encoding:   return [.encoding]
        case .fallback:   return [.encoding, .fallback]
        case .organizing: return [.encoding, .organizing]
        case .extras:     return [.encoding, .organizing, .extras]
        default:
            Issue.record("no non-terminal path to \(phase)")
            return []
        }
    }

    private static func finished(_ outcome: JobOutcome, from phase: JobPhase, elapsed: TimeInterval = 2_472) throws -> JobSnapshot {
        var state = JobState.initial
        for step in try path(to: phase) {
            state = try #require(state.advancing(to: step))
        }
        state = try #require(state.finishing(with: outcome))
        return JobSnapshot(
            id: JobID.make(), metadata: try metadata(), state: state,
            outcome: outcome, startDate: start, endDate: start.addingTimeInterval(elapsed), progress: nil
        )
    }

    private static let destination = URL(fileURLWithPath: "/Volumes/Plex/Movies/Fargo (1996) {tmdb-275}/Fargo (1996).mp4")

    // MARK: - formatETA

    @Test func etaIsRoundedToMinutes() {
        #expect(JobPresentation.formatETA(seconds: 2729) == "ETA 45 min")
        #expect(JobPresentation.formatETA(seconds: 3900) == "ETA 1h 05m")
        #expect(JobPresentation.formatETA(seconds: 30) == "ETA under a minute")
        #expect(JobPresentation.formatETA(seconds: 0) == "ETA under a minute")
        #expect(JobPresentation.formatETA(seconds: 90) == "ETA 2 min")
    }

    // MARK: - progressSummary

    @Test func theFeatureEncodeShowsPercentETARateAndElapsed() throws {
        let snapshot = try Self.running(phase: .encoding, progress: Self.progress(0.3123))
        let summary = JobPresentation.progressSummary(for: snapshot, now: Self.start.addingTimeInterval(728))

        #expect(summary.unitLabel == "Encoding the feature")
        #expect(summary.percentText == "31 %")
        #expect(summary.etaText == "ETA 45 min")
        #expect(summary.rateText == "56 fps")
        #expect(summary.elapsedText == "12m 08s")
        #expect(summary.isDeterminate == true)
    }

    /// Before the first percentage arrives there is nothing honest to show
    /// but a spinner.
    @Test func anEncodeWithNoProgressYetIsIndeterminate() throws {
        let summary = JobPresentation.progressSummary(for: try Self.running(phase: .encoding), now: Self.start)
        #expect(summary.isDeterminate == false)
        #expect(summary.percentText == nil)
        #expect(summary.etaText == nil)
        #expect(summary.rateText == nil)
    }

    /// HandBrake scans the disc itself before encoding. Calling that
    /// "Encoding" would be a claim the bar can't back up.
    @Test func handBrakesOwnPreEncodeScanSaysSo() throws {
        let snapshot = try Self.running(phase: .encoding, progress: Self.progress(0.3, stage: .scanning, eta: nil, averageFPS: nil))
        let summary = JobPresentation.progressSummary(for: snapshot, now: Self.start)
        #expect(summary.unitLabel == "Reading the disc")
        #expect(summary.isDeterminate == false)
    }

    @Test func extrasNameWhichExtraIsEncoding() throws {
        let snapshot = try Self.running(
            phase: .extras,
            progress: Self.progress(0.5, unit: .extra(index: 2, count: 3, titleIndex: 7))
        )
        let summary = JobPresentation.progressSummary(for: snapshot, now: Self.start)
        #expect(summary.unitLabel == "Encoding extra 2 of 3 — title 7")
        #expect(summary.percentText == "50 %")
    }

    @Test func theFallbackAndTheMoveNameThemselves() throws {
        let fallback = try Self.running(phase: .fallback)
        #expect(JobPresentation.progressSummary(for: fallback, now: Self.start).unitLabel == "Retrying with MakeMKV")

        let organizing = try Self.running(phase: .organizing)
        let summary = JobPresentation.progressSummary(for: organizing, now: Self.start)
        #expect(summary.unitLabel == "Moving into Plex")
        #expect(summary.isDeterminate == false)
    }

    /// #0046 — the SIGKILL-escalation gap, which can be 10 s or more.
    @Test func aCancelInFlightSaysCancelling() throws {
        let snapshot = try Self.running(phase: .encoding, progress: Self.progress(0.5))
        let summary = JobPresentation.progressSummary(for: snapshot, now: Self.start, isCancelling: true)
        #expect(summary.unitLabel == "Cancelling…")
        #expect(summary.isDeterminate == false)
    }

    // MARK: - outcomeCard

    @Test func aSucceededJobSaysWhereTheFileLanded() throws {
        let snapshot = try Self.finished(.succeeded(destination: Self.destination), from: .organizing)
        let card = JobPresentation.outcomeCard(
            for: snapshot, retryDecision: .refuse(reason: "only a failed or cancelled job can be retried"), discEjected: true
        )
        #expect(card.headline == "Fargo (1996)")
        #expect(card.tone == .success)
        #expect(card.lines.first == "Filed as \(Self.destination.path)")
        #expect(card.lines.contains("Finished in 41m 12s · disc ejected"))
        #expect(card.actions == [.showLog, .revealInFinder(Self.destination), .nextDisc])
    }

    /// #0049 — the disc unmounted but stayed in the drive: the success card
    /// still stands, with Eject offered again.
    @Test func aPartialEjectAddsAnEjectAction() throws {
        let snapshot = try Self.finished(.succeeded(destination: Self.destination), from: .organizing)
        let card = JobPresentation.outcomeCard(
            for: snapshot, retryDecision: .refuse(reason: "nope"), discEjected: false, discUnavailable: true
        )
        #expect(card.tone == .success)
        #expect(card.actions.contains(.eject))
        #expect(card.lines.contains { $0.contains("could not be ejected") })
    }

    @Test func aFailedJobShowsTheFailurePresentersReason() throws {
        let failure = JobFailure(stage: .encode, reason: .toolExited(code: 3), logTail: ["boom"])
        let snapshot = try Self.finished(.failed(failure), from: .encoding)
        let card = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: false)

        #expect(card.headline == "Fargo (1996) — Failed")
        #expect(card.tone == .failure)
        #expect(card.lines.first == FailurePresenter.message(for: failure).headline)
        // Eject is offered because the disc is still in the drive. A failed
        // job deliberately keeps it there for a retry, but the user must
        // still have a way to take it out without hunting through the menu
        // bar — the tray opening is what says "ready for the next one".
        #expect(card.actions == [.showLog, .adjustAndRetry, .retry, .eject, .nextDisc])
    }

    /// Retry is offered only when `JobController.retryDecision` allows it —
    /// a different disc in the drive, or no scan, means no button.
    @Test func aRefusedRetryOffersNeitherRetryButton() throws {
        let failure = JobFailure(stage: .encode, reason: .toolExited(code: 3))
        let snapshot = try Self.finished(.failed(failure), from: .encoding)
        let card = JobPresentation.outcomeCard(
            for: snapshot,
            retryDecision: .refuse(reason: "a different disc is in the drive — insert this job's disc"),
            discEjected: false
        )
        #expect(card.actions == [.showLog, .eject, .nextDisc])
    }

    @Test func aCancelledJobIsNotAFailure() throws {
        let failure = JobFailure(stage: .encode, reason: .cancelled)
        let snapshot = try Self.finished(.failed(failure), from: .encoding)
        let card = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: false)
        #expect(card.headline == "Fargo (1996) — Cancelled")
        #expect(card.tone == .neutral)
        #expect(card.actions == [.showLog, .adjustAndRetry, .retry, .eject, .nextDisc])
    }

    /// #0052 — a disc pulled mid-job ends `.cancelled`, and the card says so
    /// in the user's terms with nothing to retry against an empty drive.
    @Test func aDiscPulledMidJobSaysDiscRemovedAndOffersOnlyNextDisc() throws {
        let failure = JobFailure(stage: .encode, reason: .cancelled)
        let snapshot = try Self.finished(.failed(failure), from: .encoding)
        let card = JobPresentation.outcomeCard(
            for: snapshot, discRemovedDuringJob: true,
            retryDecision: .refuse(reason: "no disc is in the drive — insert this job's disc"),
            discEjected: true
        )
        #expect(card.headline == "Disc removed")
        #expect(card.lines.first == JobPresentation.discRemovedDetail)
        #expect(card.actions == [.showLog, .nextDisc])
    }

    /// The primary action is last, in every card — that is the contract the
    /// Done step's action bar lays out against.
    @Test func theLastActionIsAlwaysTheWayForward() throws {
        let succeeded = try Self.finished(.succeeded(destination: Self.destination), from: .organizing)
        let failed = try Self.finished(.failed(JobFailure(stage: .encode, reason: .diskFull)), from: .encoding)
        for card in [
            JobPresentation.outcomeCard(for: succeeded, retryDecision: .refuse(reason: "x"), discEjected: true),
            JobPresentation.outcomeCard(for: failed, retryDecision: .retry, discEjected: false),
            JobPresentation.outcomeCard(for: failed, retryDecision: .retry, discEjected: false, discUnavailable: true),
        ] {
            #expect(card.actions.last == .nextDisc)
        }
    }
    // MARK: - The plain register (docs/plain-language-ui.md §3.9, §3.10)

    @Test func plainETADropsTheAbbreviationAndRoundsToMinutes() {
        #expect(JobPresentation.plainETA(seconds: 2_729) == "About 45 minutes left")
        #expect(JobPresentation.plainETA(seconds: 30) == "Almost done")
        #expect(JobPresentation.plainETA(seconds: 59) == "Almost done")
        #expect(JobPresentation.plainETA(seconds: 60) == "About 1 minute left")
        #expect(JobPresentation.plainETA(seconds: 3_900) == "About 1 h 5 min left")
        // The verbatim form is untouched.
        #expect(JobPresentation.formatETA(seconds: 2_729) == "ETA 45 min")
    }

    @Test func plainElapsedIsWholeMinutes() {
        #expect(JobPresentation.plainElapsed(2_472) == "41 minutes")
        #expect(JobPresentation.plainElapsed(30) == "under a minute")
        #expect(JobPresentation.formatElapsed(2_472) == "41m 12s")
    }

    /// One plain unit label per phase, and never the word "encode".
    @Test func everyUnitLabelHasItsOwnPlainForm() throws {
        let feature = JobPresentation.progressSummary(for: try Self.running(phase: .encoding, progress: Self.progress(0.31)), now: Self.start)
        #expect(feature.unitLabel == "Encoding the feature")
        #expect(feature.plainUnitLabel == "Ripping the movie")
        #expect(feature.plainETAText == "About 45 minutes left")

        let scanning = JobPresentation.progressSummary(
            for: try Self.running(phase: .encoding, progress: Self.progress(0.1, stage: .scanning)),
            now: Self.start
        )
        #expect(scanning.plainUnitLabel == "Reading the disc")

        let remux = JobPresentation.progressSummary(
            for: try Self.running(phase: .encoding, progress: Self.progress(0.5, unit: .remux)),
            now: Self.start
        )
        #expect(remux.unitLabel.hasPrefix("Rewriting metadata in"))
        #expect(remux.plainUnitLabel == "Updating the copy in Plex")

        let extra = JobPresentation.progressSummary(
            for: try Self.running(phase: .extras, progress: Self.progress(0.2, unit: .extra(index: 2, count: 3, titleIndex: 7))),
            now: Self.start
        )
        #expect(extra.unitLabel == "Encoding extra 2 of 3 — title 7")
        // The disc's own title number is the one part that means nothing.
        #expect(extra.plainUnitLabel == "Ripping extra 2 of 3")

        let fallback = JobPresentation.progressSummary(for: try Self.running(phase: .fallback), now: Self.start)
        #expect(fallback.plainUnitLabel == "Trying another way to read the disc")

        let organizing = JobPresentation.progressSummary(for: try Self.running(phase: .organizing), now: Self.start)
        #expect(organizing.plainUnitLabel == "Moving into Plex")

        let cancelling = JobPresentation.progressSummary(for: try Self.running(phase: .encoding), now: Self.start, isCancelling: true)
        #expect(cancelling.plainUnitLabel == "Cancelling…")
    }

    /// A blank line beside a moving bar reads as a stall, so an unknown ETA
    /// is itself worth one sentence — unlike `etaText`, which stays `nil`.
    @Test func anUnknownETAStillSaysSomethingPlain() throws {
        let summary = JobPresentation.progressSummary(for: try Self.running(phase: .encoding), now: Self.start)
        #expect(summary.etaText == nil)
        #expect(summary.plainETAText == "Working out how long this will take…")
    }

    @Test func aSucceededCardSaysItLandedWithoutNamingThePath() throws {
        let snapshot = try Self.finished(.succeeded(destination: Self.destination), from: .organizing)
        let card = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: true)
        #expect(card.plainHeadline == "Fargo (1996)")
        #expect(card.plainLines == ["Added to Plex.", "Took 41 minutes. The disc has been ejected."])
        // The path is still there, verbatim, under Details.
        #expect(card.lines[0] == "Filed as \(Self.destination.path)")
    }

    @Test func thePlainDiscSentenceSaysWhereTheDiscIs() throws {
        let snapshot = try Self.finished(.succeeded(destination: Self.destination), from: .organizing)
        let stillIn = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: false)
        #expect(stillIn.plainLines.last == "Took 41 minutes. The disc is still in the drive.")

        let stuck = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: false, discUnavailable: true)
        #expect(stuck.plainLines.contains("Took 41 minutes. The disc couldn't be ejected."))
        #expect(stuck.plainLines.last == "The disc is stuck in the drive. Try Eject again, or take it out by hand.")
    }

    @Test func aFailedCardLeadsWithThePlainHeadlineAndKeepsTheDetails() throws {
        let failure = JobFailure(stage: .encode, reason: .discUnreadable)
        let snapshot = try Self.finished(.failed(failure), from: .encoding, elapsed: 700)
        let card = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: false)

        #expect(card.plainLines[0] == "This disc couldn't be read. Clean it and try again.")
        #expect(card.plainLines.last == "Took 11 minutes. The disc is still in the drive.")
        // Every `FailurePresenter` detail line is still on the card, verbatim.
        #expect(card.lines.contains("Clean the disc and try again."))
    }

    @Test func aCancelledCardSaysStoppedRatherThanFinished() throws {
        let snapshot = try Self.finished(.failed(JobFailure(stage: .encode, reason: .cancelled)), from: .encoding, elapsed: 700)
        let card = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: false)
        #expect(card.plainHeadline == "Fargo (1996) — Cancelled")
        #expect(card.plainLines == ["Stopped after 11 minutes. The disc is still in the drive."])
    }

    @Test func aDiscPulledMidJobSaysSoInOneSentence() throws {
        let snapshot = try Self.finished(.failed(JobFailure(stage: .encode, reason: .cancelled)), from: .encoding)
        let card = JobPresentation.outcomeCard(
            for: snapshot, discRemovedDuringJob: true, retryDecision: .refuse(reason: "x"), discEjected: false
        )
        #expect(card.plainHeadline == "Disc removed")
        #expect(card.plainLines == ["The disc was taken out before ripping finished. Nothing was added to Plex."])
        #expect(card.lines.first == JobPresentation.discRemovedDetail)
    }

    /// "Upgrade" is this project's word for a remux and not anyone else's.
    @Test func anUpgradedCardSaysUpdatedInThePlainRegister() throws {
        let snapshot = try Self.finished(.succeeded(destination: Self.destination), from: .organizing)
        let plan = UpgradePlan(
            filePath: "/Plex/Movies/Fargo (1996) {tmdb-275}/Fargo (1996).mp4",
            chapters: (1...20).map { MarkerRow(number: $0, name: "Name \($0)") },
            audio: [AudioTag(track: 0, language: "eng", title: nil)]
        )
        let card = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: true, upgrade: plan)
        #expect(card.headline == "Fargo (1996) — Upgraded")
        #expect(card.plainHeadline == "Fargo (1996) — Updated")
        #expect(card.plainLines[0] == "Added 20 chapter names and 1 audio language to the copy in Plex. Nothing was re-encoded.")
        #expect(card.lines[0] == "Upgraded: 20 chapter names, 1 audio language. Video and audio untouched.")
    }

    /// Every plain sentence the Done card can produce survives the sweep.
    @Test func noOutcomeCardsPlainSentenceNamesATool() throws {
        let cards = [
            JobPresentation.outcomeCard(
                for: try Self.finished(.succeeded(destination: Self.destination), from: .organizing),
                retryDecision: .retry, discEjected: true
            ),
            JobPresentation.outcomeCard(
                for: try Self.finished(.failed(JobFailure(stage: .encode, reason: .toolExited(code: 3))), from: .encoding),
                retryDecision: .retry, discEjected: false
            ),
            JobPresentation.outcomeCard(
                for: try Self.finished(.failed(JobFailure(stage: .encode, reason: .cancelled)), from: .encoding),
                retryDecision: .retry, discEjected: false
            ),
        ]
        for card in cards {
            #expect(PlainLanguage.violations(in: card.plainHeadline).isEmpty, "\(card.plainHeadline)")
            for line in card.plainLines {
                #expect(PlainLanguage.violations(in: line).isEmpty, "\(line)")
            }
        }
    }

}
