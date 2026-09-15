import Foundation
import Testing
@testable import Changeover

/// Covers #0045's manual "Eject Disc" action on `JobController`. Every test
/// drives `ejectDisc()` through the injectable `Ejector` seam with a
/// recording fake — never `DiscEjector.eject`, which would touch real
/// `DiskArbitration`. `EjectPolicyTests` covers the underlying decision table
/// in isolation; these tests cover the controller wiring around it: the
/// ejector is never called on a refusal, `insertedDisc` is left for the real
/// `DVDMonitor.onDVDRemoved` path to clear, and every outcome is logged.
@MainActor
struct JobControllerEjectTests {

    // MARK: - Helpers (mirrors JobControllerTests' / PowerAssertionTests' fixtures)

    // #0050: the recording fake ejector these tests share is
    // `RecordingEjector`, in `FakeRunnerSupport.swift` — this suite used to
    // keep its own private `FakeEjector` with the same shape.

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

    // MARK: - Refusals

    @Test func ejectDiscRefusesWithNoDiscMounted() async {
        let ejector = RecordingEjector()
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        // Deliberately not mounted.

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(ejector.calls.isEmpty)
        #expect(controller.logLines.contains("⚠︎ No disc is mounted."))
    }

    @Test func ejectDiscRefusesWhileAJobIsRunning() async throws {
        let gate = Gate()
        let ejector = RecordingEjector()
        let controller = JobController(runner: { context, _ in
            context.log("▶ working")
            await gate.wait()
            return fakeSuccess(context, destination: Self.destination)
        }, ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()))
        #expect(controller.isRunning == true)

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(ejector.calls.isEmpty)
        #expect(controller.logLines.contains("⚠︎ A job is running — wait for it to finish before ejecting."))
        // The running job is never disturbed by the refused eject.
        #expect(controller.isRunning == true)

        gate.open()
        var spins = 0
        while controller.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(controller.isRunning == false)
    }

    // MARK: - Outcomes

    @Test func ejectDiscSucceedsAndCallsTheEjectorWithTheMountedVolume() async {
        let ejector = RecordingEjector()
        ejector.outcome = .ejected
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        let result = await controller.ejectDisc()

        #expect(result == true)
        #expect(ejector.calls == [Self.testDisc.mountURL])
        #expect(controller.logLines.contains("Disc ejected."))
    }

    @Test func ejectDiscDoesNotClearInsertedDiscItself() async {
        // Removal happens through the real `DVDMonitor.onDVDRemoved` →
        // `AppDelegate.jobs.removeDisc()` path, not from `ejectDisc()`
        // directly — clearing it here would race the real disappearance
        // notification.
        let ejector = RecordingEjector()
        ejector.outcome = .ejected
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        _ = await controller.ejectDisc()

        #expect(controller.insertedDisc == Self.testDisc)
    }

    @Test func ejectDiscReportsABusyFailureAndDoesNotClaimSuccess() async {
        let ejector = RecordingEjector()
        ejector.outcome = .busy(message: "Could not eject the disc — it's still in use: resource busy.")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(controller.logLines.contains("⚠︎ Could not eject the disc — it's still in use: resource busy."))
        #expect(controller.isEjecting == false)
    }

    @Test func ejectDiscReportsAGenericFailure() async {
        let ejector = RecordingEjector()
        ejector.outcome = .failed(message: "Could not eject the disc: status -119930868.")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(controller.logLines.contains("⚠︎ Could not eject the disc: status -119930868."))
        // A failed eject leaves the disc usable: Eject can be tried again.
        #expect(controller.isEjecting == false)
    }

    // MARK: - #0045 review: scan and in-flight eject

    private final class ScanCounter {
        var calls = 0
    }

    /// #0051: a scan no longer refuses the eject outright — `ejectDisc()`
    /// cancels it and waits. But if a scan is *still* running after that
    /// (here `scanState` is hand-set with no scan `Task` behind it, so
    /// nothing can settle it), the eject must still refuse, never run under
    /// the scan, and must not leave `isEjecting` stuck on.
    @Test func ejectDiscStillRefusesIfTheScanIsStillRunningAfterTheCancel() async {
        let ejector = RecordingEjector()
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        controller.insertedDisc = Self.testDisc
        controller.scanState = .scanning

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(ejector.calls.isEmpty)
        #expect(controller.logLines.contains("Cancelling the scan to eject…"))
        #expect(controller.logLines.contains("⚠︎ \(EjectPolicy.scanStillRunningReason)"))
        #expect(controller.scanState == .scanning)
        #expect(controller.insertedDisc == Self.testDisc)
        #expect(controller.isEjecting == false)
    }

    /// Once the scan has settled, even as a failure, the disc can be ejected.
    @Test func ejectDiscIsAllowedAfterAFailedScan() async {
        let ejector = RecordingEjector()
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        controller.insertedDisc = Self.testDisc
        controller.scanState = .failed(.jsonMissing)

        #expect(await controller.ejectDisc() == true)
        #expect(ejector.calls == [Self.testDisc.mountURL])
    }

    /// While the eject is in flight, a second Eject, a Start and a Rescan
    /// are all refused, and none of them reach the ejector, the runner or
    /// the scanner.
    @Test func ejectStartAndRescanAreRefusedWhileAnEjectIsInFlight() async throws {
        let gate = Gate()
        let ejector = RecordingEjector()
        let scans = ScanCounter()
        let controller = JobController(
            runner: { context, _ in
                Issue.record("the runner must not be invoked while ejecting")
                return fakeSuccess(context, destination: Self.destination)
            },
            scanRunner: { _, _, _, _, _ in
                scans.calls += 1
                return .failure(.jsonMissing)
            },
            ejector: { url in
                await gate.wait()
                return await ejector.eject(url)
            })
        Self.mount(controller, disc: Self.testDisc)

        let first = Task { await controller.ejectDisc() }
        var spins = 0
        while !controller.isEjecting && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(controller.isEjecting == true)

        #expect(await controller.ejectDisc() == false)
        #expect(controller.logLines.contains("⚠︎ The disc is already being ejected."))
        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()) == false)
        #expect(controller.logLines.contains("⚠︎ The disc is being ejected — insert a DVD before starting."))
        #expect(controller.startScan(settings: AppSettings()) == false)

        gate.open()
        #expect(await first.value == true)
        #expect(ejector.calls == [Self.testDisc.mountURL])
        #expect(controller.isRunning == false)
        #expect(scans.calls == 0)
    }

    /// After a successful eject, `insertedDisc` still names the departed disc
    /// until `DVDMonitor`'s removal reaches `removeDisc()`. Start stays
    /// refused in that gap, and the removal clears everything.
    @Test func aSuccessfulEjectKeepsStartRefusedUntilTheRemovalLands() async throws {
        let ejector = RecordingEjector()
        let controller = JobController(
            runner: { context, _ in
                Issue.record("the runner must not be invoked on an ejected disc")
                return fakeSuccess(context, destination: Self.destination)
            },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        #expect(await controller.ejectDisc() == true)
        #expect(controller.isEjecting == true)
        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()) == false)

        // What `AppDelegate`'s `onDVDRemoved` handler calls.
        controller.removeDisc()

        #expect(controller.isEjecting == false)
        #expect(controller.insertedDisc == nil)
        #expect(controller.scanState == .idle)
    }

    /// A new insertion also clears the flag, so the next disc is never
    /// blocked by the previous one's eject.
    @Test func aNewInsertionClearsTheEjectingFlag() async {
        let ejector = RecordingEjector()
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in .failure(.jsonMissing) },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        #expect(await controller.ejectDisc() == true)
        #expect(controller.isEjecting == true)

        controller.insertDisc(Self.testDisc, settings: AppSettings())

        #expect(controller.isEjecting == false)
        #expect(controller.scanState == .scanning)
    }

    // MARK: - #0049: unmounted but not ejected

    /// The bug this ticket fixes: the unmount succeeded but the physical
    /// eject then failed, leaving the disc unmounted but still in the
    /// drive. `discUnavailable` records that; `isEjecting` clears so the
    /// user can retry the eject itself; `insertedDisc` is left alone
    /// (there is no removal event to react to).
    @Test func anUnmountedButNotEjectedOutcomeMarksTheDiscUnavailable() async {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(controller.isEjecting == false)
        #expect(controller.discUnavailable == true)
        #expect(controller.insertedDisc == Self.testDisc)
        #expect(controller.logLines.contains("⚠︎ the tray did not open"))
    }

    /// Start is refused, with a clear reason, once the disc is marked
    /// unavailable — never left live against a dead mount path.
    @Test func startIsRefusedAfterAnUnmountedButNotEjectedResult() async throws {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let controller = JobController(
            runner: { context, _ in
                Issue.record("the runner must not be invoked on an unmounted-but-not-ejected disc")
                return fakeSuccess(context, destination: Self.destination)
            },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        let started = controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())

        #expect(started == false)
        #expect(controller.isRunning == false)
        #expect(controller.logLines.contains(
            "⚠︎ The disc was unmounted but could not be ejected — retry Eject or remove the disc before starting."))
    }

    /// Rescan is refused the same way.
    @Test func rescanIsRefusedAfterAnUnmountedButNotEjectedResult() async {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let scans = ScanCounter()
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in
                scans.calls += 1
                return .failure(.jsonMissing)
            },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        let rescanned = controller.startScan(settings: AppSettings())

        #expect(rescanned == false)
        #expect(scans.calls == 0)
    }

    /// `JobController.retryDecision` refuses the same way — the #0048
    /// handoff note this ticket closes: Retry must not stay enabled on a
    /// dead mount path either.
    @Test func retryIsRefusedAfterAnUnmountedButNotEjectedResult() async throws {
        let ejector = RecordingEjector()
        let controller = JobController(
            runner: { context, _ in
                context.phase(.encoding)
                return .failed(JobFailure(stage: .encode, reason: .diskFull))
            },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        let request = Self.request(try Self.metadata())
        #expect(controller.start(request: request, settings: AppSettings()))
        var spins = 0
        while controller.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        let failedID = try #require(controller.history.last?.id)
        #expect(controller.retryDecision(id: failedID) == .retry)

        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        let decision = controller.retryDecision(id: failedID)
        #expect(decision != .retry)
        #expect(decision.refusalReason?.contains("unmounted but could not be ejected") == true)
    }

    /// A later successful eject — the user retrying Eject from the disabled
    /// state — clears `discUnavailable`, per the plan's third clearing
    /// trigger (a removal and a new insertion are covered by the two tests
    /// above/below).
    @Test func aLaterSuccessfulEjectClearsDiscUnavailable() async {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        ejector.outcome = .ejected
        let result = await controller.ejectDisc()

        #expect(result == true)
        #expect(controller.discUnavailable == false)
    }

    /// A removal (the real `DVDMonitor.onDVDRemoved` path) also clears it.
    @Test func removeDiscClearsDiscUnavailable() async {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        controller.removeDisc()

        #expect(controller.discUnavailable == false)
    }

    /// A new insertion also clears it, mirroring `aNewInsertionClearsTheEjectingFlag`.
    @Test func insertDiscClearsDiscUnavailable() async {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in .failure(.jsonMissing) },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        controller.insertDisc(Self.testDisc, settings: AppSettings())

        #expect(controller.discUnavailable == false)
    }

    /// Eject itself stays enabled/offered while the disc is unavailable —
    /// `EjectPolicy` never looks at `discUnavailable`, only `isEjecting`
    /// (which the unmounted-but-not-ejected outcome already clears), so a
    /// retry of the eject is exactly what's on offer.
    @Test func ejectRemainsAvailableWhileDiscUnavailable() async {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        let decision = EjectPolicy.decide(
            isRunning: controller.isRunning,
            isScanning: controller.scanState == .scanning,
            isEjecting: controller.isEjecting,
            hasDisc: controller.insertedDisc != nil)

        #expect(decision == .eject)
    }

    // MARK: - #0049 review: automatic eject and remount

    /// The #0005 automatic end-of-job eject is the most common eject path.
    /// A partial result there, reported through `JobContext.eject` the way
    /// `DVDPipeline.run()` reports it, must mark the disc unavailable just
    /// like a manual one: Start and Rescan refused afterwards.
    @Test func anAutomaticEndOfJobPartialEjectMarksTheDiscUnavailable() async throws {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let scans = ScanCounter()
        var runs = 0
        let controller = JobController(
            runner: { context, _ in
                runs += 1
                _ = await context.eject(context.disc)
                return fakeSuccess(context, destination: Self.destination)
            },
            scanRunner: { _, _, _, _, _ in
                scans.calls += 1
                return .failure(.jsonMissing)
            },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        let request = Self.request(try Self.metadata())

        #expect(controller.start(request: request, settings: AppSettings()))
        var spins = 0
        while controller.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(controller.isRunning == false)
        #expect(ejector.calls == [Self.testDisc.mountURL])
        #expect(controller.discUnavailable == true)
        #expect(controller.insertedDisc == Self.testDisc)

        #expect(controller.start(request: request, settings: AppSettings()) == false)
        #expect(controller.logLines.contains(
            "⚠︎ The disc was unmounted but could not be ejected — retry Eject or remove the disc before starting."))
        #expect(controller.startScan(settings: AppSettings()) == false)
        #expect(runs == 1)
        #expect(scans.calls == 0)
    }

    /// A successful automatic eject leaves `discUnavailable` alone.
    @Test func anAutomaticEndOfJobSuccessfulEjectLeavesTheDiscAvailable() async throws {
        let ejector = RecordingEjector()
        ejector.outcome = .ejected
        let controller = JobController(
            runner: { context, _ in
                _ = await context.eject(context.disc)
                return fakeSuccess(context, destination: Self.destination)
            },
            ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.start(request: Self.request(try Self.metadata()), settings: AppSettings()))
        var spins = 0
        while controller.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(ejector.calls == [Self.testDisc.mountURL])
        #expect(controller.discUnavailable == false)
    }

    /// The same disc remounted in place (no disappearance, so no
    /// `insertDisc`) clears `discUnavailable`, takes the new mount path and
    /// keeps the insertion's id so the movie selection still matches.
    @Test func aRemountOfTheSameDiscClearsDiscUnavailable() async {
        let ejector = RecordingEjector()
        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        let remounted = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9 1"),
            deviceNode: "disk6",
            discID: Self.testDisc.discID)
        controller.discRemounted(remounted)

        #expect(controller.discUnavailable == false)
        #expect(controller.insertedDisc?.mountURL == remounted.mountURL)
        #expect(controller.insertedDisc?.insertionID == Self.testDisc.insertionID)
    }

    /// A different disc's mount event never clears it, and a remount event
    /// while the disc is available changes nothing.
    @Test func aRemountOfADifferentDiscOrAnAvailableDiscChangesNothing() async {
        let ejector = RecordingEjector()
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        let samePath = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/OTHER"), deviceNode: "disk6", discID: Self.testDisc.discID)
        controller.discRemounted(samePath)
        #expect(controller.insertedDisc == Self.testDisc)

        ejector.outcome = .unmountedButNotEjected(message: "the tray did not open")
        _ = await controller.ejectDisc()
        #expect(controller.discUnavailable == true)

        controller.discRemounted(DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/OTHER"), deviceNode: "disk7", discID: "some-other-disc"))
        #expect(controller.discUnavailable == true)
        #expect(controller.insertedDisc == Self.testDisc)
    }
}
