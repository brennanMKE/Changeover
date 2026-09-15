import Foundation
import Testing
@testable import Changeover

/// Covers #0052: `JobController.removeDisc()` while a job is running.
/// Before this ticket, `removeDisc()` cleared `insertedDisc`/`scanState` and
/// never looked at `current` at all — a disc pulled mid-job told the job
/// nothing, so it either failed minutes later with a disc-shaped reason
/// (blamed on the disc, not the removal) or sat until #0009's 30-minute
/// inactivity watchdog.
///
/// Every test drives the controller through its injectable `Runner` seam —
/// `fakeCancel` (`FakeRunnerSupport.swift`) or a hand-rolled stub — so none
/// of this needs `makemkvcon`, `HandBrakeCLI`, or a physical disc.
/// `DiscRemovedDuringJobPipelineTests` covers the real `DVDPipeline`-level
/// `discRemoved` closure and the reliability-log override.
@MainActor
struct DiscRemovedDuringJobTests {

    // MARK: - Helpers (mirrors JobCancellationTests' own copies)

    private static func metadata(
        id: Int = 78,
        title: String = "Blade Runner",
        releaseDate: String = "1982-06-25"
    ) throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json), selectionDisc: testDisc)
    }

    private static func request(
        _ metadata: MovieMetadata,
        featureTitleIndex: Int = 1,
        audioTrackNumbers: [Int] = []
    ) -> RipRequest {
        RipRequest(metadata: metadata, featureTitleIndex: featureTitleIndex, audioTrackNumbers: audioTrackNumbers)
    }

    private static let destination = URL(fileURLWithPath:
        "/Volumes/Plex/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4")

    private static let testDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
        deviceNode: "disk6",
        discID: "ceaaceba983071d9a7e28fd6107947b7")

    private static func readyScanState(titleIndex: Int = 1) -> ScanState {
        let title = DiscTitle(
            index: titleIndex,
            durationSeconds: 6_645,
            chapterCount: 21,
            sizeBytes: 6_300_000_000,
            outputFileName: nil)
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [title])
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: titleIndex, warnings: []))
    }

    private static func mount(_ controller: JobController, disc: DiscInsertion, titleIndex: Int = 1) {
        controller.insertedDisc = disc
        controller.scanState = Self.readyScanState(titleIndex: titleIndex)
        controller.selectTitle(titleIndex, settings: AppSettings())
    }

    private func waitUntilIdle(_ controller: JobController, iterations: Int = 200_000) async throws {
        var spins = 0
        while controller.isRunning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")
    }

    private func waitUntilPhase(_ controller: JobController, _ phase: JobPhase, iterations: Int = 200_000) async throws {
        var spins = 0
        while controller.currentJobState?.phase != phase && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(controller.currentJobState?.phase == phase, "job never reached \(phase); last seen \(String(describing: controller.currentJobState?.phase))")
    }

    /// A one-shot latch, mirroring `JobCancellationTests.Gate`.
    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let resuming = waiters
            waiters = []
            for continuation in resuming { continuation.resume() }
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    // MARK: - Milestone + prompt stop

    /// The core of the fix: removing the disc while `.encoding` logs the
    /// milestone into the job's own log at once, flags the job, and stops it
    /// promptly (through `fakeCancel`'s cancellation-aware runner) — never
    /// waiting out a watchdog. The job ends `.failed(reason: .cancelled)`,
    /// same wire shape a plain cancel produces (#0040's no-new-`FailureReason`
    /// decision), and the next `start` is accepted.
    @Test func removeDiscWhileEncodingLogsAtOnceStopsPromptlyAndFlagsTheJob() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()))
        try await waitUntilPhase(controller, .encoding)
        let job = try #require(controller.current)

        controller.removeDisc()

        // Logged at once, synchronously, before the job's Task has even had
        // a chance to notice cancellation.
        #expect(job.log.displayLines.contains { $0.text.contains("Disc removed while the job was running") })
        #expect(job.discRemovedDuringJob)

        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome == .failed(JobFailure(stage: .encode, reason: .cancelled)))
        #expect(controller.current == nil)

        let second = try Self.metadata(id: 50456, title: "Hanna", releaseDate: "2011-03-08")
        Self.mount(controller, disc: Self.testDisc)
        #expect(controller.start(request: Self.request(second), settings: AppSettings()))
        try await waitUntilPhase(controller, .encoding)
        let secondID = try #require(controller.current?.id)
        #expect(controller.cancel(id: secondID))
        try await waitUntilIdle(controller)
    }

    /// With no job running, `removeDisc()` behaves exactly as before this
    /// ticket: it logs nothing into any job (there is none), and doesn't
    /// crash reaching for `current`/`task`.
    @Test func removeDiscWithNoJobRunningLogsNothingIntoAnyJob() async throws {
        let controller = JobController(runner: { _, _ in .succeeded(destination: Self.destination) })
        Self.mount(controller, disc: Self.testDisc)

        controller.removeDisc()

        #expect(controller.current == nil)
        #expect(controller.history.isEmpty)
        #expect(!controller.logLines.contains { $0.contains("Disc removed while the job was running") })
    }

    /// The milestone lands only in the running job's own log, never in
    /// `controllerLog` (the between-job buffer `logDisplayRows` shows once
    /// idle) — mirroring the #0043-review rule `append(_:)` already
    /// enforces for every other line logged while a job is current.
    @Test func milestoneLandsOnlyInTheJobsOwnLogNotTheControllerLog() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .encoding)

        controller.removeDisc()
        try await waitUntilIdle(controller)

        // The finished job's own retained log has the milestone…
        let job = try #require(controller.history.last)
        #expect(job.log.displayLines.contains { $0.text.contains("Disc removed while the job was running") })

        // …and it appears exactly once in the merged idle display (the
        // finished job's log, not duplicated into the controller's own
        // between-job buffer).
        let occurrences = controller.logLines.filter { $0.contains("Disc removed while the job was running") }
        #expect(occurrences.count == 1)
    }

    // MARK: - Phase-specific behaviour

    /// Removal during `.organizing`: the move is reading the already-encoded
    /// file off local disk, not the disc, so it finishes unaffected — the
    /// job still ends `.succeeded`. `task?.cancel()` is still called (no
    /// phase check), but nothing inside `PlexOrganizer.move` ever checks
    /// `Task.isCancelled` (#0041/#0046), so it's a harmless no-op here.
    @Test func removalDuringOrganizingContinuesUnaffectedAndEndsSucceeded() async throws {
        let gate = Gate()
        let controller = JobController(runner: { context, _ in
            context.phase(.encoding)
            context.phase(.organizing)
            await gate.wait()
            return .succeeded(destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .organizing)

        let job = try #require(controller.current)
        controller.removeDisc()
        #expect(job.discRemovedDuringJob)
        #expect(controller.isRunning, "organizing must not be interrupted by the removal")

        gate.open()
        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome == .succeeded(destination: Self.destination))
        #expect(controller.history.last?.discRemovedDuringJob == true)
    }

    /// Removal during `.extras`: the existing #0046 cancellation points in
    /// `DVDPipeline`'s extras loop already skip the remaining extras and log
    /// why, then the job ends `.succeeded` — `extras → succeeded` is the
    /// only legal terminal edge from `.extras` (#0041), so this needs no new
    /// transition. Exercised here at the `JobController` seam with a runner
    /// that mirrors that shape; the real loop is covered end to end by
    /// `DVDPipelineCancellationTests.aCancelDuringExtrasSkipsTheRestRemovesThePartialAndStillSucceeds`.
    @Test func removalDuringExtrasEndsSucceededWithRemainingExtrasSkippedAndLogged() async throws {
        let controller = JobController(runner: { context, _ in
            context.phase(.encoding)
            context.phase(.organizing)
            context.phase(.extras)
            while !Task.isCancelled {
                await Task.yield()
            }
            context.log("⚠︎ Cancelled — skipping the remaining 1 extra(s). The feature is already in Plex.")
            return .succeeded(destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .extras)

        controller.removeDisc()
        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome == .succeeded(destination: Self.destination))
        #expect(controller.history.last?.discRemovedDuringJob == true)
        #expect(controller.history.last?.log.displayLines.contains {
            $0.text.contains("skipping the remaining 1 extra")
        } == true)
    }

    // MARK: - Retry once the disc is re-inserted

    /// #0048's `retryDecision` already requires the same disc back in the
    /// drive and a completed scan — once the physically-pulled disc is
    /// reinserted (a fresh `insertDisc`/scan, recognised as the same disc by
    /// `SelectionReset.sameDisc`), Retry is offered with no new code needed:
    /// the job ended `.cancelled`, which `retryDecision` already treats as
    /// retryable.
    @Test func retryIsOfferedOnceTheSameDiscIsReinserted() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .encoding)
        let jobID = try #require(controller.current?.id)

        controller.removeDisc()
        try await waitUntilIdle(controller)

        // Still gone: no disc, no completed scan — Retry refuses.
        #expect(controller.retryDecision(id: jobID) == .refuse(reason: "no disc is in the drive — insert this job's disc"))

        // The same physical disc comes back.
        Self.mount(controller, disc: Self.testDisc)
        #expect(controller.retryDecision(id: jobID) == .retry)
    }
}
