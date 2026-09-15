import Foundation
import Testing
@testable import Changeover

/// Covers #0048's `JobPresentation` — pure, `nonisolated`, driven off
/// `JobSnapshot`, no `JobController`, no view, no disc. This is the layer
/// `JobHistoryView`/`StatusMenuView` render and the layer a Phase 4 client
/// will eventually render too, so every `JobPhase` and a representative set
/// of `FailureReason`s must produce a specific, asserted string — never
/// "compiles and doesn't crash".
struct JobPresentationTests {

    // MARK: - Fixtures

    private static func metadata(selectionDisc: DiscInsertion? = nil) throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        let movie = try JSONDecoder().decode(TMDBMovie.self, from: json)
        return MovieMetadata(from: movie, selectionDisc: selectionDisc)
    }

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    /// Builds a `JobSnapshot` at a given non-terminal `phase`, reached the
    /// only way production code reaches one — `JobState.initial.advancing(to:)`
    /// — so every fixture here is a state the real transition table actually
    /// allows, never a hand-forged invariant violation.
    private static func snapshot(
        phase: JobPhase,
        progress: Double? = nil,
        metadata: MovieMetadata? = nil
    ) throws -> JobSnapshot {
        var state = JobState.initial
        for step in try path(to: phase) {
            state = try #require(state.advancing(to: step))
        }
        return JobSnapshot(
            id: JobID.make(),
            metadata: try metadata ?? Self.metadata(),
            state: try progressState(state, progress: progress),
            outcome: nil,
            startDate: start,
            endDate: nil
        )
    }

    /// `JobState.progress` has no public setter — every legitimate advance
    /// resets it to `nil` (#0041: no progress parser exists yet). Tests that
    /// need a determinate value build the state through `Codable`, the one
    /// other public entry point, since `JobState.init(from:)` accepts an
    /// explicit `progress` in `0...1` for a non-terminal phase.
    private static func progressState(_ state: JobState, progress: Double?) throws -> JobState {
        guard let progress else { return state }
        let json = """
        {"phase":"\(state.phase.rawValue)","progress":\(progress)}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(JobState.self, from: json)
    }

    /// The one legal path from `.starting` to `phase`, per
    /// `JobPhase.allowedTransitions`.
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

    /// A terminal snapshot, reached via `finishing(with:)` exactly like
    /// `Job.finish(with:)` does — `outcome` mirrors `Job.outcome` (#0042's
    /// deliberate divergence from `state.outcome`), so every fixture below
    /// exercises the same field `JobPresentation.make(for:)` actually reads.
    private static func terminalSnapshot(
        outcome: JobOutcome,
        via nonTerminal: JobPhase = .organizing,
        startDate: Date = start,
        endDate: Date? = nil,
        metadata: MovieMetadata? = nil
    ) throws -> JobSnapshot {
        var state = JobState.initial
        for step in try path(to: nonTerminal) {
            state = try #require(state.advancing(to: step))
        }
        let finished = try #require(state.finishing(with: outcome))
        return JobSnapshot(
            id: JobID.make(),
            metadata: try metadata ?? Self.metadata(),
            state: finished,
            outcome: outcome,
            startDate: startDate,
            endDate: endDate
        )
    }

    private static func failure(_ reason: FailureReason, stage: JobStage = .encode, fallback: FallbackAttempt? = nil) -> JobFailure {
        JobFailure(stage: stage, reason: reason, logTail: [], fallback: fallback)
    }

    // MARK: - Non-terminal phases

    @Test func startingIsNeutralWithAFixedLabel() throws {
        let presentation = JobPresentation.make(for: try Self.snapshot(phase: .starting))
        #expect(presentation.label == "Checking setup")
        #expect(presentation.tone == .neutral)
        #expect(presentation.progress == .none)
        #expect(presentation.detail.isEmpty)
    }

    @Test func encodingWithNoKnownProgressIsIndeterminate() throws {
        let presentation = JobPresentation.make(for: try Self.snapshot(phase: .encoding))
        #expect(presentation.label == "Encoding Blade Runner (1982)")
        #expect(presentation.tone == .active)
        #expect(presentation.progress == .indeterminate)
    }

    @Test func encodingWithKnownProgressIsDeterminate() throws {
        let presentation = JobPresentation.make(for: try Self.snapshot(phase: .encoding, progress: 0.42))
        #expect(presentation.progress == .determinate(0.42))
    }

    @Test func fallbackIsWarningWithAFixedLabel() throws {
        let presentation = JobPresentation.make(for: try Self.snapshot(phase: .fallback))
        #expect(presentation.label == "Retrying with MakeMKV")
        #expect(presentation.tone == .warning)
        #expect(presentation.progress == .indeterminate)
    }

    @Test func organizingIsActiveIndeterminateWithAFixedLabel() throws {
        let presentation = JobPresentation.make(for: try Self.snapshot(phase: .organizing))
        #expect(presentation.label == "Moving into Plex")
        #expect(presentation.tone == .active)
        #expect(presentation.progress == .indeterminate)
    }

    /// #0041 review: a 40-minute extras encode is its own phase, not folded
    /// into "Moving into Plex".
    @Test func extrasIsActiveIndeterminateWithItsOwnLabel() throws {
        let presentation = JobPresentation.make(for: try Self.snapshot(phase: .extras))
        #expect(presentation.label == "Encoding extras")
        #expect(presentation.tone == .active)
        #expect(presentation.progress == .indeterminate)
    }

    // MARK: - Terminal phases

    @Test func succeededShowsElapsedTime() throws {
        let end = Self.start.addingTimeInterval(42 * 60 + 7) // 42m07s
        let snapshot = try Self.terminalSnapshot(
            outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")),
            startDate: Self.start,
            endDate: end
        )
        let presentation = JobPresentation.make(for: snapshot)
        #expect(presentation.label == "Finished in 42m 07s")
        #expect(presentation.tone == .success)
        #expect(presentation.progress == .none)
        #expect(presentation.detail.isEmpty)
    }

    @Test func succeededWithNoEndDateFallsBackToAPlainLabel() throws {
        // Not reachable through `Job.finish(with:)` in production (`endDate`
        // is always set alongside `outcome`), but `JobPresentation` must not
        // crash or force-unwrap on a hand-built snapshot that omits it.
        let snapshot = try Self.terminalSnapshot(
            outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")),
            endDate: nil
        )
        #expect(JobPresentation.make(for: snapshot).label == "Succeeded")
    }

    @Test func cancelledIsNeutralWithAFixedLabelAndNoDetail() throws {
        let snapshot = try Self.terminalSnapshot(outcome: .failed(Self.failure(.cancelled)), via: .encoding)
        let presentation = JobPresentation.make(for: snapshot)
        #expect(presentation.label == "Cancelled")
        #expect(presentation.tone == .neutral)
        #expect(presentation.progress == .none)
        #expect(presentation.detail.isEmpty)
    }

    /// The label stays the fixed word "Failed" — the *reason* lives in
    /// `detail`, matching #0048's "failed jobs show the actual reason".
    @Test func failedShowsAFixedLabelWithTheReasonInDetail() throws {
        let snapshot = try Self.terminalSnapshot(outcome: .failed(Self.failure(.diskFull)))
        let presentation = JobPresentation.make(for: snapshot)
        #expect(presentation.label == "Failed")
        #expect(presentation.tone == .failure)
        #expect(presentation.progress == .none)
        let expected = FailurePresenter.message(for: Self.failure(.diskFull))
        #expect(presentation.detail == [expected.headline] + expected.details)
        #expect(!presentation.detail.isEmpty)
    }

    /// A representative set of `FailureReason`s — each must surface its own
    /// distinct headline, not a generic "something failed" string.
    @Test(arguments: [
        FailureReason.toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"),
        .toolLaunchFailed("permission denied"),
        .toolIncompatible(detail: "no x265 encoder"),
        .toolExited(code: 1),
        .noTitlesProduced,
        .destinationUnwritable(path: "/Volumes/Plex/Movies"),
        .diskFull,
        .activationExpired,
        .discUnreadable,
        .unknown("mystery"),
    ])
    func everyFailureReasonProducesItsOwnHeadlineInDetail(_ reason: FailureReason) throws {
        let failure = Self.failure(reason)
        let snapshot = try Self.terminalSnapshot(outcome: .failed(failure))
        let presentation = JobPresentation.make(for: snapshot)
        let expected = FailurePresenter.message(for: failure)
        #expect(presentation.detail.first == expected.headline)
    }

    @Test func failedWithAFallbackAttemptIncludesTheFallbackSentenceInDetail() throws {
        let fallback = FallbackAttempt.failed(stage: .rip, reason: .discUnreadable, logTail: [])
        let failure = Self.failure(.discUnreadable, fallback: fallback)
        let snapshot = try Self.terminalSnapshot(outcome: .failed(failure))
        let presentation = JobPresentation.make(for: snapshot)
        let expected = FailurePresenter.message(for: failure)
        #expect(presentation.detail == [expected.headline] + expected.details)
        #expect(presentation.detail.contains { $0.contains("MakeMKV fallback was tried") })
    }

    // MARK: - isCancelling

    @Test func isCancellingOverridesEveryNonTerminalPhase() throws {
        for phase: JobPhase in [.starting, .encoding, .fallback, .organizing, .extras] {
            let snapshot = try Self.snapshot(phase: phase)
            let presentation = JobPresentation.make(for: snapshot, isCancelling: true)
            #expect(presentation.label == "Cancelling…", "phase: \(phase)")
            #expect(presentation.tone == .warning, "phase: \(phase)")
            #expect(presentation.progress == .indeterminate, "phase: \(phase)")
        }
    }

    /// A stale "cancelling" flag the caller forgot to clear must never hide
    /// the real, already-settled outcome.
    @Test func isCancellingIsIgnoredOnceTheJobIsTerminal() throws {
        let snapshot = try Self.terminalSnapshot(outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")), endDate: Self.start.addingTimeInterval(5))
        let presentation = JobPresentation.make(for: snapshot, isCancelling: true)
        #expect(presentation.label != "Cancelling…")
        #expect(presentation.tone == .success)
    }

    // MARK: - formatElapsed

    @Test func formatElapsedUnderAMinuteShowsSecondsOnly() {
        #expect(JobPresentation.formatElapsed(7) == "7s")
        #expect(JobPresentation.formatElapsed(0) == "0s")
    }

    @Test func formatElapsedUnderAnHourShowsMinutesAndSeconds() {
        #expect(JobPresentation.formatElapsed(65) == "1m 05s")
        #expect(JobPresentation.formatElapsed(42 * 60 + 7) == "42m 07s")
    }

    @Test func formatElapsedOverAnHourShowsHoursAndMinutes() {
        #expect(JobPresentation.formatElapsed(3661) == "1h 01m")
        #expect(JobPresentation.formatElapsed(2 * 3600 + 5 * 60) == "2h 05m")
    }

    // MARK: - menuSummary

    @Test func menuSummaryWhenNotConfiguredAlwaysWins() throws {
        let running = try Self.snapshot(phase: .encoding)
        #expect(JobPresentation.menuSummary(current: running, lastFinished: nil, isConfigured: false) == "Settings required")
        #expect(JobPresentation.menuSummary(current: nil, lastFinished: nil, isConfigured: false) == "Settings required")
    }

    @Test func menuSummaryWhenIdleWithNoHistory() {
        #expect(JobPresentation.menuSummary(current: nil, lastFinished: nil, isConfigured: true) == "Idle — insert a DVD to begin")
    }

    @Test func menuSummaryWhenRunningReflectsThePhase() throws {
        let running = try Self.snapshot(phase: .encoding)
        #expect(JobPresentation.menuSummary(current: running, lastFinished: nil, isConfigured: true) == "Encoding Blade Runner (1982)")
    }

    @Test func menuSummaryAfterAFailureNamesTheReason() throws {
        let finished = try Self.terminalSnapshot(outcome: .failed(Self.failure(.diskFull)))
        let summary = JobPresentation.menuSummary(current: nil, lastFinished: finished, isConfigured: true)
        #expect(summary == "Last job failed — \(FailurePresenter.message(for: Self.failure(.diskFull)).headline)")
    }

    /// A cancel is the user's own request, not a problem to keep reporting —
    /// mirrors `JobNotifier.message(for:outcome:)`'s own distinction.
    @Test func menuSummaryAfterACancelReadsAsIdle() throws {
        let finished = try Self.terminalSnapshot(outcome: .failed(Self.failure(.cancelled)), via: .encoding)
        #expect(JobPresentation.menuSummary(current: nil, lastFinished: finished, isConfigured: true) == "Idle — insert a DVD to begin")
    }

    @Test func menuSummaryAfterASuccessReadsAsIdle() throws {
        let finished = try Self.terminalSnapshot(outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")))
        #expect(JobPresentation.menuSummary(current: nil, lastFinished: finished, isConfigured: true) == "Idle — insert a DVD to begin")
    }

    // MARK: - canRetry

    @Test func canRetryTruthTable() throws {
        let failed = try Self.terminalSnapshot(outcome: .failed(Self.failure(.diskFull)))
        let cancelled = try Self.terminalSnapshot(outcome: .failed(Self.failure(.cancelled)), via: .encoding)
        let succeeded = try Self.terminalSnapshot(outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")))
        let running = try Self.snapshot(phase: .encoding)

        // Terminal-failed/cancelled, idle, matching disc ids: retryable.
        #expect(JobPresentation.canRetry(failed, isRunning: false, insertedDiscID: "disc-1", jobDiscID: "disc-1") == true)
        #expect(JobPresentation.canRetry(cancelled, isRunning: false, insertedDiscID: "disc-1", jobDiscID: "disc-1") == true)

        // Succeeded or still running: never retryable, whatever the disc ids say.
        #expect(JobPresentation.canRetry(succeeded, isRunning: false, insertedDiscID: "disc-1", jobDiscID: "disc-1") == false)
        #expect(JobPresentation.canRetry(running, isRunning: false, insertedDiscID: "disc-1", jobDiscID: "disc-1") == false)

        // A job is currently running: refuse even a matching failed job.
        #expect(JobPresentation.canRetry(failed, isRunning: true, insertedDiscID: "disc-1", jobDiscID: "disc-1") == false)

        // Disc ids differ, missing, or both nil: never retryable.
        #expect(JobPresentation.canRetry(failed, isRunning: false, insertedDiscID: "disc-1", jobDiscID: "disc-2") == false)
        #expect(JobPresentation.canRetry(failed, isRunning: false, insertedDiscID: nil, jobDiscID: "disc-1") == false)
        #expect(JobPresentation.canRetry(failed, isRunning: false, insertedDiscID: "disc-1", jobDiscID: nil) == false)
        #expect(JobPresentation.canRetry(failed, isRunning: false, insertedDiscID: nil, jobDiscID: nil) == false)
    }

    // MARK: - statusSymbolName

    @Test func statusSymbolNameReflectsIsRunning() {
        #expect(JobPresentation.statusSymbolName(isRunning: true) == "opticaldisc.fill")
        #expect(JobPresentation.statusSymbolName(isRunning: false) == "opticaldisc")
    }
}
