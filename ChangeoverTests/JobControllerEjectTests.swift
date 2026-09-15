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

    // MARK: - Fake

    /// Records every call and returns a scripted outcome.
    private final class FakeEjector {
        private(set) var calls: [URL] = []
        var outcome: DiscEjector.Outcome = .ejected

        func eject(_ url: URL) async -> DiscEjector.Outcome {
            calls.append(url)
            return outcome
        }
    }

    // MARK: - Helpers (mirrors JobControllerTests' / PowerAssertionTests' fixtures)

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
        let ejector = FakeEjector()
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        // Deliberately not mounted.

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(ejector.calls.isEmpty)
        #expect(controller.logLines.contains("⚠︎ No disc is mounted."))
    }

    @Test func ejectDiscRefusesWhileAJobIsRunning() async throws {
        let gate = Gate()
        let ejector = FakeEjector()
        let controller = JobController(runner: { _, _, _, _, _, log in
            log("▶ working")
            await gate.wait()
            return .succeeded(destination: Self.destination)
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
        let ejector = FakeEjector()
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
        let ejector = FakeEjector()
        ejector.outcome = .ejected
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        _ = await controller.ejectDisc()

        #expect(controller.insertedDisc == Self.testDisc)
    }

    @Test func ejectDiscReportsABusyFailureAndDoesNotClaimSuccess() async {
        let ejector = FakeEjector()
        ejector.outcome = .busy(message: "Could not eject the disc — it's still in use: resource busy.")
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        Self.mount(controller, disc: Self.testDisc)

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(controller.logLines.contains("⚠︎ Could not eject the disc — it's still in use: resource busy."))
        #expect(controller.isEjecting == false)
    }

    @Test func ejectDiscReportsAGenericFailure() async {
        let ejector = FakeEjector()
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

    /// A `HandBrakeCLI --scan` holds the disc and can't be cancelled yet
    /// (#0046). Ejecting mid-scan must be refused, not attempted: the eject
    /// would fail as busy, or unmount the volume without removing the disc
    /// and turn the scan's I/O error into a misleading scan failure.
    @Test func ejectDiscRefusesWhileTheDiscIsBeingScanned() async {
        let ejector = FakeEjector()
        let controller = JobController(ejector: { url in await ejector.eject(url) })
        controller.insertedDisc = Self.testDisc
        controller.scanState = .scanning

        let result = await controller.ejectDisc()

        #expect(result == false)
        #expect(ejector.calls.isEmpty)
        #expect(controller.logLines.contains("⚠︎ The disc is still being scanned — wait for the scan to finish before ejecting."))
        #expect(controller.scanState == .scanning)
        #expect(controller.insertedDisc == Self.testDisc)
        #expect(controller.isEjecting == false)
    }

    /// Once the scan has settled, even as a failure, the disc can be ejected.
    @Test func ejectDiscIsAllowedAfterAFailedScan() async {
        let ejector = FakeEjector()
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
        let ejector = FakeEjector()
        let scans = ScanCounter()
        let controller = JobController(
            runner: { _, _, _, _, _, _ in
                Issue.record("the runner must not be invoked while ejecting")
                return .succeeded(destination: Self.destination)
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
        let ejector = FakeEjector()
        let controller = JobController(
            runner: { _, _, _, _, _, _ in
                Issue.record("the runner must not be invoked on an ejected disc")
                return .succeeded(destination: Self.destination)
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
        let ejector = FakeEjector()
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
}
