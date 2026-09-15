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
    /// widening the production initializer just for tests. Bound to
    /// `testDisc`, the disc these tests mount, because `start` refuses
    /// metadata with no `selectionDisc` (#0034).
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

    /// Raw decode, for tests that need a `TMDBMovie` to build their own
    /// `MovieMetadata` (e.g. attaching a `selectionDisc`) rather than the
    /// one `metadata()` above produces.
    private static func decodeMovie(
        id: Int = 78,
        title: String = "Blade Runner",
        releaseDate: String = "1982-06-25"
    ) throws -> TMDBMovie {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(TMDBMovie.self, from: json)
    }

    /// #0027: `start` now takes a `RipRequest`, not a bare `MovieMetadata`.
    /// `featureTitleIndex`/`audioTrackNumbers` default to what `mount(_:disc:)`
    /// below puts on the scan (a single title, index 1, no streams) — every
    /// test that doesn't care about title/track resolution just needs
    /// `EncodeSelection.make` to succeed, which an empty track list satisfies
    /// vacuously.
    private static func request(
        _ metadata: MovieMetadata,
        featureTitleIndex: Int = 1,
        audioTrackNumbers: [Int] = []
    ) -> RipRequest {
        RipRequest(metadata: metadata, featureTitleIndex: featureTitleIndex, audioTrackNumbers: audioTrackNumbers)
    }

    private static let destination = URL(fileURLWithPath:
        "/Volumes/Plex/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4")

    /// #0014: `start` refuses to run without a mounted disc, so every test
    /// that drives a job through `start` needs one set first.
    private static let testDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
        deviceNode: "disk6",
        discID: "ceaaceba983071d9a7e28fd6107947b7")

    /// #0026: `start` also requires a completed scan holding a settled
    /// title. Most of these tests exercise the re-entrancy/disc-identity
    /// guards, not the scan pipeline itself, so this stands in for "the user
    /// already confirmed a title" — a single-title scan preselected exactly
    /// as `JobController.applyScanOutcome` would for a `.single` outcome.
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

    /// Puts `controller` in the state `start` requires: a disc mounted, plus
    /// #0026's completed-scan-with-a-settled-title gate satisfied. Safe to
    /// use even in tests whose refusal happens earlier in `start`'s guard
    /// chain (disc identity, missing `selectionDisc`) — the scan gate is
    /// never reached in those cases either way.
    private static func mount(_ controller: JobController, disc: DiscInsertion, titleIndex: Int = 1) {
        controller.insertedDisc = disc
        controller.scanState = Self.readyScanState(titleIndex: titleIndex)
        controller.selectTitle(titleIndex, settings: AppSettings())
    }

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
        let controller = JobController(runner: { context, _ in
            context.log("▶ ripping")
            context.log("✓ done")
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.lastOutcome == nil)
        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()))
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
        let controller = JobController(runner: { _, _ in .failed(failure) })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
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
        let controller = JobController(runner: { context, _ in
            runs.record(context.metadata)
            context.log("▶ started \(context.metadata.title)")
            await gate.wait()
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        let first = try Self.metadata()
        let second = try Self.metadata(id: 50456, title: "Hanna", releaseDate: "2011-03-08")

        #expect(controller.start(request: Self.request(first), settings: AppSettings()) == true)
        // Let the task actually enter the runner and park on the gate.
        var spins = 0
        while runs.starts.isEmpty && spins < 100_000 { await Task.yield(); spins += 1 }
        try #require(!runs.starts.isEmpty, "runner never started")

        #expect(controller.isRunning == true)
        #expect(controller.start(request: Self.request(second), settings: AppSettings()) == false)
        #expect(runs.starts.count == 1)
        #expect(controller.currentMetadata?.tmdbID == first.tmdbID)
        // The refusal is visible to the user rather than silent.
        #expect(controller.logLines.contains { $0.contains("already running") })

        gate.open()
        try await waitUntilIdle(controller)

        // Once it's idle, a new job is accepted again.
        #expect(controller.start(request: Self.request(second), settings: AppSettings()) == true)
        try await waitUntilIdle(controller)
        #expect(runs.starts.count == 2)
    }

    /// The other half of the orphaning: whoever called `start` can go away —
    /// a closed window, a released view — and the job keeps running and keeps
    /// accumulating its log on the controller.
    @Test func jobKeepsRunningAfterTheStartingScopeGoesAway() async throws {
        let gate = Gate()
        let started = Gate()
        let controller = JobController(runner: { context, _ in
            context.log("▶ line 1")
            started.open()
            await gate.wait()
            context.log("✓ line 2")
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        // Start from a scope that returns immediately, holding nothing.
        func transientCaller() throws {
            controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
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
        let controller = JobController(maxLogLines: 5, runner: { context, _ in
            for index in 1...50 { context.log("line \(index)") }
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.logLines.count == 5)
        #expect(controller.logLines == ["line 46", "line 47", "line 48", "line 49", "line 50"])
    }

    /// #0043 review: `logLines` is what the log area shows, so a milestone
    /// pushed out of the capped ring still appears — ahead of the surviving
    /// window — and the latest progress update appears once, in arrival
    /// order, instead of not at all.
    @Test func logLinesKeepAnEvictedMilestoneAheadOfTheCappedWindow() async throws {
        let controller = JobController(maxLogLines: 3, runner: { context, _ in
            context.log("── Starting: Blade Runner (1982)")
            for index in 1...10 { context.log("line \(index)") }
            context.log("Encoding: task 1 of 1, 50.00 %")
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.logLines == [
            "── Starting: Blade Runner (1982)",
            "line 8", "line 9", "line 10",
            "Encoding: task 1 of 1, 50.00 %",
        ])
    }

    @Test func defaultLogCapIsBounded() {
        #expect(JobController.defaultMaxLogLines == 2000)
        let controller = JobController()
        #expect(controller.logLines.isEmpty)
    }

    /// #0043: `logLines` (mirroring `currentLog`) still shows only the
    /// running/most-recently-started job's lines — same observable values as
    /// before this ticket for a single controller instance driven serially.
    /// What changed is that the *first* job's log is no longer destroyed
    /// when the second one starts; it's swapped out of `currentLog`, not
    /// wiped, and stays reachable through `retainedLog(forJobID:)`. Renamed
    /// from `logIsClearedAtTheStartOfEachJob`, which asserted the bug this
    /// ticket fixes.
    @Test func eachJobGetsAFreshLogAndThePreviousOnesLogIsRetained() async throws {
        var lineToLog = "first job"
        let controller = JobController(runner: { context, _ in
            context.log(lineToLog)
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)
        #expect(controller.logLines == ["first job"])
        let firstJobID = try #require(controller.currentJobID)

        lineToLog = "second job"
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)
        #expect(controller.logLines == ["second job"])
        #expect(controller.lastOutcome != nil)

        // The bug this ticket fixes: the first job's log used to be gone
        // the moment the second job started (`logLines = []`). It's still
        // here, by its own JobID.
        #expect(controller.retainedLog(forJobID: firstJobID)?.lines.map(\.text) == ["first job"])
    }

    // MARK: - Job id (input to #0003)

    @Test func eachJobGetsAFreshFilesystemSafeID() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.currentJobID == nil)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        let first = try #require(controller.currentJobID)
        try await waitUntilIdle(controller)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
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
        let controller = JobController(runner: { context, _ in
            started.open()
            await gate.wait()
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.statusDescription == "Idle — insert a DVD to begin")

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        await started.wait()
        #expect(controller.statusDescription == "Working on Blade Runner…")

        gate.open()
        try await waitUntilIdle(controller)
        #expect(controller.statusDescription == "Idle — insert a DVD to begin")
    }

    // MARK: - Disc required (#0014)

    /// The encode now reads the disc directly, so `start` forwards
    /// `insertedDisc.mountURL` into the runner as its third parameter.
    @Test func startForwardsTheInsertedDiscToTheRunner() async throws {
        final class DiscLog {
            private(set) var discs: [URL] = []
            func record(_ disc: URL) { discs.append(disc) }
        }
        let discLog = DiscLog()
        let controller = JobController(runner: { context, _ in
            discLog.record(context.disc)
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()) == true)
        try await waitUntilIdle(controller)

        #expect(discLog.discs == [Self.testDisc.mountURL])
    }

    /// With no disc mounted, `start` refuses exactly like the re-entrancy
    /// guard does — same `Bool` contract, and the reason is visible in the log.
    @Test func startRefusesWithNoDiscMounted() async throws {
        final class RunLog {
            private(set) var count = 0
            func record() { count += 1 }
        }
        let runs = RunLog()
        let controller = JobController(runner: { context, _ in
            runs.record()
            return fakeSuccess(context, destination: Self.destination)
        })

        #expect(controller.insertedDisc == nil)
        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()) == false)
        #expect(controller.isRunning == false)
        #expect(runs.count == 0)
        #expect(controller.logLines.contains { $0.contains("No disc is mounted") })
    }

    // MARK: - Selection/disc mismatch guard (#0034)

    /// The failsafe half of #0034: even if the UI-level reset in
    /// `MetadataEntryView` somehow didn't run, `start` itself refuses
    /// metadata selected for a disc other than the one actually mounted —
    /// this is what stops a stale selection from filing the new disc under
    /// the previous movie's name and overwriting it in Plex (#0012).
    @Test func startRefusesMetadataSelectedForADifferentDisc() async throws {
        let runs = RunLog()
        let controller = JobController(runner: { context, _ in
            runs.record(context.metadata)
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        let otherDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/OTHER_DISC"),
            deviceNode: "disk9",
            discID: "a-different-disc-id")
        let movie = try Self.decodeMovie()
        let staleMetadata = MovieMetadata(from: movie, selectionDisc: otherDisc)

        #expect(controller.start(request: Self.request(staleMetadata), settings: AppSettings()) == false)
        #expect(controller.isRunning == false)
        #expect(runs.starts.isEmpty)
        #expect(controller.logLines.contains { $0.contains("different disc") })
    }

    /// Reinserting the *same* disc (by identity) is a convenience, not a
    /// mismatch — mount path/device node can legitimately differ across a
    /// remount, so the guard must key off `discID` alone, same as
    /// `SelectionReset.sameDisc`.
    @Test func startAcceptsMetadataSelectedForTheSameDiscByIdentity() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        let sameDiscReinserted = DiscInsertion(
            mountURL: Self.testDisc.mountURL,
            deviceNode: "disk9",
            discID: Self.testDisc.discID)
        let movie = try Self.decodeMovie()
        let metadata = MovieMetadata(from: movie, selectionDisc: sameDiscReinserted)

        #expect(controller.start(request: Self.request(metadata), settings: AppSettings()) == true)
        try await waitUntilIdle(controller)
    }

    /// Fails closed: metadata that isn't bound to any disc is refused, so a
    /// call site that forgets to bind the selection can't reopen #0034.
    @Test func startRefusesMetadataWithNoSelectionDiscAttached() async throws {
        let runs = RunLog()
        let controller = JobController(runner: { context, _ in
            runs.record(context.metadata)
            return fakeSuccess(context, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        let unbound = MovieMetadata(from: try Self.decodeMovie())
        #expect(controller.start(request: Self.request(unbound), settings: AppSettings()) == false)
        #expect(controller.isRunning == false)
        #expect(runs.starts.isEmpty)
        #expect(controller.logLines.contains { $0.contains("isn't tied to a disc") })
    }

    /// No lsdvd and no volume name, so the disc has no identity. The movie
    /// was chosen on this very insertion, so Start must still work. A
    /// "unknown is never a match" rule on its own locked such discs out.
    @Test func startAcceptsAnUnknownIdentityDiscForTheInsertionItWasSelectedOn() async throws {
        let controller = JobController(runner: { context, _ in
            fakeSuccess(context, destination: Self.destination)
        })
        let unidentified = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/Untitled"),
            deviceNode: "disk6",
            discID: nil)
        Self.mount(controller, disc: unidentified)

        let metadata = MovieMetadata(from: try Self.decodeMovie(), selectionDisc: unidentified)
        #expect(controller.start(request: Self.request(metadata), settings: AppSettings()) == true)
        try await waitUntilIdle(controller)
    }

    /// An unidentifiable disc swapped for another that mounts at the same
    /// path and device node is still a different insertion, so it's refused.
    @Test func startRefusesAnUnknownIdentityLookalikeFromAnotherInsertion() async throws {
        let runs = RunLog()
        let controller = JobController(runner: { context, _ in
            runs.record(context.metadata)
            return fakeSuccess(context, destination: Self.destination)
        })
        let selectedOn = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/Untitled"),
            deviceNode: "disk6",
            discID: nil)
        controller.insertedDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/Untitled"),
            deviceNode: "disk6",
            discID: nil)

        let metadata = MovieMetadata(from: try Self.decodeMovie(), selectionDisc: selectedOn)
        #expect(controller.start(request: Self.request(metadata), settings: AppSettings()) == false)
        #expect(runs.starts.isEmpty)
        #expect(controller.logLines.contains { $0.contains("different disc") })
    }
}

/// Covers #0026's wiring: a disc insertion starts a HandBrake scan, the
/// scan's outcome is applied through `DiscTitleHeuristic.classify` (a
/// `.single` outcome preselects; `.playAll`/`.none` leave the choice to the
/// user), a scan failure is held as itself, and `start` refuses to run
/// without a settled title that actually belongs to the scan it holds.
///
/// Driven entirely through the injectable `ScanRunner`/`Runner` seams — no
/// disc, no `HandBrakeCLI`.
@MainActor
struct JobControllerScanTests {

    // MARK: - Helpers

    private static let testDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
        deviceNode: "disk6",
        discID: "ceaaceba983071d9a7e28fd6107947b7")

    private static func title(_ index: Int, _ durationSeconds: Int, chapters: Int = 10) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: durationSeconds, chapterCount: chapters,
                  sizeBytes: 1_000_000_000, outputFileName: nil)
    }

    /// A one-shot latch, same shape as `JobControllerTests`' private `Gate`
    /// — duplicated rather than shared across the two test structs, which
    /// stay independent on purpose.
    @MainActor
    private final class ScanGate {
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

    /// Pumps the main actor until `scanState` leaves `.scanning`.
    private func waitUntilScanned(_ controller: JobController, iterations: Int = 100_000) async throws {
        var spins = 0
        while controller.scanState == .scanning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(controller.scanState != .scanning, "scan never finished")
    }

    // MARK: - insertDisc starts a scan

    @Test func insertDiscStartsAScanThatPreselectsASingleFeature() async throws {
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6",
                            titles: [Self.title(1, 6645, chapters: 21)])
        let controller = JobController(scanRunner: { _, _, _, _, _ in
            .success(DiscScanner.Result(disc: disc, mainFeatureIndex: 1, warnings: []))
        })

        #expect(controller.scanState == .idle)
        controller.insertDisc(Self.testDisc, settings: AppSettings())
        #expect(controller.scanState == .scanning)
        try await waitUntilScanned(controller)

        #expect(controller.scanState == .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: 1, warnings: [])))
        #expect(controller.selectedTitleIndex == 1)
    }

    @Test func aPlayAllOutcomeLeavesNothingSelected() async throws {
        // Eight ~21-minute episodes (1256s) clustering to the long title's
        // duration, the Brooklyn Nine-Nine shape #0025's guard is built on.
        let episodes = (1...8).map { Self.title($0, 1256) }
        let longTitle = Self.title(9, episodes.reduce(0) { $0 + $1.durationSeconds }, chapters: 33)
        let disc = DiscInfo(volumeName: "TV", driveName: "disk6", titles: episodes + [longTitle])
        let controller = JobController(scanRunner: { _, _, _, _, _ in
            .success(DiscScanner.Result(disc: disc, mainFeatureIndex: 9, warnings: []))
        })

        controller.insertDisc(Self.testDisc, settings: AppSettings())
        try await waitUntilScanned(controller)

        guard case .scanned = controller.scanState else {
            Issue.record("expected .scanned")
            return
        }
        #expect(controller.selectedTitleIndex == nil)
    }

    @Test func noFeatureIdentifiedLeavesNothingSelected() async throws {
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [Self.title(1, 120)])
        let controller = JobController(scanRunner: { _, _, _, _, _ in
            .success(DiscScanner.Result(disc: disc, mainFeatureIndex: nil, warnings: []))
        })

        controller.insertDisc(Self.testDisc, settings: AppSettings())
        try await waitUntilScanned(controller)

        #expect(controller.selectedTitleIndex == nil)
    }

    // MARK: - Failure is held as itself (#0024's exit criterion, rendered by #0026)

    @Test func aFailedScanIsHeldAsAFailureNotAnEmptyScan() async throws {
        let controller = JobController(scanRunner: { _, _, _, _, _ in
            .failure(.toolExited(code: 1))
        })

        controller.insertDisc(Self.testDisc, settings: AppSettings())
        try await waitUntilScanned(controller)

        #expect(controller.scanState == .failed(.toolExited(code: 1)))
        #expect(controller.selectedTitleIndex == nil)
    }

    @Test func startScanWithNoDiscDoesNothing() {
        let controller = JobController()
        #expect(controller.startScan(settings: AppSettings()) == false)
        #expect(controller.scanState == .idle)
    }

    // MARK: - A disc swap mid-scan discards the superseded result

    @Test func aDiscRemovedWhileScanningDiscardsTheStaleResult() async throws {
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [Self.title(1, 6645)])
        let gate = ScanGate()
        let controller = JobController(scanRunner: { _, _, _, _, _ in
            await gate.wait()
            return .success(DiscScanner.Result(disc: disc, mainFeatureIndex: 1, warnings: []))
        })

        controller.insertDisc(Self.testDisc, settings: AppSettings())
        #expect(controller.scanState == .scanning)

        controller.removeDisc()
        #expect(controller.scanState == .idle)

        gate.open()
        // Give the in-flight scan's continuation a chance to land, if it
        // were (wrongly) going to.
        for _ in 0..<1000 { await Task.yield() }

        #expect(controller.scanState == .idle)
        #expect(controller.insertedDisc == nil)
    }

    // MARK: - removeDisc clears everything

    @Test func removeDiscClearsScanAndSelectionState() {
        let controller = JobController()
        controller.insertedDisc = Self.testDisc
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [Self.title(1, 6645)]),
            mainFeatureIndex: 1, warnings: []))
        controller.selectTitle(1, settings: AppSettings())
        controller.acknowledgeMismatch(titleIndex: 1, movieID: 78)

        controller.removeDisc()

        #expect(controller.insertedDisc == nil)
        #expect(controller.scanState == .idle)
        #expect(controller.selectedTitleIndex == nil)
        #expect(controller.selectedAudioTrackNumbers == [])
        #expect(controller.mismatchAcknowledgement == nil)
    }

    // MARK: - A superseded scan of the same insertion is discarded (review)

    /// A Rescan of the same insertion passes the disc check, so only the
    /// generation token stops the older scan, finishing last, from replacing
    /// the newer result and its preselection.
    @Test func anOlderScanOfTheSameInsertionFinishingLastIsDiscarded() async throws {
        let first = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [Self.title(1, 6645)])
        let second = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [Self.title(2, 6645)])
        let firstGate = ScanGate()
        let secondGate = ScanGate()
        final class CallCount { var value = 0 }
        let calls = CallCount()
        let controller = JobController(scanRunner: { _, _, _, _, _ in
            calls.value += 1
            if calls.value == 1 {
                await firstGate.wait()
                return .success(DiscScanner.Result(disc: first, mainFeatureIndex: 1, warnings: []))
            }
            await secondGate.wait()
            return .success(DiscScanner.Result(disc: second, mainFeatureIndex: 2, warnings: []))
        })

        controller.insertDisc(Self.testDisc, settings: AppSettings())
        controller.startScan(settings: AppSettings())
        var spins = 0
        while calls.value < 2 && spins < 100_000 { await Task.yield(); spins += 1 }
        try #require(calls.value == 2)

        secondGate.open()
        try await waitUntilScanned(controller)
        #expect(controller.selectedTitleIndex == 2)

        firstGate.open()
        for _ in 0..<1000 { await Task.yield() }

        #expect(controller.scanState == .scanned(DiscScanner.Result(disc: second, mainFeatureIndex: 2, warnings: [])))
        #expect(controller.selectedTitleIndex == 2)
    }

    // MARK: - The mismatch acknowledgement

    @Test func acknowledgeMismatchRecordsTitleAndMovieAndSelectingATitleClearsIt() {
        let controller = JobController()
        controller.acknowledgeMismatch(titleIndex: 1, movieID: 78)
        #expect(controller.mismatchAcknowledgement == MismatchAcknowledgement(titleIndex: 1, movieID: 78))

        controller.selectTitle(3, settings: AppSettings())
        #expect(controller.mismatchAcknowledgement == nil)
    }

    // MARK: - start's scan/title/track gate (#0026/#0027)

    private static func metadata(selectionDisc: DiscInsertion?) throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json), selectionDisc: selectionDisc)
    }

    /// #0027: `start` now takes a `RipRequest` and resolves it against the
    /// scan via `EncodeSelection.make(request:disc:)` — it no longer reads
    /// `JobController.selectedTitleIndex` at all. `featureTitleIndex`/
    /// `audioTrackNumbers` default to a title-1, no-audio-tracks request,
    /// which `EncodeSelection.make` accepts vacuously when `disc` really
    /// does have a title 1 (an empty track list falls back to
    /// `.sourceDefault` downstream, not a rejection).
    private static func request(
        selectionDisc: DiscInsertion?,
        featureTitleIndex: Int = 1,
        audioTrackNumbers: [Int] = []
    ) throws -> RipRequest {
        RipRequest(
            metadata: try Self.metadata(selectionDisc: selectionDisc),
            featureTitleIndex: featureTitleIndex,
            audioTrackNumbers: audioTrackNumbers
        )
    }

    @Test func startRefusesWithoutACompletedScan() async throws {
        let controller = JobController(runner: { context, _ in fakeSuccess(context, destination: URL(fileURLWithPath: "/x")) })
        controller.insertedDisc = Self.testDisc
        // scanState stays .idle — no scan has ever run.

        #expect(controller.start(request: try Self.request(selectionDisc: Self.testDisc), settings: AppSettings()) == false)
        #expect(controller.logLines.contains { $0.contains("No completed disc scan") })
    }

    /// The request names a `featureTitleIndex` that isn't a title on the
    /// scan currently held — `EncodeSelection.make` returns `nil` and
    /// `start` refuses, the same enforcement whether the mismatch is because
    /// nothing was ever selected in the UI or because the scan changed out
    /// from under a stale request.
    @Test func startRefusesARequestWhoseFeatureTitleIndexIsNotOnTheHeldScan() async throws {
        let controller = JobController(runner: { context, _ in fakeSuccess(context, destination: URL(fileURLWithPath: "/x")) })
        controller.insertedDisc = Self.testDisc
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [Self.title(1, 6645)]),
            mainFeatureIndex: 1, warnings: []))

        #expect(controller.start(request: try Self.request(selectionDisc: Self.testDisc, featureTitleIndex: 99), settings: AppSettings()) == false)
        #expect(controller.logLines.contains { $0.contains("don't match the current disc scan") })
    }

    /// Same enforcement, the other axis: the title is real but an audio
    /// track number on the request isn't one of its streams — e.g. a track
    /// number left over from a superseded scan of a different disc.
    @Test func startRefusesARequestWhoseAudioTrackNumberIsNotOnTheHeldScan() async throws {
        let controller = JobController(runner: { context, _ in fakeSuccess(context, destination: URL(fileURLWithPath: "/x")) })
        controller.insertedDisc = Self.testDisc
        let scannedTitle = DiscTitle(
            index: 1, durationSeconds: 6645, chapterCount: 21, sizeBytes: 6_300_000_000, outputFileName: nil,
            streams: [DiscStream(index: 1, kind: .audio, codecId: "A_AC3", languageCode: "eng")]
        )
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [scannedTitle]),
            mainFeatureIndex: 1, warnings: []))

        #expect(controller.start(request: try Self.request(selectionDisc: Self.testDisc, audioTrackNumbers: [9]), settings: AppSettings()) == false)
        #expect(controller.logLines.contains { $0.contains("don't match the current disc scan") })
    }

    /// #0027 review: an empty track list resolves in `EncodeSelection.make`,
    /// but on a title with audio it would encode the first track while the
    /// picker shows nothing checked. `start` refuses it and never runs the
    /// runner.
    @Test func startRefusesAnEmptyAudioSelectionOnATitleWithAudio() async throws {
        final class RunCount { var value = 0 }
        let runs = RunCount()
        let controller = JobController(runner: { context, _ in
            runs.value += 1
            return fakeSuccess(context, destination: URL(fileURLWithPath: "/x"))
        })
        controller.insertedDisc = Self.testDisc
        let scannedTitle = DiscTitle(
            index: 1, durationSeconds: 6645, chapterCount: 21, sizeBytes: 6_300_000_000, outputFileName: nil,
            streams: [DiscStream(index: 1, kind: .audio, codecId: "A_AC3", languageCode: "eng")]
        )
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [scannedTitle]),
            mainFeatureIndex: 1, warnings: []))

        #expect(controller.start(request: try Self.request(selectionDisc: Self.testDisc, audioTrackNumbers: []), settings: AppSettings()) == false)
        #expect(controller.isRunning == false)
        #expect(runs.value == 0)
        #expect(controller.logLines.contains { $0.contains("No audio track selected") })
    }

    @Test func startPassesTheResolvedSelectionToTheRunner() async throws {
        final class SelectionLog {
            private(set) var selections: [EncodeSelection] = []
            func record(_ selection: EncodeSelection) { selections.append(selection) }
        }
        let log = SelectionLog()
        let controller = JobController(runner: { context, _ in
            log.record(context.selection)
            return fakeSuccess(context, destination: URL(fileURLWithPath: "/x"))
        })
        controller.insertedDisc = Self.testDisc
        let scannedTitle = DiscTitle(
            index: 7, durationSeconds: 500, chapterCount: 5, sizeBytes: 1_000_000_000, outputFileName: nil,
            streams: [
                DiscStream(index: 1, kind: .audio, codecId: "A_AC3", languageCode: "eng"),
                DiscStream(index: 4, kind: .audio, codecId: "A_AC3", languageCode: "fra"),
            ]
        )
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [Self.title(1, 6645), scannedTitle]),
            mainFeatureIndex: 1, warnings: []))

        let request = try Self.request(selectionDisc: Self.testDisc, featureTitleIndex: 7, audioTrackNumbers: [1, 4])
        #expect(controller.start(request: request, settings: AppSettings()) == true)
        var spins = 0
        while log.selections.isEmpty && spins < 100_000 { await Task.yield(); spins += 1 }

        #expect(log.selections == [EncodeSelection.make(request: request, disc: DiscInfo(
            volumeName: "TEST", driveName: "disk6", titles: [Self.title(1, 6645), scannedTitle]
        ))])
        #expect(log.selections.first?.title == .index(7))
        #expect(log.selections.first?.audio == .tracks([1, 4]))
    }

    // MARK: - #0031 extras selection

    private static let extrasDisc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [
        Self.title(1, 6645), Self.title(2, 300), Self.title(3, 400), Self.title(5, 500),
    ])

    @Test func startPassesTheResolvedExtrasPlanToTheRunner() async throws {
        final class PlanLog {
            private(set) var plans: [ExtrasPlan] = []
            func record(_ plan: ExtrasPlan) { plans.append(plan) }
        }
        let log = PlanLog()
        let controller = JobController(runner: { context, _ in
            log.record(context.extras)
            return fakeSuccess(context, destination: URL(fileURLWithPath: "/x"))
        })
        controller.insertedDisc = Self.testDisc
        controller.scanState = .scanned(DiscScanner.Result(disc: Self.extrasDisc, mainFeatureIndex: 1, warnings: []))

        // The feature, an unknown index and a duplicate are all in the
        // request; only 3 and 5, ascending, may reach the runner.
        let request = RipRequest(
            metadata: try Self.metadata(selectionDisc: Self.testDisc),
            featureTitleIndex: 1,
            extraTitleIndices: [5, 1, 99, 3, 3],
            audioTrackNumbers: []
        )
        #expect(controller.start(request: request, settings: AppSettings()) == true)
        var spins = 0
        while log.plans.isEmpty && spins < 100_000 { await Task.yield(); spins += 1 }

        #expect(log.plans.map { $0.items.map(\.titleIndex) } == [[3, 5]])
    }

    @Test func extrasSelectionNeverHoldsTheFeatureAndMatchesThePlan() {
        let controller = JobController()
        controller.insertedDisc = Self.testDisc
        controller.scanState = .scanned(DiscScanner.Result(disc: Self.extrasDisc, mainFeatureIndex: 1, warnings: []))
        controller.selectTitle(1, settings: AppSettings())

        controller.toggleExtra(1)
        #expect(controller.selectedExtraTitleIndices.isEmpty)

        controller.toggleExtra(3)
        controller.toggleExtra(2)
        #expect(controller.selectedExtraTitleIndices == [2, 3])
        controller.toggleExtra(2)
        #expect(controller.selectedExtraTitleIndices == [3])
        controller.toggleExtra(5)
        #expect(controller.selectedExtrasPlan.items.map(\.titleIndex) == [3, 5])
        #expect(controller.selectedExtrasPlan.totalDurationSeconds == 900)

        // Picking an extra as the feature drops just that index.
        controller.selectTitle(3, settings: AppSettings())
        #expect(controller.selectedTitleIndex == 3)
        #expect(controller.selectedExtraTitleIndices == [5])
        #expect(controller.selectedExtrasPlan.items.map(\.titleIndex) == [5])
    }

    @Test func extrasSelectionIsClearedOnRemovalAndOnRescan() async throws {
        let controller = JobController(scanRunner: { _, _, _, _, _ in
            .success(DiscScanner.Result(disc: Self.extrasDisc, mainFeatureIndex: 1, warnings: []))
        })
        controller.insertDisc(Self.testDisc, settings: AppSettings())
        try await waitUntilScanned(controller)
        controller.toggleExtra(3)
        #expect(controller.selectedExtraTitleIndices == [3])

        controller.startScan(settings: AppSettings())
        #expect(controller.selectedExtraTitleIndices.isEmpty)
        try await waitUntilScanned(controller)

        controller.toggleExtra(2)
        #expect(controller.selectedExtraTitleIndices == [2])
        controller.removeDisc()
        #expect(controller.selectedExtraTitleIndices.isEmpty)
        #expect(controller.selectedExtrasPlan.items.isEmpty)
    }
}

/// `JobController.insertedDisc` is only useful if something writes it. The
/// monitor's classification and identity logic now live in
/// `OpticalDiscClassifier`/`DVDMonitor` — see `DVDMonitorTests.swift` (#0013).
/// This just covers that a `DiscInsertion` handed to `onDVDInserted` lands on
/// the controller and clears on `onDVDRemoved`.
@MainActor
struct DVDMonitorWiringTests {

    @Test func insertedDiscIsStoredAndClearedOnRemoval() {
        let controller = JobController()
        let monitor = DVDMonitor()
        monitor.onDVDInserted = { insertion in controller.insertedDisc = insertion }
        monitor.onDVDRemoved = { controller.insertedDisc = nil }

        #expect(controller.insertedDisc == nil)

        let insertion = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            deviceNode: "disk6",
            discID: "ceaaceba983071d9a7e28fd6107947b7")
        monitor.onDVDInserted?(insertion)
        #expect(controller.insertedDisc == insertion)

        monitor.onDVDRemoved?()
        #expect(controller.insertedDisc == nil)
    }
}
