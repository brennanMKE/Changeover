import Foundation
import Testing
@testable import Changeover

/// #0048 review — `JobController.retry(id:settings:)`. Retry must replay the
/// finished job's own recorded `RipRequest`, never the selection the
/// controller holds by then, and must never run against a disc other than
/// the job's own (#0034's overwrite). Driven entirely through the `Runner`
/// seam: no HandBrakeCLI, no disc.
@MainActor
struct JobRetryTests {

    // MARK: - Helpers

    private static func metadata(disc: DiscInsertion) throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json), selectionDisc: disc)
    }

    private static let discA = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_A"), deviceNode: "disk6", discID: "disc-a")
    private static let discB = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_B"), deviceNode: "disk6", discID: "disc-b")

    /// Two titles, so "the job's title" and "the current selection" can differ.
    private static func twoTitleScan() -> ScanState {
        let titles = [1, 2].map {
            DiscTitle(index: $0, durationSeconds: 6_000 + $0, chapterCount: 20, sizeBytes: 6_000_000_000, outputFileName: nil)
        }
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles)
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: 1, warnings: []))
    }

    private static func mount(_ controller: JobController, disc: DiscInsertion, titleIndex: Int = 1) {
        controller.insertedDisc = disc
        controller.scanState = twoTitleScan()
        controller.selectTitle(titleIndex, settings: AppSettings())
    }

    private static func failure() -> JobOutcome {
        .failed(JobFailure(stage: .encode, reason: .diskFull))
    }

    /// Records every run's resolved title, and fails each job.
    @MainActor
    private final class Recorder {
        var titles: [EncodeController.TitleSelection] = []
        var runner: JobController.Runner {
            { [self] context, _ in
                titles.append(context.selection.title)
                context.phase(.encoding)
                return JobRetryTests.failure()
            }
        }
    }

    private func waitUntilIdle(_ controller: JobController, iterations: Int = 200_000) async throws {
        var spins = 0
        while controller.isRunning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")
    }

    /// Starts one job on `disc` for title `titleIndex` and waits for it to fail.
    private func runFailedJob(_ controller: JobController, disc: DiscInsertion, titleIndex: Int = 1) async throws -> JobID {
        Self.mount(controller, disc: disc, titleIndex: titleIndex)
        let request = RipRequest(metadata: try Self.metadata(disc: disc), featureTitleIndex: titleIndex, audioTrackNumbers: [])
        try #require(controller.start(request: request, settings: AppSettings()))
        let id = try #require(controller.current?.id)
        try await waitUntilIdle(controller)
        return id
    }

    // MARK: - Tests

    /// The core fix: the user picks another title after the failure (say,
    /// for a second movie on the same disc). Retry must still encode the
    /// failed job's own title, not the one selected now.
    @Test func retryReplaysTheJobsOwnTitleNotTheCurrentSelection() async throws {
        let recorder = Recorder()
        let controller = JobController(runner: recorder.runner)
        let firstID = try await runFailedJob(controller, disc: Self.discA, titleIndex: 1)

        controller.selectTitle(2, settings: AppSettings())
        #expect(controller.selectedTitleIndex == 2)

        #expect(controller.retryDecision(id: firstID) == .retry)
        #expect(controller.retry(id: firstID, settings: AppSettings()))
        let retryID = try #require(controller.current?.id)
        #expect(retryID != firstID)
        try await waitUntilIdle(controller)

        #expect(recorder.titles == [.index(1), .index(1)])
        #expect(controller.history.map(\.id) == [firstID, retryID])
        #expect(controller.history.last?.metadata == controller.history.first?.metadata)
    }

    /// #0034 by another route: disc A's job failed, disc B is now in the
    /// drive. Retry is refused, logged, and the runner never runs again.
    @Test func retryAfterADiscSwapIsRefusedAndNeverRuns() async throws {
        let recorder = Recorder()
        let controller = JobController(runner: recorder.runner)
        let firstID = try await runFailedJob(controller, disc: Self.discA)

        controller.removeDisc()
        Self.mount(controller, disc: Self.discB)

        #expect(controller.retryDecision(id: firstID) != .retry)
        #expect(controller.retry(id: firstID, settings: AppSettings()) == false)
        #expect(controller.isRunning == false)
        #expect(recorder.titles.count == 1)
        #expect(controller.logLines.contains { $0.contains("Retry refused") && $0.contains("different disc") })
    }

    /// Re-inserting the same disc (same identity, new insertion) is allowed.
    @Test func retryAfterReinsertingTheSameDiscIsAllowed() async throws {
        let recorder = Recorder()
        let controller = JobController(runner: recorder.runner)
        let firstID = try await runFailedJob(controller, disc: Self.discA)

        controller.removeDisc()
        let reinserted = DiscInsertion(mountURL: Self.discA.mountURL, deviceNode: "disk7", discID: Self.discA.discID)
        Self.mount(controller, disc: reinserted, titleIndex: 2)

        #expect(controller.retry(id: firstID, settings: AppSettings()))
        try await waitUntilIdle(controller)
        #expect(recorder.titles == [.index(1), .index(1)])
    }

    /// A disc with no resolvable identity retries only within its own insertion.
    @Test func anUnidentifiedDiscRetriesOnlyWithinItsInsertion() async throws {
        let recorder = Recorder()
        let controller = JobController(runner: recorder.runner)
        let unknown = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/X"), deviceNode: "disk6", discID: nil)
        let firstID = try await runFailedJob(controller, disc: unknown)

        #expect(controller.retryDecision(id: firstID) == .retry)

        controller.removeDisc()
        let lookalike = DiscInsertion(mountURL: unknown.mountURL, deviceNode: "disk6", discID: nil)
        Self.mount(controller, disc: lookalike)
        #expect(controller.retry(id: firstID, settings: AppSettings()) == false)
        #expect(recorder.titles.count == 1)
    }

    @Test func retryIsRefusedUntilTheScanCompletes() async throws {
        let recorder = Recorder()
        let controller = JobController(runner: recorder.runner)
        let firstID = try await runFailedJob(controller, disc: Self.discA)

        controller.scanState = .scanning
        #expect(controller.retry(id: firstID, settings: AppSettings()) == false)
        #expect(recorder.titles.count == 1)
    }

    @Test func retryIsRefusedForASucceededOrUnknownJob() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: URL(fileURLWithPath: "/tmp/x.mp4"))
        })
        Self.mount(controller, disc: Self.discA)
        let request = RipRequest(metadata: try Self.metadata(disc: Self.discA), featureTitleIndex: 1, audioTrackNumbers: [])
        try #require(controller.start(request: request, settings: AppSettings()))
        let id = try #require(controller.current?.id)
        try await waitUntilIdle(controller)

        #expect(controller.retry(id: id, settings: AppSettings()) == false)
        #expect(controller.retry(id: JobID.make(), settings: AppSettings()) == false)
        #expect(controller.isRunning == false)
    }

    /// While another job runs, a finished job can't be retried.
    @Test func retryIsRefusedWhileAJobIsRunning() async throws {
        let recorder = Recorder()
        var blockNext = false
        let controller = JobController(runner: { context, settings in
            if blockNext {
                context.phase(.encoding)
                while !Task.isCancelled { await Task.yield() }
                return .failed(JobFailure(stage: .encode, reason: .cancelled))
            }
            return await recorder.runner(context, settings)
        })
        let firstID = try await runFailedJob(controller, disc: Self.discA)

        blockNext = true
        let request = RipRequest(metadata: try Self.metadata(disc: Self.discA), featureTitleIndex: 1, audioTrackNumbers: [])
        try #require(controller.start(request: request, settings: AppSettings()))
        #expect(controller.retryDecision(id: firstID) != .retry)
        #expect(controller.retry(id: firstID, settings: AppSettings()) == false)

        let runningID = try #require(controller.current?.id)
        #expect(controller.cancel(id: runningID))
        try await waitUntilIdle(controller)
    }
}
