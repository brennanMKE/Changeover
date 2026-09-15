import Foundation
import Testing
@testable import Changeover

/// Covers #0046: `JobController.cancel(id:)` and `CancelPolicy`. Every test
/// drives the controller through its injectable `Runner` seam — `fakeCancel`
/// (`FakeRunnerSupport.swift`) or a hand-rolled stub — so none of this needs
/// `makemkvcon`, `HandBrakeCLI`, or a physical disc. `DVDPipelineCancellation
/// Tests` and `ProcessRunnerTests` cover the real subprocess-cancellation
/// path this sits on top of.
@MainActor
struct JobCancellationTests {

    // MARK: - Helpers (mirrors JobControllerTests' own copies)

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

    /// Pumps the main actor until the controller goes idle, rather than
    /// sleeping — mirrors `JobControllerTests.waitUntilIdle`.
    private func waitUntilIdle(_ controller: JobController, iterations: Int = 200_000) async throws {
        var spins = 0
        while controller.isRunning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")
    }

    /// Pumps the main actor until the current job reaches `phase`.
    private func waitUntilPhase(_ controller: JobController, _ phase: JobPhase, iterations: Int = 200_000) async throws {
        var spins = 0
        while controller.currentJobState?.phase != phase && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(controller.currentJobState?.phase == phase, "job never reached \(phase); last seen \(String(describing: controller.currentJobState?.phase))")
    }

    /// A one-shot latch, mirroring `JobControllerTests.Gate`.
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

    /// Records every `begin`/`end` call, mirroring `PowerAssertionTests
    /// .FakeSleepAssertion` — a separate copy, per this project's convention
    /// of each test file owning its own small fixtures.
    @MainActor
    private final class FakeSleepAssertion: SleepAssertion {
        private(set) var isHeld = false
        private(set) var beginCount = 0
        private(set) var endCount = 0

        func begin(reason: String) {
            beginCount += 1
            isHeld = true
        }

        func end() {
            endCount += 1
            isHeld = false
        }
    }

    // MARK: - The core wiring: cancel → finish → history

    /// `cancel(id:)` while `.encoding` ends the job `.cancelled`, moves it
    /// into `history`, clears `current`, and accepts the next `start` — a
    /// cancel never wedges the controller. The second job is cancelled too
    /// (with the same `fakeCancel` runner) so the test leaves nothing
    /// running afterward.
    @Test func cancelWhileEncodingEndsTheJobCancelledAndAcceptsTheNextStart() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()))
        try await waitUntilPhase(controller, .encoding)
        let firstID = try #require(controller.current?.id)

        #expect(controller.cancel(id: firstID))
        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome == .failed(JobFailure(stage: .encode, reason: .cancelled)))
        #expect(controller.lastOutcome?.failure?.reason == .cancelled)
        #expect(controller.current == nil)
        #expect(controller.isRunning == false)

        let second = try Self.metadata(id: 50456, title: "Hanna", releaseDate: "2011-03-08")
        #expect(controller.start(request: Self.request(second), settings: AppSettings()))
        try await waitUntilPhase(controller, .encoding)
        let secondID = try #require(controller.current?.id)
        #expect(secondID != firstID)

        #expect(controller.cancel(id: secondID))
        try await waitUntilIdle(controller)
        #expect(controller.lastOutcome?.failure?.reason == .cancelled)
    }

    /// #0047 handoff: a cancel must release the sleep assertion, exactly
    /// like any other terminal outcome — the job ends through `finish`, and
    /// `finish`'s `sleepAssertion.end()` is unconditional.
    @Test func releaseOnCancelReleasesTheSleepAssertion() async throws {
        let sleepAssertion = FakeSleepAssertion()
        let controller = JobController(
            runner: { context, _ in await fakeCancel(context) },
            sleepAssertion: sleepAssertion
        )
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .encoding)
        #expect(sleepAssertion.isHeld)
        #expect(sleepAssertion.beginCount == 1)
        #expect(sleepAssertion.endCount == 0)

        let id = try #require(controller.current?.id)
        #expect(controller.cancel(id: id))
        try await waitUntilIdle(controller)

        #expect(!sleepAssertion.isHeld)
        #expect(sleepAssertion.endCount == 1)
    }

    /// The notification still posts on cancel (earlier decision, carried
    /// forward by #0046's refresh) — `JobController.start`'s `Task` calls
    /// `JobNotifier.notify` unconditionally after `finish`, for every
    /// `JobOutcome`. Proven here as "the outcome the notifier would have
    /// received is exactly the cancelled one", since `JobNotifier` itself is
    /// covered by `JobNotifierTests`.
    @Test func lastOutcomeAfterACancelIsWhatTheNotifierWouldReceive() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .encoding)
        let id = try #require(controller.current?.id)
        controller.cancel(id: id)
        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome?.failure?.reason == .cancelled)
    }

    // MARK: - Refusals

    @Test func cancelRefusesWhenNoJobIsRunning() {
        let controller = JobController(runner: { _, _ in .succeeded(destination: Self.destination) })
        #expect(controller.cancel(id: JobID.make()) == false)
        #expect(controller.logLines.contains { $0.contains("Cancel refused") })
    }

    /// A wrong id — a stale button from a finished job, or a mismatched id
    /// off a future wire protocol (#0060) — must never touch the real
    /// running job.
    @Test func cancelRefusesAWrongJobID() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .encoding)

        let wrongID = JobID.make()
        #expect(controller.cancel(id: wrongID) == false)
        #expect(controller.isRunning == true)
        #expect(controller.logLines.contains { $0.contains("Cancel refused") })

        // Clean up: cancel for real, so the test doesn't leak a hung Task.
        let realID = try #require(controller.current?.id)
        #expect(controller.cancel(id: realID) == true)
        try await waitUntilIdle(controller)
        #expect(controller.lastOutcome?.failure?.reason == .cancelled)
    }

    /// `organizing` has no outgoing `cancelled` edge (#0041): the Plex move
    /// must finish once started. `cancel(id:)` refuses, the job keeps
    /// running, and it succeeds normally once released.
    @Test func cancelRefusesWhileOrganizing() async throws {
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

        let id = try #require(controller.current?.id)
        #expect(controller.cancel(id: id) == false)
        #expect(controller.isRunning == true)
        #expect(controller.logLines.contains { $0.contains("moved into Plex") })

        gate.open()
        try await waitUntilIdle(controller)
        #expect(controller.lastOutcome == .succeeded(destination: Self.destination))
    }

    /// A repeated cancel on an already-cancelled (now finished) job is
    /// refused, not a silent no-op that could be mistaken for cancelling a
    /// second, different job.
    @Test func repeatedCancelAfterTheJobEndedIsRefused() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .encoding)

        let id = try #require(controller.current?.id)
        #expect(controller.cancel(id: id) == true)
        try await waitUntilIdle(controller)

        #expect(controller.cancel(id: id) == false)
    }

    /// A second cancel while the job is *still* running (before the runner
    /// has actually noticed `Task.isCancelled`) is harmless: `Task.cancel()`
    /// is idempotent, and the job still ends exactly once, with one history
    /// entry.
    @Test func aSecondCancelWhileStillRunningIsHarmless() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        Self.mount(controller, disc: Self.testDisc)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilPhase(controller, .encoding)

        let id = try #require(controller.current?.id)
        #expect(controller.cancel(id: id) == true)
        #expect(controller.cancel(id: id) == true)
        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome?.failure?.reason == .cancelled)
    }
}
