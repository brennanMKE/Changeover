import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Changeover

/// #0155 — a screenshot of every screen, rendered off-screen from real state.
///
/// Reviewing the window used to mean feeding a real disc into joe and watching:
/// several screens go past in seconds, the interesting ones fastest of all, and
/// half of them cannot be reached on demand at all (a disc already in Plex, a
/// failed rip, a disc pulled mid-job). That made design review nearly
/// impossible, which is how two new screens shipped that the user is not happy
/// with.
///
/// This renders each screen with `ImageRenderer`, which needs **no window
/// server, no XCUITest and no VM**: it draws the SwiftUI view into a bitmap on
/// the main actor. So it runs as an ordinary unit test on gordon, and none of
/// `docs/ui-test-crash-prevention.md` applies — nothing is automated against a
/// live GUI.
///
/// The states are built by driving the **real** controllers through their real
/// APIs (`select`, `continueToConfirm`, `ripRequest`, `start`) rather than by
/// forcing view arguments, and each scenario asserts the step it actually
/// derived. A screenshot of an unreachable state would be worse than no
/// screenshot, because a design decision would be taken against a screen the
/// app cannot show.
///
/// Output: `build/screens/*.png` plus `manifest.json`, which
/// `Tools/build-screen-review.swift` turns into the review page.
@MainActor
@Suite struct ScreenshotHarnessTests {

    // MARK: - Where the output goes

    /// The repo root, from this file's own compile-time path — so it resolves
    /// on gordon (where the repo is synced to `$HOME`) exactly as it does here.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // .../ChangeoverTests/ScreenshotHarnessTests.swift
            .deletingLastPathComponent()      // .../ChangeoverTests
            .deletingLastPathComponent()      // repo root
    }

    private static var outputDirectory: URL {
        repoRoot.appendingPathComponent("build/screens", isDirectory: true)
    }

    // MARK: - Fixtures

    private static func settings(autoStart: Bool = false, showsDetails: Bool = true) -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.plexMediaRoot = NSTemporaryDirectory()
        s.autoStartRipping = autoStart
        s.showsDetails = showsDetails
        return s
    }

    private static func disc(_ volume: String = "ADVENTURELAND", id: String = "disc-a") -> DiscInsertion {
        DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/\(volume)"),
                      deviceNode: "disk4", discID: id)
    }

    private static func movie(id: Int, title: String, date: String) throws -> TMDBMovie {
        let json = #"{"id": \#(id), "title": "\#(title)", "release_date": "\#(date)", "poster_path": null}"#
        return try JSONDecoder().decode(TMDBMovie.self, from: Data(json.utf8))
    }

    /// A finished scan with a plausible feature: 107 minutes, 21 chapters.
    private static func scannedState(titleIndex: Int = 1, seconds: Int = 6_420) -> ScanState {
        let feature = DiscTitle(index: titleIndex, durationSeconds: seconds, chapterCount: 21,
                                sizeBytes: 6_300_000_000, outputFileName: nil, displayAspect: 1.78)
        let extra = DiscTitle(index: 2, durationSeconds: 212, chapterCount: 1,
                              sizeBytes: 90_000_000, outputFileName: nil, displayAspect: 1.78)
        let info = DiscInfo(volumeName: "ADVENTURELAND", driveName: "disk4", titles: [feature, extra])
        return .scanned(DiscScanner.Result(disc: info, mainFeatureIndex: titleIndex, warnings: []))
    }

    /// A controller with a disc in and a settled title — the precondition for
    /// everything past step 1.
    private static func mounted(
        runner: @escaping JobController.Runner = { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
        disc: DiscInsertion? = nil,
        settings: AppSettings
    ) -> JobController {
        let jobs = JobController(runner: runner, ejector: PipelineTestSupport.fakeEject)
        jobs.insertedDisc = disc ?? Self.disc()
        jobs.scanState = scannedState()
        jobs.selectTitle(1, settings: settings)
        return jobs
    }

    /// Put a film in the results and pick it the way a click does.
    private static func pick(_ flow: RipFlowController, jobs: JobController,
                             _ movie: TMDBMovie, origin: RipFlowController.SelectionOrigin) {
        flow.search.results = [movie]
        flow.select(movieID: movie.id, jobs: jobs, apiKey: "", origin: origin)
    }

    private static func libraryPresent(tmdbID: Int, folder: String, file: String, bytes: Int64) -> LibraryCheck {
        .done(tmdbID: String(tmdbID), .present([
            LibraryEntry(folderName: folder,
                         folderPath: "/Volumes/Media/Media/Movies/\(folder)",
                         files: [LibraryFile(name: file, sizeBytes: bytes, modified: Date())])
        ]))
    }

    /// Polls a condition on the main actor. The real controllers finish their
    /// work in detached `Task`s, so a scenario that starts a job or an eject has
    /// to wait for the state it wants rather than read it in the same tick.
    private static func waitUntil(
        _ label: String, timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(label)")
    }

    // MARK: - The scenario list

    /// One screen to photograph, with what the reviewer should look at.
    struct Scenario {
        let id: String
        let path: String
        let title: String
        /// What the user is doing and seeing at this moment.
        let purpose: String
        /// What is worth judging here — the design question the screenshot is
        /// meant to answer.
        let lookAt: String
        /// How long the user sees it in practice. The user's specific complaint
        /// is that the informative screens go by fastest.
        let dwell: String
        let expected: FlowStep
        let height: CGFloat
        let build: () async throws -> (AppSettings, JobController, RipFlowController)
    }

    static func scenarios() -> [Scenario] {
        var all: [Scenario] = []

        // ── Path 1: the automatic import ─────────────────────────────────
        all.append(Scenario(
            id: "1a-insert-disc",
            path: "Path 1 — automatic import",
            title: "Waiting for a disc",
            purpose: "The resting state. Nothing is in the drive and the app has nothing to say yet.",
            lookAt: "Whether an idle Plex host should show more than this — the last job's one-line summary is the only history here.",
            dwell: "Indefinite — until a disc goes in.",
            expected: .insertDisc(.noDisc),
            height: WindowSizing.defaultHeight(for: .compact),
            build: {
                let s = settings()
                let jobs = JobController(runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
                                         ejector: PipelineTestSupport.fakeEject)
                return (s, jobs, RipFlowController())
            }))

        all.append(Scenario(
            id: "1b-scanning",
            path: "Path 1 — automatic import",
            title: "Disc in, scan running, nothing identified yet",
            purpose: "The disc has been seen and HandBrake is scanning it. The app is about to try to identify the film on its own.",
            lookAt: "The one-line scan strip. This is where Smart Import's evidence begins to appear and there is no panel to hold it yet.",
            dwell: "Tens of seconds — as long as the scan takes.",
            expected: .chooseMovie,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = JobController(runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
                                         ejector: PipelineTestSupport.fakeEject)
                jobs.insertedDisc = disc()
                jobs.scanState = .scanning
                return (s, jobs, RipFlowController())
            }))

        all.append(Scenario(
            id: "1c-auto-identified-confirm",
            path: "Path 1 — automatic import",
            title: "Identified automatically, about to start on its own",
            purpose: "Smart Import matched the film from the disc's label and menus. With automatic ripping on, this screen starts the job by itself after a short pause.",
            lookAt: "THE KEY SCREEN FOR THE USER'S COMPLAINT. All the identification evidence is here, and it is replaced by the Ripping step seconds later. Is the pause long enough, and is the evidence legible before it goes?",
            dwell: "Seconds — then it advances on its own.",
            expected: .confirm,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = mounted(settings: s)
                let flow = RipFlowController()
                let m = try movie(id: 13811, title: "Knowing", date: "2009-03-19")
                pick(flow, jobs: jobs, m, origin: .automatic)
                flow.continueToConfirm()
                return (s, jobs, flow)
            }))

        all.append(Scenario(
            id: "1d-ripping",
            path: "Path 1 — automatic import",
            title: "Ripping, with the identification evidence carried forward",
            purpose: "The encode is running. The evidence panel exists so the reasoning stays on screen for the forty minutes the encode takes.",
            lookAt: "Whether the evidence panel is big enough to be read, and whether the progress block and the panel are fighting for the same space.",
            dwell: "Twenty to sixty minutes.",
            expected: .ripping(JobID.make()),   // id compared loosely below
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = mounted(runner: { ctx, _ in await fakeCancel(ctx) }, settings: s)
                let flow = RipFlowController()
                let m = try movie(id: 13811, title: "Knowing", date: "2009-03-19")
                jobs.note("▶ Identifying the disc — its label reads “KNOWING”")
                jobs.note("  · the menus print “Knowing” — searching for that")
                jobs.note("  · asking this Mac's on-device model to read 21 lines")
                jobs.note("▶ Matching against TMDB — the disc's feature runs 121 min")
                jobs.note("  · Knowing — 121 min · Nicolas Cage, Rose Byrne · dir. Alex Proyas")
                jobs.note("✓ Chose Knowing — the only result, and its runtime matches the disc")
                pick(flow, jobs: jobs, m, origin: .automatic)
                flow.continueToConfirm()
                if let request = flow.ripRequest(jobs: jobs) {
                    _ = jobs.start(request: request, settings: s)
                }
                return (s, jobs, flow)
            }))

        // ── Path 2: the user has to help ─────────────────────────────────
        all.append(Scenario(
            id: "2a-cannot-identify",
            path: "Path 2 — the user identifies it",
            title: "Smart Import gave up: no candidate fits",
            purpose: "The disc's label is unusable (here the real one: ADV-0N-NW1.1_DES) so the app refuses to guess and hands the decision over.",
            lookAt: "Whether it is clear WHY the app could not identify it, and whether the search field is obviously the next thing to do.",
            dwell: "Until the user types something.",
            expected: .chooseMovie,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = mounted(disc: disc("ADV-0N-NW1.1_DES", id: "disc-adv"), settings: s)
                jobs.note("▶ Identifying the disc — its label reads “ADV-0N-NW1.1_DES”")
                jobs.note("  · the model had no answer — the label spells nothing")
                jobs.note("• Not choosing for you — no candidate fits the disc. Pick one below.")
                return (s, jobs, RipFlowController())
            }))

        all.append(Scenario(
            id: "2b-user-typed-results",
            path: "Path 2 — the user identifies it",
            title: "The user typed a title and the results came back",
            purpose: "The user searched for “Adventureland” themselves. The credits line under each row is what makes two same-titled films tellable apart.",
            lookAt: "Whether the recommendation is visible enough, and whether a single obvious match still needs a click.",
            dwell: "Until the user picks a row.",
            expected: .chooseMovie,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = mounted(disc: disc("ADV-0N-NW1.1_DES", id: "disc-adv"), settings: s)
                let flow = RipFlowController()
                flow.search.query = "Adventureland"
                flow.search.results = [
                    try movie(id: 13363, title: "Adventureland", date: "2009-04-03"),
                    try movie(id: 1108778, title: "Adventureland", date: "2024-01-01"),
                ]
                return (s, jobs, flow)
            }))

        all.append(Scenario(
            id: "2c-manual-confirm",
            path: "Path 2 — the user identifies it",
            title: "Manually chosen, and about to start immediately",
            purpose: "The user did the work of identifying the disc, picked the film, and the app moves straight on.",
            lookAt: "THE USER'S SPECIFIC ASK: after taking manual steps, they want a moment to see the match and the recommendation confirmed. Right now this screen can pass in a second.",
            dwell: "Seconds — arguably too few, given the user just did the work.",
            expected: .confirm,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = mounted(disc: disc("ADV-0N-NW1.1_DES", id: "disc-adv"), settings: s)
                let flow = RipFlowController()
                jobs.note("▶ Identifying the disc — its label reads “ADV-0N-NW1.1_DES”")
                jobs.note("• Not choosing for you — no candidate fits the disc. Pick one below.")
                flow.search.query = "Adventureland"
                let m = try movie(id: 13363, title: "Adventureland", date: "2009-04-03")
                pick(flow, jobs: jobs, m, origin: .user)
                flow.continueToConfirm()
                return (s, jobs, flow)
            }))

        all.append(Scenario(
            id: "2d-ripping-after-manual",
            path: "Path 2 — the user identifies it",
            title: "Ripping a film the user chose by hand",
            purpose: "The evidence panel now records both halves: what the app guessed, and what the user chose. Before #0154 the heading claimed the app had identified it.",
            lookAt: "The heading change, and whether “✎ You chose …” is distinguishable enough from the app's own lines.",
            dwell: "Twenty to sixty minutes.",
            expected: .ripping(JobID.make()),
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = mounted(runner: { ctx, _ in await fakeCancel(ctx) },
                                   disc: disc("ADV-0N-NW1.1_DES", id: "disc-adv"), settings: s)
                let flow = RipFlowController()
                jobs.note("▶ Identifying the disc — its label reads “ADV-0N-NW1.1_DES”")
                jobs.note("  · the model had no answer — the label spells nothing")
                jobs.note("• Not choosing for you — no candidate fits the disc. Pick one below.")
                flow.search.query = "Adventureland"
                let m = try movie(id: 13363, title: "Adventureland", date: "2009-04-03")
                pick(flow, jobs: jobs, m, origin: .user)
                flow.continueToConfirm()
                if let request = flow.ripRequest(jobs: jobs) {
                    _ = jobs.start(request: request, settings: s)
                }
                return (s, jobs, flow)
            }))

        // ── Path 3: already in the library ───────────────────────────────
        all.append(Scenario(
            id: "3a-duplicate-notice",
            path: "Path 3 — already in Plex",
            title: "Already in Plex, waiting for a decision",
            purpose: "With automatic ripping OFF, a film already in the library stops here and offers “Replace the Existing File”.",
            lookAt: "Whether the existing copy is described well enough to decide against — name, size, and where it is.",
            dwell: "Until the user decides.",
            expected: .confirm,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: false)
                let jobs = mounted(disc: disc("KNOWING", id: "disc-knowing"), settings: s)
                let flow = RipFlowController()
                let m = try movie(id: 13811, title: "Knowing", date: "2009-03-19")
                pick(flow, jobs: jobs, m, origin: .user)
                flow.continueToConfirm()
                flow.setLibraryCheckForTesting(libraryPresent(
                    tmdbID: 13811, folder: "Knowing (2009) {tmdb-13811}",
                    file: "Knowing (2009).mp4", bytes: 630_421_198))
                return (s, jobs, flow)
            }))

        all.append(Scenario(
            id: "3b-ejected",
            path: "Path 3 — already in Plex",
            title: "Ejected because the film is already in Plex",
            purpose: "With automatic ripping ON, the disc is ejected so the line keeps moving. Before #0153 this happened in total silence — the tray just opened.",
            lookAt: "NEW SCREEN. Is this the right amount of text? Does it need an action (Rip anyway / Show in Plex)? Does it stay long enough?",
            dwell: "Until the next disc goes in.",
            expected: .ejected(EjectExplanation(
                cause: .alreadyInPlex, movie: "Knowing (2009)",
                existingFile: "Knowing (2009).mp4", existingSize: "601 MB")),
            height: WindowSizing.defaultHeight(for: .compact),
            build: {
                let s = settings(autoStart: true)
                let jobs = JobController(runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
                                         ejector: PipelineTestSupport.fakeEject)
                let flow = RipFlowController()
                flow.setUnexplainedEjectionForTesting(EjectExplanation(
                    cause: .alreadyInPlex, movie: "Knowing (2009)",
                    existingFile: "Knowing (2009).mp4", existingSize: "601 MB"))
                return (s, jobs, flow)
            }))

        // ── Other branches the user did not name ─────────────────────────
        all.append(Scenario(
            id: "4a-done-success",
            path: "Path 4 — endings",
            title: "Finished, filed into Plex",
            purpose: "The successful ending. The disc has been ejected and the file is in the library.",
            lookAt: "THE USER'S OTHER COMPLAINT: this screen loses most of the useful detail the Ripping screen had. Should the evidence panel survive into Done?",
            dwell: "Until the next disc, or indefinitely.",
            expected: .done(JobID.make()),
            height: WindowSizing.defaultHeight(for: .compact),
            build: {
                let s = settings()
                let jobs = mounted(settings: s)
                let flow = RipFlowController()
                let m = try movie(id: 13811, title: "Knowing", date: "2009-03-19")
                jobs.note("✓ Chose Knowing — the only result, and its runtime matches the disc")
                pick(flow, jobs: jobs, m, origin: .automatic)
                flow.continueToConfirm()
                if let request = flow.ripRequest(jobs: jobs) {
                    _ = jobs.start(request: request, settings: s)
                }
                // The fake runner finishes in its own Task; Done only exists
                // once the job has moved into history.
                try await waitUntil("the job to finish") {
                    jobs.current == nil && !jobs.history.isEmpty
                }
                return (s, jobs, flow)
            }))

        all.append(Scenario(
            id: "5a-eject-in-flight",
            path: "Path 5 — the drive misbehaves",
            title: "Ejecting",
            purpose: "The eject ladder is running. On joe's USB drive this can take minutes and six attempts, because loginwindow dissents while the screen is locked.",
            lookAt: "Whether a multi-minute eject needs more than “Ejecting…” — on joe it really does take that long.",
            dwell: "Seconds to several minutes.",
            expected: .insertDisc(.ejecting),
            height: WindowSizing.defaultHeight(for: .compact),
            build: {
                let s = settings()
                let jobs = JobController(runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
                                         ejector: { _ in
                                             try? await Task.sleep(for: .seconds(600))
                                             return .ejected
                                         })
                jobs.insertedDisc = disc()
                // `ejectDisc` sets `isEjecting` and then awaits the ejector,
                // which here never returns — so the window stays on this step.
                Task { _ = await jobs.ejectDisc() }
                try await waitUntil("the eject to be in flight") { jobs.isEjecting }
                return (s, jobs, RipFlowController())
            }))

        // ── Path 6: a disc holding more than one film (#0157/#0160) ──────
        /// The real Uncle Buck / The Great Outdoors disc, as captured.
        func doubleFeatureScan() -> ScanState {
            let outdoors = DiscTitle(index: 1, durationSeconds: 5_425, chapterCount: 17,
                                     sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
            let buck = DiscTitle(index: 2, durationSeconds: 5_978, chapterCount: 17,
                                 sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
            let trailer = DiscTitle(index: 3, durationSeconds: 169, chapterCount: 3,
                                    sizeBytes: 0, outputFileName: nil, displayAspect: 1.33)
            let info = DiscInfo(volumeName: "UNCLE_BUCK_GREAT_OUTDOORS",
                                driveName: "disk4", titles: [outdoors, buck, trailer])
            return .scanned(DiscScanner.Result(disc: info, mainFeatureIndex: 1, warnings: []))
        }

        all.append(Scenario(
            id: "6a-two-features-unnamed",
            path: "Path 6 — two films on one disc",
            title: "Two features, neither named yet",
            purpose: "The disc holds two films. Both search boxes are deliberately blank: the volume label is UNCLE_BUCK_GREAT_OUTDOORS, and prefilling that whole string returns 0 results and looks broken.",
            lookAt: "THE KEY SCREEN: is it obvious there are two films and that each needs naming? Are the blocks distinguishable by runtime alone, with no poster and no title?",
            dwell: "Until the user names at least one film.",
            expected: .chooseMovie,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = JobController(runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
                                         ejector: PipelineTestSupport.fakeEject)
                jobs.insertedDisc = disc("UNCLE_BUCK_GREAT_OUTDOORS", id: "disc-ub")
                jobs.scanState = doubleFeatureScan()
                let flow = RipFlowController()
                flow.reconcile(jobs: jobs, apiKey: "", settings: s)
                return (s, jobs, flow)
            }))

        all.append(Scenario(
            id: "6b-two-features-one-named",
            path: "Path 6 — two films on one disc",
            title: "One film named, one still to go",
            purpose: "The user has searched for and picked Uncle Buck for the 1h 40m feature. The other block is still waiting.",
            lookAt: "Does the named block read as settled, and the unnamed one as outstanding? Is it clear which film this pass will actually rip?",
            dwell: "Until the second film is named, or Start is pressed.",
            expected: .chooseMovie,
            height: WindowSizing.defaultHeight(for: .full),
            build: {
                let s = settings(autoStart: true)
                let jobs = JobController(runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
                                         ejector: PipelineTestSupport.fakeEject)
                jobs.insertedDisc = disc("UNCLE_BUCK_GREAT_OUTDOORS", id: "disc-ub")
                jobs.scanState = doubleFeatureScan()
                let flow = RipFlowController()
                flow.reconcile(jobs: jobs, apiKey: "", settings: s)
                if let model = flow.featureSearch(2) {
                    model.query = "Uncle Buck"
                    model.results = [try movie(id: 2616, title: "Uncle Buck", date: "1989-08-16")]
                    flow.selectFeature(movieID: 2616, feature: 2, jobs: jobs, settings: s)
                }
                return (s, jobs, flow)
            }))

        return all
    }

    // MARK: - The render

    /// Renders every scenario, asserts it reached the screen it claims, and
    /// writes the PNGs plus the manifest the review page is built from.
    @Test func everyScreenRendersToAPNG() async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.outputDirectory)
        try fm.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        var manifest: [[String: String]] = []

        for scenario in Self.scenarios() {
            let (settings, jobs, flow) = try await scenario.build()
            let actual = flow.step(jobs: jobs)

            // The screenshot must be of the screen it says it is. A scenario
            // that silently lands elsewhere would put a design decision in
            // front of the wrong picture.
            #expect(Self.sameCase(actual, scenario.expected),
                    "\(scenario.id): built \(actual), expected \(scenario.expected)")

            let view = RipFlowView()
                .environment(settings)
                .environment(jobs)
                .environment(flow)

            let size = CGSize(width: 620, height: scenario.height)
            let file = Self.outputDirectory.appendingPathComponent("\(scenario.id).png")
            try #require(Self.captureWindow(view, size: size, to: file),
                         "\(scenario.id): PNG not written")

            manifest.append([
                "id": scenario.id,
                "path": scenario.path,
                "title": scenario.title,
                "purpose": scenario.purpose,
                "lookAt": scenario.lookAt,
                "dwell": scenario.dwell,
                "step": String(describing: actual),
                "file": "\(scenario.id).png",
                "width": "620",
                "height": String(Int(scenario.height)),
            ])
        }

        let json = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: Self.outputDirectory.appendingPathComponent("manifest.json"))

        #expect(manifest.count == Self.scenarios().count)
        print("screens written to \(Self.outputDirectory.path) — \(manifest.count) images")
    }

    /// Case-only comparison: `.ripping`/`.done` carry a `JobID` generated at
    /// build time, which no fixture can predict.
    private static func sameCase(_ a: FlowStep, _ b: FlowStep) -> Bool {
        switch (a, b) {
        case (.insertDisc(let x), .insertDisc(let y)):   return x == y
        case (.ejected, .ejected):                        return true
        case (.chooseMovie, .chooseMovie):                return true
        case (.confirm, .confirm):                        return true
        case (.ripping, .ripping):                        return true
        case (.done, .done):                              return true
        default:                                          return false
        }
    }

    /// Draws the view by hosting it in a real off-screen window and asking it
    /// to cache its own display.
    ///
    /// `ImageRenderer` was the obvious choice and is the wrong one: it drew
    /// `ProgressView` as a yellow placeholder with a missing-glyph symbol, and
    /// rendered the evidence panel's `ScrollView` as an empty box — the two
    /// things the Ripping screen is *for*. It re-draws SwiftUI into a bitmap
    /// rather than running the real AppKit hierarchy, so anything backed by an
    /// `NSView` is lost.
    ///
    /// `cacheDisplay(in:to:)` is the app drawing itself, which is exactly what
    /// `NSHostingView` already does on screen. It needs no Screen Recording
    /// permission and no window server session — the window is never ordered
    /// front — which is why this stays an ordinary unit test rather than
    /// anything resembling UI automation.
    private static func captureWindow<V: View>(_ view: V, size: CGSize, to url: URL) -> Bool {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)

        // A real window, so the hosting view gets a backing scale, an
        // appearance and a proper layout pass. Never ordered front.
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)

        // Let SwiftUI settle: layout, async image loads, animations landing on
        // their first frame. Without this the first screens come out half laid
        // out.
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let ok = (try? png.write(to: url)) != nil
        window.contentView = nil
        return ok
    }
}
