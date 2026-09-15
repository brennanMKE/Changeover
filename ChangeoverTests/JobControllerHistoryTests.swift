import Foundation
import Testing
@testable import Changeover

/// Covers #0042: `JobController` holds the current job plus a bounded
/// `history` of finished ones, replacing the single `currentJobID`/
/// `currentJobState`/`currentLog`/`lastOutcome` scalars that used to be
/// overwritten in place on every `start()`.
///
/// Driven entirely through the injectable `Runner` seam — no disc, no
/// `HandBrakeCLI`.
@MainActor
struct JobControllerHistoryTests {

    // MARK: - Helpers (mirrors JobControllerTests')

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

    private static func request(_ metadata: MovieMetadata) -> RipRequest {
        RipRequest(metadata: metadata, featureTitleIndex: 1, audioTrackNumbers: [])
    }

    private static let destination = URL(fileURLWithPath:
        "/Volumes/Plex/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4")

    private static let testDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
        deviceNode: "disk6",
        discID: "ceaaceba983071d9a7e28fd6107947b7")

    private static func readyScanState(titleIndex: Int = 1) -> ScanState {
        let title = DiscTitle(
            index: titleIndex, durationSeconds: 6_645, chapterCount: 21,
            sizeBytes: 6_300_000_000, outputFileName: nil)
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [title])
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: titleIndex, warnings: []))
    }

    private static func mount(_ controller: JobController, disc: DiscInsertion, titleIndex: Int = 1) {
        controller.insertedDisc = disc
        controller.scanState = Self.readyScanState(titleIndex: titleIndex)
        controller.selectTitle(titleIndex, settings: AppSettings())
    }

    /// A one-shot latch, same shape as `JobControllerTests.Gate`.
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

    private func waitUntilIdle(_ controller: JobController, iterations: Int = 100_000) async throws {
        var spins = 0
        while controller.isRunning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")
    }

    private func runOneJob(_ controller: JobController) async throws {
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)
    }

    // MARK: - A finished job moves into history

    @Test func aFinishedJobMovesIntoHistoryAndCurrentBecomesNil() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })
        #expect(controller.current == nil)
        #expect(controller.history.isEmpty)

        try await runOneJob(controller)

        #expect(controller.current == nil)
        #expect(controller.history.count == 1)
        #expect(controller.history.first?.state.outcome == .succeeded(destination: Self.destination))
    }

    // MARK: - Three sequential jobs appear in order

    @Test func threeSequentialJobsAppearInHistoryInOrderAndJobIDFindsEach() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })

        var ids: [JobID] = []
        for _ in 1...3 {
            Self.mount(controller, disc: Self.testDisc)
            controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
            let id = try #require(controller.current?.id)
            ids.append(id)
            try await waitUntilIdle(controller)
        }

        #expect(controller.history.map(\.id) == ids)
        for id in ids {
            #expect(controller.job(id: id)?.id == id)
        }
    }

    // MARK: - Pruning

    @Test func pruningDropsTheOldestJobPastTheHistoryLimit() async throws {
        let controller = JobController(historyLimit: 2, runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })

        var ids: [JobID] = []
        for _ in 1...3 {
            Self.mount(controller, disc: Self.testDisc)
            controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
            let id = try #require(controller.current?.id)
            ids.append(id)
            try await waitUntilIdle(controller)
        }

        #expect(controller.history.count == 2)
        #expect(controller.history.map(\.id) == [ids[1], ids[2]])
        #expect(controller.job(id: ids[0]) == nil)
        #expect(controller.retainedLog(forJobID: ids[0].rawValue) == nil)
    }

    // MARK: - lastOutcome

    @Test func lastOutcomeIsNilWhileRunningAndTheFinishedOutcomeOtherwise() async throws {
        let gate = Gate()
        let controller = JobController(runner: { context, _ in
            await gate.wait()
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        #expect(controller.lastOutcome == nil)

        gate.open()
        try await waitUntilIdle(controller)
        #expect(controller.lastOutcome == .succeeded(destination: Self.destination))
    }

    // MARK: - Between-job traffic never lands in a finished job's log (#0043 review fix)

    /// The exact bug the #0043 review flagged for this ticket to fix: once a
    /// job finishes, anything logged with no job running (a scan line, a
    /// refused `start`/`ejectDisc`) must go to the controller-level log, not
    /// get appended into the log of the job that just finished.
    @Test func betweenJobTrafficAfterAFinishedJobNeverLandsInItsRetainedLog() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })
        try await runOneJob(controller)
        let finishedID = try #require(controller.history.first?.id)
        let linesAfterFinish = controller.retainedLog(forJobID: finishedID.rawValue)?.lines.count

        // No job is running now — none of this may touch the finished job's log.
        controller.removeDisc()
        #expect(controller.startScan(settings: AppSettings()) == false)
        _ = await controller.ejectDisc()

        let finishedLog = try #require(controller.retainedLog(forJobID: finishedID.rawValue))
        #expect(finishedLog.lines.count == linesAfterFinish)
        #expect(!finishedLog.lines.contains { $0.text.contains("No disc is mounted") })
    }

    // MARK: - clearHistory / snapshots

    @Test func clearHistoryRemovesEveryFinishedJobButNeverTouchesCurrent() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })
        try await runOneJob(controller)
        #expect(controller.history.count == 1)
        controller.clearHistory()
        #expect(controller.history.isEmpty)

        let gate = Gate()
        let running = JobController(runner: { context, _ in
            await gate.wait()
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(running, disc: Self.testDisc)
        running.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        let runningID = try #require(running.current?.id)

        running.clearHistory()
        #expect(running.current?.id == runningID)

        gate.open()
        try await waitUntilIdle(running)
    }

    @Test func snapshotsIncludeHistoryThenTheRunningJobOldestFirst() async throws {
        // First call finishes immediately, landing that job in `history`;
        // the second parks on `gate` so it's still `current` when
        // `snapshots` is read below.
        final class CallCount { var value = 0 }
        let calls = CallCount()
        let gate = Gate()
        let controller = JobController(runner: { context, _ in
            calls.value += 1
            if calls.value == 2 {
                await gate.wait()
            }
            return fakeSuccess(context, destination: Self.destination)
        })
        try await runOneJob(controller)

        let historyID = try #require(controller.history.first?.id)

        // Second job: parked on a fresh gate so it's still `current` while
        // `historyID`'s job sits in `history` — this is the "history + a
        // running job" shape `snapshots` exists for.
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        let runningID = try #require(controller.current?.id)

        #expect(controller.snapshots.map(\.id) == [historyID, runningID])

        gate.open()
        try await waitUntilIdle(controller)
    }

    // MARK: - Observation

    /// #0042 plan refresh: `isRunning` now derives from a stored `current`,
    /// so a plain assignment to `current` must fire `withObservationTracking`
    /// — the property #0047's power assertion / #0048's queue view depend on.
    @Test func isRunningFiresObservationWhenAJobStarts() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        var changed = false
        withObservationTracking {
            _ = controller.isRunning
        } onChange: {
            changed = true
        }

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        #expect(changed == true)

        try await waitUntilIdle(controller)
    }
}
