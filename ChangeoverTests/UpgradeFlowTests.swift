import Foundation
import Testing
@testable import Changeover

/// §7.6 — where the upgrade sits in the step flow: the duplicate check finds
/// the file, a second probe reads what is in it, and the Confirm step offers
/// a third action beside Replace and Reveal.
///
/// Driven with a fake probe and a fake runner: no `ffprobe`, no library
/// volume, no disc.
@MainActor
struct UpgradeFlowTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/BLOODSPORT"), deviceNode: "disk6", discID: "bloodsport")

    private static let folder = "/Plex/Movies/Bloodsport (1988) {tmdb-10336}"
    private static let file = "\(folder)/Bloodsport (1988).mp4"

    private static var entry: LibraryEntry {
        LibraryEntry(
            folderName: "Bloodsport (1988) {tmdb-10336}",
            folderPath: folder,
            files: [LibraryFile(name: "Bloodsport (1988).mp4", sizeBytes: 1_210_453_921, modified: nil)]
        )
    }

    private static func movie() throws -> TMDBMovie {
        let json = """
        {"id": 10336, "title": "Bloodsport", "release_date": "1988-02-26", "poster_path": null}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(TMDBMovie.self, from: json)
    }

    private static func controller() -> JobController {
        let controller = JobController(
            runner: { context, _ in fakeSuccess(context, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertedDisc = disc
        let title = DiscTitle(index: 1, durationSeconds: 5_880, chapterCount: 23, sizeBytes: 4_000_000_000, outputFileName: nil)
        let info = DiscInfo(volumeName: "BLOODSPORT", driveName: "disk6", titles: [title])
        controller.scanState = .scanned(DiscScanner.Result(disc: info, mainFeatureIndex: 1, warnings: []))
        controller.selectTitle(1, settings: AppSettings())
        return controller
    }

    /// The flow with a film picked, the duplicate found, the file read and
    /// the replacement confirmed — everything the Upgrade button needs.
    private static func readyFlow(
        jobs: JobController,
        inventory: LibraryFileInventory
    ) async throws -> RipFlowController {
        let flow = RipFlowController()
        flow.search.results = [try movie()]
        flow.select(movieID: 10336, jobs: jobs, apiKey: "")
        await flow.checkLibrary(settings: AppSettings(), probe: { _, _ in .present([entry]) })
        await flow.checkFile(settings: AppSettings(), probe: { _, _ in .success(inventory) })
        flow.acknowledgeReplace()
        return flow
    }

    private static func inventory(_ name: String) throws -> LibraryFileInventory {
        try LibraryFileInventoryTests.inventory(name)
    }

    /// A menu read that names all 23 chapters, as the real Bloodsport capture
    /// does.
    private static func menuReady(_ jobs: JobController) {
        var menu = MenuIntelligence()
        menu.chapterNames = (1...23).map {
            ChapterNames.Candidate(chapter: $0, printedNumber: $0, name: ChapterNamesTests.expectedNames[$0 - 1], confidence: 1)
        }
        jobs.menuState = .ready(menu)
    }

    // MARK: - Finding the file

    @Test func theUpgradeTargetIsTheMatchedFolderesOwnFile() async throws {
        let jobs = Self.controller()
        let flow = try await Self.readyFlow(jobs: jobs, inventory: try Self.inventory("bloodsport-library.json"))
        #expect(flow.upgradeTargetPath == Self.file)
    }

    @Test func theFileProbesAnswerIsStored() async throws {
        let jobs = Self.controller()
        let flow = try await Self.readyFlow(jobs: jobs, inventory: try Self.inventory("bloodsport-library.json"))
        #expect(flow.fileCheck.inventory?.chapters.count == 23)
    }

    @Test func aFailedProbeIsSaidRatherThanSwallowed() async throws {
        let jobs = Self.controller()
        let flow = RipFlowController()
        flow.search.results = [try Self.movie()]
        flow.select(movieID: 10336, jobs: jobs, apiKey: "")
        await flow.checkLibrary(settings: AppSettings(), probe: { _, _ in .present([Self.entry]) })

        await flow.checkFile(settings: AppSettings(), probe: { _, _ in
            .failure(JobFailure(stage: .encode, reason: .toolMissing(path: "/opt/homebrew/bin/ffprobe")))
        })

        guard case .unavailable(let path, let reason) = flow.fileCheck else {
            Issue.record("expected .unavailable, got \(flow.fileCheck)")
            return
        }
        #expect(path == Self.file)
        #expect(!reason.isEmpty)
    }

    /// Everything that clears the duplicate answer clears the file read and
    /// the overwrite permission with it: a permission given for one file must
    /// never carry to another.
    @Test func pickingADifferentFilmClearsTheFileReadAndTheTick() async throws {
        let jobs = Self.controller()
        let flow = try await Self.readyFlow(jobs: jobs, inventory: try Self.inventory("bloodsport-library.json"))
        flow.overwriteExistingChapterNames = true

        let other = try JSONDecoder().decode(TMDBMovie.self, from: Data("""
        {"id": 275, "title": "Fargo", "release_date": "1996-04-05", "poster_path": null}
        """.utf8))
        flow.search.results = [try Self.movie(), other]
        flow.select(movieID: 275, jobs: jobs, apiKey: "")

        #expect(flow.fileCheck == .idle)
        #expect(flow.overwriteExistingChapterNames == false)
        #expect(flow.upgradeTargetPath == nil)
    }

    // MARK: - The request

    @Test func theUpgradeRequestCarriesThePlanAndNoExtras() async throws {
        let jobs = Self.controller()
        Self.menuReady(jobs)
        jobs.selectedExtraTitleIndices = [2]
        let flow = try await Self.readyFlow(jobs: jobs, inventory: try Self.inventory("bloodsport-library.json"))

        let request = try #require(flow.upgradeRequest(jobs: jobs))
        #expect(request.isUpgrade)
        #expect(request.upgrade?.filePath == Self.file)
        #expect(request.upgrade?.chapters.count == 23)
        #expect(request.extraTitleIndices.isEmpty)
        #expect(request.chapterMarkers == nil)
        // Still a fully-formed request, so `JobController.start`'s disc and
        // scan guards apply to it unchanged.
        #expect(request.featureTitleIndex == 1)
        #expect(request.metadata.selectionDisc == Self.disc)
    }

    @Test func aDiscWithNothingToOfferProducesNoRequestAtAll() async throws {
        let jobs = Self.controller()
        // No menu read at all: the disc offers nothing.
        let flow = try await Self.readyFlow(jobs: jobs, inventory: try Self.inventory("bloodsport-library.json"))

        #expect(flow.upgradeRequest(jobs: jobs) == nil)
        #expect(flow.upgradeDecision(jobs: jobs, settings: AppSettings(), ffmpegAvailable: true) == .upgradeNothingSelected)
        #expect(flow.startUpgrade(jobs: jobs, settings: AppSettings(), ffmpegAvailable: true) == false)
    }

    @Test func theOverwriteTickFeedsStraightIntoTheProposal() async throws {
        let jobs = Self.controller()
        Self.menuReady(jobs)
        let named = LibraryFileInventory(
            durationMS: 23_000,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: "eng", title: "English")],
            subtitleCount: 1,
            chapters: (0..<23).map { ChapterSummary(startMS: $0 * 1000, endMS: ($0 + 1) * 1000, title: "Real \($0 + 1)") }
        )
        let flow = try await Self.readyFlow(jobs: jobs, inventory: named)

        #expect(flow.upgradeProposal(jobs: jobs)?.plan == nil)
        #expect(flow.upgradeProposal(jobs: jobs)?.overwriteWouldHelp == true)

        flow.overwriteExistingChapterNames = true
        #expect(flow.upgradeProposal(jobs: jobs)?.plan?.chapters.count == 23)
    }

    // MARK: - Starting it

    /// `JobController.start`'s failsafe: a plan with nothing in it would
    /// still overwrite a library file, so it is refused at the point of harm
    /// as well as disabled in the UI.
    @Test func anEmptyPlanIsRefusedAtThePointOfHarm() throws {
        let jobs = Self.controller()
        var request = RipRequest(
            metadata: MovieMetadata(title: "Bloodsport", year: "1988", tmdbID: "10336", selectionDisc: Self.disc),
            featureTitleIndex: 1,
            audioTrackNumbers: jobs.selectedAudioTrackNumbers
        )
        request.upgrade = UpgradePlan(filePath: Self.file)

        #expect(jobs.start(request: request, settings: AppSettings()) == false)
        #expect(jobs.isRunning == false)
        #expect(jobs.logLines.contains { $0.contains("nothing this disc can add") })
    }

    @Test func anUpgradeRunsThroughTheSameJobMachineryAsARip() async throws {
        let jobs = Self.controller()
        Self.menuReady(jobs)
        let flow = try await Self.readyFlow(jobs: jobs, inventory: try Self.inventory("bloodsport-library.json"))

        #expect(flow.upgradeDecision(jobs: jobs, settings: AppSettings(), ffmpegAvailable: true) != .upgradeNothingSelected)
        let request = try #require(flow.upgradeRequest(jobs: jobs))
        #expect(jobs.start(request: request, settings: AppSettings()))
        #expect(jobs.isRunning)
        // The job keeps its request, which is what the Done card reads to say
        // what was upgraded.
        #expect(jobs.current?.request?.upgrade == request.upgrade)
    }
}
