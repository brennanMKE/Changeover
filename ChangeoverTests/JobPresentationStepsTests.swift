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
        #expect(card.actions == [.showLog, .adjustAndRetry, .retry, .nextDisc])
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
        #expect(card.actions == [.showLog, .nextDisc])
    }

    @Test func aCancelledJobIsNotAFailure() throws {
        let failure = JobFailure(stage: .encode, reason: .cancelled)
        let snapshot = try Self.finished(.failed(failure), from: .encoding)
        let card = JobPresentation.outcomeCard(for: snapshot, retryDecision: .retry, discEjected: false)
        #expect(card.headline == "Fargo (1996) — Cancelled")
        #expect(card.tone == .neutral)
        #expect(card.actions == [.showLog, .adjustAndRetry, .retry, .nextDisc])
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
}
