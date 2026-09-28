import Foundation
import Testing
@testable import Changeover

/// #0161 — each film on a multi-feature disc says whether it is already in Plex.
///
/// Reported on the Uncle Buck / The Great Outdoors disc, 2026-09-27: "I am
/// pretty sure both movies are imported yet the app does not show that." Both
/// were — `{tmdb-2616}` and `{tmdb-2617}` — and the app could not say so,
/// because the library probe had only ever run from the Confirm step's
/// `.task(id:)` against the single active movie. On a disc where the user is
/// naming two films by hand, that is too late and too narrow: the second
/// film's status never appeared anywhere at all.
@Suite struct FeatureLibraryStatusTests {

    private static func present(_ file: String, _ bytes: Int64) -> FeatureLibraryStatus.State {
        .present(file: file, size: EjectExplanation.formatSize(bytes))
    }

    // MARK: - The badge beside one block

    /// The headline: a film already in Plex says so, and names the file, so
    /// the claim can be checked rather than trusted.
    @Test func aFilmAlreadyInPlexNamesTheFileAndItsSize() throws {
        let badge = try #require(FeatureLibraryStatus.badge(
            for: Self.present("Uncle Buck (1989).mp4", 533_136_772)))
        #expect(badge.hasPrefix("Already in Plex"))
        #expect(badge.contains("Uncle Buck (1989).mp4"))
        #expect(badge.contains("MB"))
    }

    /// A film the library does not have says nothing. Silence is the ordinary
    /// case and a badge on every block would be noise.
    @Test func aFilmNotInPlexSaysNothing() {
        #expect(FeatureLibraryStatus.badge(for: .absent) == nil)
    }

    /// Nothing named yet is not an answer about the library.
    @Test func anUnnamedFeatureSaysNothing() {
        #expect(FeatureLibraryStatus.badge(for: .noFilmNamed) == nil)
    }

    @Test func aCheckInFlightSaysSo() {
        #expect(FeatureLibraryStatus.badge(for: .checking) == "Checking Plex…")
    }

    /// An unreadable library is **never** reported as "not there". #0143's
    /// rule: "not there" may only be said after a successful listing.
    @Test func anUnreadableLibraryIsNotReportedAsAbsent() throws {
        let badge = try #require(FeatureLibraryStatus.badge(
            for: .unreadable(reason: "the volume is not mounted")))
        #expect(badge.lowercased().contains("could not read"))
        #expect(!badge.lowercased().contains("already in plex"))
    }

    /// A match with no file detail still reads.
    @Test func aMatchWithNoFileDetailStillReads() {
        #expect(FeatureLibraryStatus.badge(for: .present(file: nil, size: nil)) == "Already in Plex")
    }

    // MARK: - The notice for the whole disc

    /// The reported case: both films already there, said once at the top.
    @Test func everyFeaturePresentIsSaidOnce() throws {
        let states = [
            Self.present("The Great Outdoors (1988).mp4", 400_000_000),
            Self.present("Uncle Buck (1989).mp4", 533_136_772),
        ]
        let notice = try #require(FeatureLibraryStatus.everyFeatureNotice(states))
        #expect(notice.contains("Both"))
        #expect(try #require(FeatureLibraryStatus.plainEveryFeatureNotice(states))
                    .contains("both of these movies"))
    }

    /// One of two is not "both", and must not claim to be — that is the case
    /// where the disc is still worth ripping.
    @Test func oneOfTwoSaysNothing() {
        let states = [Self.present("Uncle Buck (1989).mp4", 1), .absent]
        #expect(FeatureLibraryStatus.everyFeatureNotice(states) == nil)
        #expect(FeatureLibraryStatus.plainEveryFeatureNotice(states) == nil)
    }

    /// A film still being checked is not a film known to be present.
    @Test func aCheckInFlightBlocksTheNotice() {
        #expect(FeatureLibraryStatus.everyFeatureNotice(
            [Self.present("a.mp4", 1), .checking]) == nil)
    }

    /// More than two counts correctly — the payload is N, never a pair.
    @Test func threeFeaturesCountThemselves() throws {
        let states = (1...3).map { Self.present("f\($0).mp4", 1) }
        #expect(try #require(FeatureLibraryStatus.everyFeatureNotice(states)).contains("All 3"))
        #expect(try #require(FeatureLibraryStatus.plainEveryFeatureNotice(states)).contains("all 3"))
    }

    /// A single-feature disc never shows it: the Confirm step's own duplicate
    /// notice is the established place for that, and two notices saying the
    /// same thing in different words is worse than one.
    @Test func aSingleFeatureDiscNeverShowsTheNotice() {
        #expect(FeatureLibraryStatus.everyFeatureNotice([Self.present("a.mp4", 1)]) == nil)
        #expect(FeatureLibraryStatus.everyFeatureNotice([]) == nil)
    }

    // MARK: - Translating the probe's answer

    @Test func aNamedFilmWithAMatchBecomesPresent() {
        let check = LibraryCheck.done(tmdbID: "2616", .present([
            LibraryEntry(folderName: "Uncle Buck (1989) {tmdb-2616}",
                         folderPath: "/Volumes/Media/Media/Movies/Uncle Buck (1989) {tmdb-2616}",
                         files: [LibraryFile(name: "Uncle Buck (1989).mp4", sizeBytes: 533_136_772)])
        ]))
        guard case .present(let file, let size) =
                FeatureLibraryStatus.state(from: check, hasFilm: true) else {
            Issue.record("expected .present"); return
        }
        #expect(file == "Uncle Buck (1989).mp4")
        #expect(size?.contains("MB") == true)
    }

    /// No film named means no library question, whatever the stale check says.
    @Test func noFilmNamedOverridesAnyStaleAnswer() {
        let stale = LibraryCheck.done(tmdbID: "2616", .absent)
        #expect(FeatureLibraryStatus.state(from: stale, hasFilm: false) == .noFilmNamed)
    }

    @Test func anIdleCheckForANamedFilmReadsAsChecking() {
        #expect(FeatureLibraryStatus.state(from: .idle, hasFilm: true) == .checking)
    }

    @Test func anUnreachableLibraryKeepsItsReason() {
        let check = LibraryCheck.done(tmdbID: "2616", .unreachable(reason: "not mounted"))
        #expect(FeatureLibraryStatus.state(from: check, hasFilm: true)
                == .unreadable(reason: "not mounted"))
    }
}

/// #0161 — the controller side: one answer per feature, and it never shows
/// under the wrong film.
@MainActor
@Suite struct FeatureLibraryCheckTests {

    private static func settings() -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.plexMediaRoot = NSTemporaryDirectory()
        return s
    }

    private static func jobs() -> JobController {
        let c = JobController(
            runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject)
        c.insertedDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
            deviceNode: "disk4", discID: "disc-ub")
        let outdoors = DiscTitle(index: 1, durationSeconds: 5_425, chapterCount: 17,
                                 sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
        let buck = DiscTitle(index: 2, durationSeconds: 5_978, chapterCount: 17,
                             sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
        c.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "UNCLE_BUCK_GREAT_OUTDOORS", driveName: "disk4",
                           titles: [outdoors, buck]),
            mainFeatureIndex: 1, warnings: []))
        return c
    }

    private static func movie(id: Int, title: String) throws -> TMDBMovie {
        try JSONDecoder().decode(TMDBMovie.self, from: Data(
            #"{"id": \#(id), "title": "\#(title)", "release_date": "1989-01-01", "poster_path": null}"#.utf8))
    }

    private static func entry(_ file: String) -> LibraryLookup {
        .present([LibraryEntry(folderName: "F", folderPath: "/F",
                               files: [LibraryFile(name: file, sizeBytes: 500_000_000)])])
    }

    /// A film named in one block is asked about, and the answer lands on that
    /// block only.
    @Test func namingAFilmChecksTheLibraryForThatFeatureAlone() async throws {
        let s = Self.settings(), jobs = Self.jobs()
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)

        let model = try #require(flow.featureSearch(2))
        model.results = [try Self.movie(id: 2616, title: "Uncle Buck")]
        flow.selectFeature(movieID: 2616, feature: 2, jobs: jobs, settings: s)

        await flow.checkLibraryForFeature(2, settings: s,
                                          probe: { _, _ in Self.entry("Uncle Buck (1989).mp4") })

        guard case .present(let file, _) = flow.libraryStatus(for: 2) else {
            Issue.record("feature 2 should be present"); return
        }
        #expect(file == "Uncle Buck (1989).mp4")
        #expect(flow.libraryStatus(for: 1) == .noFilmNamed, "the other block was never asked")
    }

    /// Re-picking a film drops the previous answer rather than showing it
    /// under the new name.
    @Test func repickingAFilmClearsItsPreviousAnswer() async throws {
        let s = Self.settings(), jobs = Self.jobs()
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)

        let model = try #require(flow.featureSearch(2))
        model.results = [try Self.movie(id: 2616, title: "Uncle Buck"),
                         try Self.movie(id: 2617, title: "The Great Outdoors")]
        flow.selectFeature(movieID: 2616, feature: 2, jobs: jobs, settings: s)
        await flow.checkLibraryForFeature(2, settings: s,
                                          probe: { _, _ in Self.entry("Uncle Buck (1989).mp4") })

        flow.selectFeature(movieID: 2617, feature: 2, jobs: jobs, settings: s)
        #expect(flow.libraryStatus(for: 2) == .checking,
                "the old film's answer must not sit under the new film's name")
    }

    /// The reported case end to end: both films already there, so the disc
    /// says so once.
    @Test func bothFilmsPresentProducesTheDiscWideNotice() async throws {
        let s = Self.settings(), jobs = Self.jobs()
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)

        for (feature, id, name) in [(1, 2617, "The Great Outdoors"), (2, 2616, "Uncle Buck")] {
            let model = try #require(flow.featureSearch(feature))
            model.results = [try Self.movie(id: id, title: name)]
            flow.selectFeature(movieID: id, feature: feature, jobs: jobs, settings: s)
            await flow.checkLibraryForFeature(feature, settings: s,
                                              probe: { _, _ in Self.entry("\(name).mp4") })
        }

        #expect(FeatureLibraryStatus.everyFeatureNotice(flow.featureLibraryStates) != nil)
    }

    /// A new disc takes its answers with it.
    @Test func aNewDiscClearsEveryFeaturesAnswer() async throws {
        let s = Self.settings(), jobs = Self.jobs()
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)
        let model = try #require(flow.featureSearch(2))
        model.results = [try Self.movie(id: 2616, title: "Uncle Buck")]
        flow.selectFeature(movieID: 2616, feature: 2, jobs: jobs, settings: s)
        await flow.checkLibraryForFeature(2, settings: s,
                                          probe: { _, _ in Self.entry("Uncle Buck (1989).mp4") })

        jobs.scanState = .idle
        jobs.insertedDisc = nil
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)
        #expect(flow.featureLibraryStates.isEmpty)
    }
}
