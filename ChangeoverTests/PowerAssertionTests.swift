import Foundation
import Testing
@testable import Changeover

/// Covers #0047: the Mac must not idle-sleep mid-job.
///
/// Every test here drives `JobController` through its injectable
/// `sleepAssertion` seam with a recording fake — never `ProcessInfoSleep
/// Assertion`, which would take a genuine `ProcessInfo.beginActivity` token
/// even if it's released immediately. The fake's own idempotence stands in
/// for the real type's, which is a thin, low-risk pass-through onto
/// `ProcessInfo`.
@MainActor
struct PowerAssertionTests {

    // MARK: - Fake

    /// Records every call so tests can assert both the observable `isHeld`
    /// state and how many times `begin`/`end` were actually invoked —
    /// `beginCount`/`endCount` catch a caller that skips the idempotence
    /// check and calls through unconditionally.
    @MainActor
    private final class FakeSleepAssertion: SleepAssertion {
        private(set) var isHeld = false
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private(set) var reasons: [String] = []
        /// How many times a token was actually taken (i.e. `begin` ran past
        /// its own idempotence guard) — distinct from `beginCount`, which
        /// counts every call including no-ops.
        private(set) var tokensTaken = 0

        func begin(reason: String) {
            beginCount += 1
            reasons.append(reason)
            guard !isHeld else { return }
            isHeld = true
            tokensTaken += 1
        }

        func end() {
            endCount += 1
            isHeld = false
        }
    }

    // MARK: - Helpers (mirrors JobControllerTests' private fixtures)

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

    private func waitUntilIdle(_ controller: JobController,
                               iterations: Int = 100_000) async throws {
        var spins = 0
        while controller.isRunning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")
    }

    // MARK: - Fake protocol conformance itself

    @Test func beginTakesTheAssertionAndSetsIsHeld() {
        let assertion = FakeSleepAssertion()
        #expect(assertion.isHeld == false)
        assertion.begin(reason: "test")
        #expect(assertion.isHeld == true)
        #expect(assertion.tokensTaken == 1)
    }

    @Test func aSecondBeginWhileHeldDoesNotTakeASecondToken() {
        let assertion = FakeSleepAssertion()
        assertion.begin(reason: "first")
        assertion.begin(reason: "second")
        #expect(assertion.isHeld == true)
        #expect(assertion.beginCount == 2)
        // Only one token was ever actually taken — the second call was a
        // no-op past the idempotence guard.
        #expect(assertion.tokensTaken == 1)
    }

    @Test func endReleasesTheAssertion() {
        let assertion = FakeSleepAssertion()
        assertion.begin(reason: "test")
        assertion.end()
        #expect(assertion.isHeld == false)
    }

    @Test func aSecondEndWithNothingHeldIsHarmless() {
        let assertion = FakeSleepAssertion()
        assertion.end()
        #expect(assertion.isHeld == false)
        #expect(assertion.endCount == 1)
    }

    // MARK: - Driven through JobController

    @Test func assertionIsHeldWhileTheJobRunsAndReleasedOnSuccess() async throws {
        let gate = Gate()
        let assertion = FakeSleepAssertion()
        let controller = JobController(runner: { _, _, _, _, _, log, _, _ in
            log("▶ working")
            await gate.wait()
            return .succeeded(destination: Self.destination)
        }, sleepAssertion: assertion)
        Self.mount(controller, disc: Self.testDisc)

        #expect(assertion.isHeld == false)
        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()))
        #expect(assertion.isHeld == true)

        gate.open()
        try await waitUntilIdle(controller)

        #expect(assertion.isHeld == false)
        #expect(assertion.endCount == 1)
    }

    @Test func assertionIsReleasedOnFailure() async throws {
        let failure = JobFailure(stage: .encode,
                                 reason: .toolExited(code: 1),
                                 logTail: ["HandBrakeCLI: failed"])
        let assertion = FakeSleepAssertion()
        let controller = JobController(runner: { _, _, _, _, _, _, _, _ in .failed(failure) },
                                       sleepAssertion: assertion)
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(assertion.isHeld == false)
        #expect(assertion.endCount == 1)
        #expect(assertion.tokensTaken == 1)
    }

    @Test func beginIsNeverCalledWhenStartRefusesBecauseAJobIsAlreadyRunning() async throws {
        let gate = Gate()
        let assertion = FakeSleepAssertion()
        let controller = JobController(runner: { _, _, _, _, _, log, _, _ in
            log("▶ working")
            await gate.wait()
            return .succeeded(destination: Self.destination)
        }, sleepAssertion: assertion)
        Self.mount(controller, disc: Self.testDisc)

        let first = try Self.metadata()
        let second = try Self.metadata(id: 50456, title: "Hanna", releaseDate: "2011-03-08")

        #expect(controller.start(request: Self.request(first), settings: AppSettings()) == true)
        #expect(assertion.beginCount == 1)

        // Second start is refused while the first is in flight — must not
        // touch the assertion at all.
        #expect(controller.start(request: Self.request(second), settings: AppSettings()) == false)
        #expect(assertion.beginCount == 1)

        gate.open()
        try await waitUntilIdle(controller)
        #expect(assertion.isHeld == false)
    }

    @Test func beginIsNeverCalledWhenStartRefusesBecauseNoDiscIsMounted() throws {
        let assertion = FakeSleepAssertion()
        let controller = JobController(runner: { _, _, _, _, _, _, _, _ in
            .succeeded(destination: Self.destination)
        }, sleepAssertion: assertion)
        // Deliberately not mounted — `start` must refuse before ever
        // reaching the assertion.

        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()) == false)
        #expect(assertion.beginCount == 0)
        #expect(assertion.isHeld == false)
    }

    @Test func reasonStringNamesTheJob() async throws {
        let assertion = FakeSleepAssertion()
        let controller = JobController(runner: { _, _, _, _, _, _, _, _ in
            .succeeded(destination: Self.destination)
        }, sleepAssertion: assertion)
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(assertion.reasons == ["Changeover: encoding Blade Runner (1982)"])
    }
}
