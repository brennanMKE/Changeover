import Foundation
import Testing
@testable import Changeover
@testable import ChangeoverBridge

/// #0243 — the first job of a double feature never reported that it finished.
///
/// Measured on WILLIS, 2026-10-08. `job-20261008-232502-8F8B` went
/// `starting → encoding → organizing` and then, 55 ms later,
/// `job-20261009-000140-AC20` started. 8F8B never got a `job.finished`, although
/// `report` listed it as succeeded.
///
/// The feed is a diff of snapshots, and the diff only ever looked at `new.job`.
/// When one job replaces another between two snapshots, the first job's terminal
/// state is simply never observed.
///
/// This is a hang rather than a cosmetic gap: `import`'s own help tells an agent
/// to wait for `job-done` on the id `import` returned, and on a double feature
/// that id is the one whose event never comes.
@Suite struct DoubleFeatureFinishEventTests {

    private static func job(_ id: String, phase: String,
                            outcome: String? = nil,
                            failureReason: String? = nil) -> JobStatus {
        BridgeFixtures.job(running: outcome == nil, id: id, phase: phase,
                           percent: nil, unit: nil, outcome: outcome,
                           failureReason: failureReason)
    }

    private static func status(job: JobStatus?,
                               lastFinished: JobStatus? = nil) -> BridgeStatus {
        BridgeFixtures.status(job: job, lastFinished: lastFinished)
    }

    /// The bug, as the test that would have caught it.
    @Test func thefirstJobOfADoubleFeatureReportsThatItFinished() {
        let before = Self.status(job: Self.job("8F8B", phase: "organizing"))
        // Job 2 has replaced job 1 in `job`; job 1's end is only in
        // `lastFinished`.
        let after = Self.status(
            job: Self.job("AC20", phase: "starting"),
            lastFinished: Self.job("8F8B", phase: "succeeded", outcome: "succeeded"))

        let kinds = BridgeStatusDiff.drafts(from: before, to: after).map(\.kind)
        #expect(kinds.contains(BridgeEvent.Kind.jobFinished),
                "8F8B ended and nothing said so — an agent waiting on it hangs")
    }

    /// And it names the job that ended, not the one that started. An event
    /// carrying the wrong id is no better than a missing one for a watcher
    /// filtering on `--job`.
    @Test func thefinishedEventNamesTheJobThatEnded() {
        let before = Self.status(job: Self.job("8F8B", phase: "organizing"))
        let after = Self.status(
            job: Self.job("AC20", phase: "starting"),
            lastFinished: Self.job("8F8B", phase: "succeeded", outcome: "succeeded"))

        let finished = BridgeStatusDiff.drafts(from: before, to: after)
            .first { $0.kind == BridgeEvent.Kind.jobFinished }
        #expect(finished?.job?.id == "8F8B")
    }

    /// The single-film case must not report twice.
    ///
    /// There the finished job is still the reported one, so `lastFinished` is
    /// `nil` by construction and only the ordinary phase transition fires.
    @Test func asingleFilmDiscStillReportsExactlyOnce() {
        let before = Self.status(job: Self.job("ONLY", phase: "organizing"))
        let after = Self.status(
            job: Self.job("ONLY", phase: "succeeded", outcome: "succeeded"),
            lastFinished: nil)

        let finished = BridgeStatusDiff.drafts(from: before, to: after)
            .filter { $0.kind == BridgeEvent.Kind.jobFinished }
        #expect(finished.count == 1, "one job ending is one event, not two")
    }

    /// The regression #0243 shipped with, found on hardware the next day.
    ///
    /// Dragnet's job ended and was reported normally while it was still
    /// `status.job`. #0232 then cleared it when the disc left. When the NEXT
    /// disc's job started, `lastFinished` became non-nil for the first time —
    /// and the old guard, which asked only whether `lastFinished` had *changed*,
    /// replayed a `succeeded` for a job that had finished the previous day, in
    /// the same millisecond as the new job's `starting`.
    ///
    /// The peer's waiter took it as the NEW job finishing and tried to eject
    /// 0.4 s into the encode. `eject` refused because a job was running, so
    /// nothing was lost — but the next such mistake might not be so lucky.
    ///
    /// My original test for this compared two identical snapshots, which is the
    /// case that never happens. This one reproduces the real sequence.
    @Test func afinishAnnouncedOnceIsNotReplayedWhenTheNextDiscStarts() {
        // Dragnet's job, already announced as succeeded while it was still the
        // reported job, then cleared with its disc (#0232).
        let afterDragnet = Self.status(job: nil, lastFinished: nil)
        // A new disc, a new job. `lastFinished` becomes non-nil here for the
        // first time, which is exactly what used to trigger the replay.
        let burbsStarting = Self.status(
            job: Self.job("FFE5", phase: "starting"),
            lastFinished: Self.job("E2EC", phase: "succeeded", outcome: "succeeded"))

        let finished = BridgeStatusDiff.drafts(from: afterDragnet, to: burbsStarting)
            .filter { $0.kind == BridgeEvent.Kind.jobFinished }
        // E2EC finished yesterday and was announced then. Announcing it again
        // as the next disc starts is worse than not at all.
        #expect(finished.isEmpty)
    }

    /// And the same thing one step later: a terminal job still sitting in
    /// `status.job` when the next one replaces it was already announced by the
    /// ordinary phase transition.
    @Test func ajobAlreadySeenTerminalIsNotAnnouncedTwice() {
        let settled = Self.status(
            job: Self.job("ONLY", phase: "succeeded", outcome: "succeeded"))
        let nextStarting = Self.status(
            job: Self.job("NEXT", phase: "starting"),
            lastFinished: Self.job("ONLY", phase: "succeeded", outcome: "succeeded"))

        let finished = BridgeStatusDiff.drafts(from: settled, to: nextStarting)
            .filter { $0.kind == BridgeEvent.Kind.jobFinished }
        #expect(finished.isEmpty,
                "the phase transition to succeeded already said so")
    }

    /// A job that finished and was already reported must not be reported again
    /// on every later snapshot.
    @Test func thesameFinishedJobIsNotReportedTwice() {
        let first = Self.status(
            job: Self.job("AC20", phase: "encoding"),
            lastFinished: Self.job("8F8B", phase: "succeeded", outcome: "succeeded"))
        let second = Self.status(
            job: Self.job("AC20", phase: "encoding"),
            lastFinished: Self.job("8F8B", phase: "succeeded", outcome: "succeeded"))

        let finished = BridgeStatusDiff.drafts(from: first, to: second)
            .filter { $0.kind == BridgeEvent.Kind.jobFinished }
        #expect(finished.isEmpty, "the same ending must be announced once")
    }

    /// A failure that is replaced reports as a failure, not merely as an ending.
    @Test func areplacedFailureSaysItFailed() {
        let before = Self.status(job: Self.job("FIRST", phase: "encoding"))
        let failed = Self.job("FIRST", phase: "failed", outcome: "failed",
                              failureReason: "HandBrake couldn't read this disc")
        let after = Self.status(job: Self.job("SECOND", phase: "starting"),
                                lastFinished: failed)

        let finished = BridgeStatusDiff.drafts(from: before, to: after)
            .first { $0.kind == BridgeEvent.Kind.jobFinished }
        #expect(finished?.summary.contains("couldn't read this disc") == true)
    }
}
