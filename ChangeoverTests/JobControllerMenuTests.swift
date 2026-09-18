import Foundation
import Testing
@testable import Changeover

/// `JobController.menuState` — the disc's menu read as a sibling of the scan.
///
/// Driven through the injectable `MenuRunner` seam, so none of this needs
/// `changeover-menudump`, `ffmpeg`, Vision or a disc. What is asserted is the
/// wiring the principle depends on: it starts only after the scan, it is
/// cleared by every disc event, a result that outlives its disc is discarded,
/// and nothing about it can hold up or change a rip.
@MainActor
struct JobControllerMenuTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/BLOODSPORT"),
        deviceNode: "disk6",
        discID: "bloodsport-id")

    private static let otherDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/OPPENHEIMER"),
        deviceNode: "disk6",
        discID: "oppenheimer-id")

    private static func scan(chapterCount: Int = 23, titleIndex: Int = 1) -> DiscScanner.Result {
        let title = DiscTitle(
            index: titleIndex,
            durationSeconds: 5_880,
            chapterCount: chapterCount,
            sizeBytes: 4_000_000_000,
            outputFileName: nil)
        return DiscScanner.Result(
            disc: DiscInfo(volumeName: "BLOODSPORT", driveName: "disk6", titles: [title]),
            mainFeatureIndex: titleIndex,
            warnings: [])
    }

    private static func names(_ count: Int) -> [ChapterNames.Candidate] {
        (1...count).map {
            ChapterNames.Candidate(chapter: $0, printedNumber: $0, name: "Scene \($0)", confidence: 1)
        }
    }

    private static func intelligence(chapterNames: Int) -> MenuIntelligence {
        var menu = MenuIntelligence()
        menu.chapterNames = names(chapterNames)
        return menu
    }

    /// Settings with a helper path that resolves to nothing on disk — the
    /// runner is injected, so the path only has to be non-empty for the read
    /// to be attempted.
    private static func settings() -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "JobControllerMenuTests-\(UUID().uuidString)")!)
        settings.menudumpPath = "/nonexistent/changeover-menudump"
        settings.plexMediaRoot = NSTemporaryDirectory()
        return settings
    }

    // MARK: - It runs after the scan

    @Test func aFinishedScanStartsTheMenuRead() async throws {
        var sawChapterCount: Int?
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in .success(Self.scan()) },
            menuRunner: { _, _, chapterCount, _, _ in
                sawChapterCount = chapterCount
                return .ready(Self.intelligence(chapterNames: 23))
            },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertDisc(Self.disc, settings: Self.settings())
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        // The read is handed the settled feature title's chapter count, which
        // is the whole basis of the equality check.
        #expect(sawChapterCount == 23)
        #expect(controller.menuState.intelligence?.chapterNames.count == 23)
    }

    /// A failed scan never starts a read: there is no chapter count to check
    /// against, and the drive has just proven unhappy.
    @Test func aFailedScanReadsNoMenus() async throws {
        var started = false
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in .failure(.toolExited(code: 3)) },
            menuRunner: { _, _, _, _, _ in
                started = true
                return .ready(MenuIntelligence())
            },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertDisc(Self.disc, settings: Self.settings())
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!started)
        #expect(controller.menuState == .idle)
    }

    /// A helper that is not there, a disc with no menus, a crash: all of them
    /// are a state with a caption, and none of them touches the scan the rip
    /// actually runs on.
    @Test func anUnavailableReadLeavesTheScanAlone() async throws {
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in .success(Self.scan()) },
            menuRunner: { _, _, _, _, _ in .unavailable(.helperMissing(path: "/nonexistent/changeover-menudump")) },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertDisc(Self.disc, settings: Self.settings())
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(controller.menuState == .unavailable(.helperMissing(path: "/nonexistent/changeover-menudump")))
        #expect(controller.scanState == .scanned(Self.scan()))
        #expect(controller.selectedTitleIndex == 1)
        #expect(controller.chapterMarkerRows == nil)
    }

    // MARK: - It never crosses discs

    @Test func removingTheDiscClearsTheMenuState() async throws {
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in .success(Self.scan()) },
            menuRunner: { _, _, _, _, _ in .ready(Self.intelligence(chapterNames: 23)) },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertDisc(Self.disc, settings: Self.settings())
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.menuState.intelligence != nil)

        controller.removeDisc()
        #expect(controller.menuState == .idle)
    }

    /// The caption belongs to the disc it was read from. A read that lands
    /// after a swap is discarded, exactly as a superseded scan's result is.
    @Test func aLateReadForADepartedDiscIsDiscarded() async throws {
        let gate = MenuGate()
        let reads = ReadCounter()
        let controller = JobController(
            scanRunner: { _, _, _, _, _ in .success(Self.scan()) },
            menuRunner: { _, _, _, _, _ in
                let index = reads.next()
                await gate.wait()
                // The first disc's read names 23 chapters; the second disc's
                // names 7. If the departed disc's result were ever applied,
                // the controller would end up holding 23.
                return .ready(Self.intelligence(chapterNames: index == 1 ? 23 : 7))
            },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertDisc(Self.disc, settings: Self.settings())
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.menuState == .reading)

        // The disc is swapped while the first read is still in flight.
        controller.insertDisc(Self.otherDisc, settings: Self.settings())
        gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(controller.insertedDisc == Self.otherDisc)
        #expect(controller.menuState.intelligence?.chapterNames.count == 7)
    }

    // MARK: - The chapter-marker gate

    @Test func namesMatchingTheTitlesChapterCountAreOffered() {
        let controller = JobController(ejector: PipelineTestSupport.fakeEject)
        controller.insertedDisc = Self.disc
        controller.scanState = .scanned(Self.scan(chapterCount: 23))
        controller.selectTitle(1, settings: Self.settings())
        controller.menuState = .ready(Self.intelligence(chapterNames: 23))

        #expect(controller.chapterMarkerPlan(forTitleIndex: 1).isWrite)
        #expect(controller.chapterMarkerRows?.count == 23)
    }

    /// The count is checked against the title actually being encoded, not the
    /// one the names were read for — the user can change the pick after the
    /// menus are read.
    @Test func aTitleWithADifferentChapterCountIsRefused() {
        let controller = JobController(ejector: PipelineTestSupport.fakeEject)
        controller.insertedDisc = Self.disc
        controller.scanState = .scanned(Self.scan(chapterCount: 18))
        controller.selectTitle(1, settings: Self.settings())
        controller.menuState = .ready(Self.intelligence(chapterNames: 23))

        #expect(!controller.chapterMarkerPlan(forTitleIndex: 1).isWrite)
        #expect(controller.chapterMarkerRows == nil)
    }

    @Test func noMenuReadMeansNoRows() {
        let controller = JobController(ejector: PipelineTestSupport.fakeEject)
        controller.insertedDisc = Self.disc
        controller.scanState = .scanned(Self.scan())
        controller.selectTitle(1, settings: Self.settings())
        #expect(controller.chapterMarkerRows == nil)
    }

    @Test func noSettledTitleMeansNoRows() {
        let controller = JobController(ejector: PipelineTestSupport.fakeEject)
        controller.insertedDisc = Self.disc
        controller.scanState = .scanned(Self.scan())
        controller.menuState = .ready(Self.intelligence(chapterNames: 23))
        #expect(controller.chapterMarkerPlan(forTitleIndex: nil).isWrite == false)
    }
}

/// Counts the reads a fake runner has been asked for, so two in-flight reads
/// can return different answers.
@MainActor
private final class ReadCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// A one-shot latch for parking a fake menu runner, the same shape the other
/// controller suites use for their own fakes.
@MainActor
private final class MenuGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
