import AppKit
import Foundation
import Testing
@testable import Changeover

/// Covers the app-level job state introduced by #0002: one job at a time, a log
/// that outlives the window that started it, and a stored terminal outcome.
///
/// The controller is driven through its injectable `Runner` seam, so none of
/// this needs `makemkvcon`, `HandBrakeCLI`, or a physical disc.
@MainActor
struct JobControllerTests {

    // MARK: - Helpers

    /// MovieMetadata is built from a TMDBMovie, so decode one rather than
    /// widening the production initializer just for tests.
    private static func metadata(
        id: Int = 78,
        title: String = "Blade Runner",
        releaseDate: String = "1982-06-25"
    ) throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static let destination = URL(fileURLWithPath:
        "/Volumes/Plex/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4")

    /// A one-shot latch. `open()` before `wait()` is fine — the waiter returns
    /// immediately — so tests don't depend on who gets there first.
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

    /// Records what the runner was asked to do.
    @MainActor
    private final class RunLog {
        private(set) var starts: [MovieMetadata] = []
        func record(_ metadata: MovieMetadata) { starts.append(metadata) }
    }

    /// Pumps the main actor until the controller goes idle, rather than sleeping.
    private func waitUntilIdle(_ controller: JobController,
                               iterations: Int = 100_000) async throws {
        var spins = 0
        while controller.isRunning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")
    }

    // MARK: - Outcome is stored on the controller

    @Test func succeededOutcomeIsStoredWhenTheJobFinishes() async throws {
        let controller = JobController(runner: { _, _, log in
            log("▶ ripping")
            log("✓ done")
            return .succeeded(destination: Self.destination)
        })

        #expect(controller.lastOutcome == nil)
        #expect(controller.start(metadata: try Self.metadata(), settings: AppSettings()))
        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome == .succeeded(destination: Self.destination))
        #expect(controller.lastOutcome?.destination == Self.destination)
        #expect(controller.logLines == ["▶ ripping", "✓ done"])
        #expect(controller.isRunning == false)
    }

    @Test func failedOutcomeIsStoredWithItsStageAndReason() async throws {
        let failure = JobFailure(stage: .rip,
                                 reason: .toolExited(code: 253),
                                 logTail: ["makemkvcon: bad disc"])
        let controller = JobController(runner: { _, _, _ in .failed(failure) })

        controller.start(metadata: try Self.metadata(), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.lastOutcome == .failed(failure))
        // A JobFailure carries its own stage — the controller adds no parallel
        // stage bookkeeping of its own.
        #expect(controller.lastOutcome?.failure?.stage == .rip)
        #expect(controller.lastOutcome?.failure?.reason == .toolExited(code: 253))
    }

    // MARK: - Re-entrancy guard

    /// The headline bug, state half: a second Start Ripping while a job is in
    /// flight must be refused. Per-view `isProcessing` could never do this — a
    /// freshly built view started at `false`.
    @Test func secondStartWhileRunningIsRefused() async throws {
        let gate = Gate()
        let runs = RunLog()
        let controller = JobController(runner: { metadata, _, log in
            runs.record(metadata)
            log("▶ started \(metadata.title)")
            await gate.wait()
            return .succeeded(destination: Self.destination)
        })

        let first = try Self.metadata()
        let second = try Self.metadata(id: 50456, title: "Hanna", releaseDate: "2011-03-08")

        #expect(controller.start(metadata: first, settings: AppSettings()) == true)
        // Let the task actually enter the runner and park on the gate.
        var spins = 0
        while runs.starts.isEmpty && spins < 100_000 { await Task.yield(); spins += 1 }
        try #require(!runs.starts.isEmpty, "runner never started")

        #expect(controller.isRunning == true)
        #expect(controller.start(metadata: second, settings: AppSettings()) == false)
        #expect(runs.starts.count == 1)
        #expect(controller.currentMetadata?.tmdbID == first.tmdbID)
        // The refusal is visible to the user rather than silent.
        #expect(controller.logLines.contains { $0.contains("already running") })

        gate.open()
        try await waitUntilIdle(controller)

        // Once it's idle, a new job is accepted again.
        #expect(controller.start(metadata: second, settings: AppSettings()) == true)
        try await waitUntilIdle(controller)
        #expect(runs.starts.count == 2)
    }

    /// The other half of the orphaning: whoever called `start` can go away —
    /// a closed window, a released view — and the job keeps running and keeps
    /// accumulating its log on the controller.
    @Test func jobKeepsRunningAfterTheStartingScopeGoesAway() async throws {
        let gate = Gate()
        let started = Gate()
        let controller = JobController(runner: { _, _, log in
            log("▶ line 1")
            started.open()
            await gate.wait()
            log("✓ line 2")
            return .succeeded(destination: Self.destination)
        })

        // Start from a scope that returns immediately, holding nothing.
        func transientCaller() throws {
            controller.start(metadata: try Self.metadata(), settings: AppSettings())
        }
        try transientCaller()

        await started.wait()
        #expect(controller.isRunning == true)
        #expect(controller.logLines == ["▶ line 1"])

        gate.open()
        try await waitUntilIdle(controller)
        #expect(controller.logLines == ["▶ line 1", "✓ line 2"])
        #expect(controller.lastOutcome?.destination == Self.destination)
    }

    // MARK: - Bounded log

    @Test func logLinesAreBoundedToTheConfiguredCap() async throws {
        let controller = JobController(maxLogLines: 5, runner: { _, _, log in
            for index in 1...50 { log("line \(index)") }
            return .succeeded(destination: Self.destination)
        })

        controller.start(metadata: try Self.metadata(), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.logLines.count == 5)
        #expect(controller.logLines == ["line 46", "line 47", "line 48", "line 49", "line 50"])
    }

    @Test func defaultLogCapIsBounded() {
        #expect(JobController.defaultMaxLogLines == 2000)
        let controller = JobController()
        #expect(controller.logLines.isEmpty)
    }

    @Test func logIsClearedAtTheStartOfEachJob() async throws {
        var lineToLog = "first job"
        let controller = JobController(runner: { _, _, log in
            log(lineToLog)
            return .succeeded(destination: Self.destination)
        })

        controller.start(metadata: try Self.metadata(), settings: AppSettings())
        try await waitUntilIdle(controller)
        #expect(controller.logLines == ["first job"])

        lineToLog = "second job"
        controller.start(metadata: try Self.metadata(), settings: AppSettings())
        try await waitUntilIdle(controller)
        #expect(controller.logLines == ["second job"])
        #expect(controller.lastOutcome != nil)
    }

    // MARK: - Job id (input to #0003)

    @Test func eachJobGetsAFreshFilesystemSafeID() async throws {
        let controller = JobController(runner: { _, _, _ in
            .succeeded(destination: Self.destination)
        })

        #expect(controller.currentJobID == nil)
        controller.start(metadata: try Self.metadata(), settings: AppSettings())
        let first = try #require(controller.currentJobID)
        try await waitUntilIdle(controller)

        controller.start(metadata: try Self.metadata(), settings: AppSettings())
        let second = try #require(controller.currentJobID)
        try await waitUntilIdle(controller)

        #expect(first != second)
        for id in [first, second] {
            #expect(!id.isEmpty)
            #expect(!id.contains("/"))
            #expect(!id.contains(":"))
            #expect(!id.contains(" "))
        }
    }

    @Test func jobIDEncodesItsTimestamp() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 11
        components.hour = 21
        components.minute = 30
        components.second = 5
        let date = try #require(Calendar.current.date(from: components))

        #expect(JobController.makeJobID(date: date).hasPrefix("job-20260911-213005-"))
    }

    // MARK: - Status surfacing

    @Test func statusDescriptionReportsTheRunningJob() async throws {
        let gate = Gate()
        let started = Gate()
        let controller = JobController(runner: { _, _, _ in
            started.open()
            await gate.wait()
            return .succeeded(destination: Self.destination)
        })

        #expect(controller.statusDescription == "Idle — insert a DVD to begin")

        controller.start(metadata: try Self.metadata(), settings: AppSettings())
        await started.wait()
        #expect(controller.statusDescription == "Working on Blade Runner…")

        gate.open()
        try await waitUntilIdle(controller)
        #expect(controller.statusDescription == "Idle — insert a DVD to begin")
    }
}

/// `JobController.insertedDiscURL` is only useful if something writes it, so the
/// monitor's volume URL is carried through the notification rather than dropped
/// (#0002 stores it; #0005 ejects it).
@MainActor
struct DVDMonitorVolumeURLTests {

    private func mountNotification(for url: URL) -> Notification {
        Notification(name: NSWorkspace.didMountNotification,
                     object: nil,
                     userInfo: [NSWorkspace.volumeURLUserInfoKey: url])
    }

    private func makeVolume(withVideoTS: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangeoverVolume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if withVideoTS {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("VIDEO_TS"),
                withIntermediateDirectories: true)
        }
        return root
    }

    @Test func aMountedDVDReportsItsVolumeURL() async throws {
        let volume = try makeVolume(withVideoTS: true)
        defer { try? FileManager.default.removeItem(at: volume) }

        let controller = JobController()
        let monitor = DVDMonitor()
        monitor.onDVDInserted = { url in controller.insertedDiscURL = url }

        monitor.volumeMounted(mountNotification(for: volume))

        var spins = 0
        while controller.insertedDiscURL == nil && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(controller.insertedDiscURL == volume)
    }

    @Test func aMountedVolumeWithoutVideoTSIsIgnored() async throws {
        let volume = try makeVolume(withVideoTS: false)
        defer { try? FileManager.default.removeItem(at: volume) }

        let controller = JobController()
        let monitor = DVDMonitor()
        monitor.onDVDInserted = { url in controller.insertedDiscURL = url }

        monitor.volumeMounted(mountNotification(for: volume))
        for _ in 0..<100 { await Task.yield() }

        #expect(controller.insertedDiscURL == nil)
    }
}
