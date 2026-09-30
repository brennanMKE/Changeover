import Foundation
import Testing
@testable import Changeover

/// #0172 — the three faults visible in one screenshot from joe, 2026-09-30.
///
/// The app had correctly placed The Campaign on title 4 (85 min) and Get Hard
/// on title 5 (100 min). One re-search of title 4 for Get Hard produced:
/// Get Hard sitting on the 85-minute title, title 5 suddenly blank with its
/// search box still showing Get Hard ticked, and Continue enabled. One click,
/// three wrong things, and not a word about any of them.
@Suite struct DuplicateFilmChoiceTests {

    private func selection(_ features: [Int]) -> FeatureSelection {
        var s = FeatureSelection()
        s.setFeatures(features)
        return s
    }

    /// The regression. #0169 moved the film; it is now refused.
    @Test func thesSameFilmIsRefusedRatherThanMoved() {
        var s = selection([4, 5])
        s.choose(movieID: 77953, for: 4)
        s.choose(movieID: 257091, for: 5)
        s.choose(movieID: 257091, for: 4)   // the user's re-search

        #expect(s.movieID(for: 4) == 77953, "title 4 keeps the film it had")
        #expect(s.movieID(for: 5) == 257091, "and title 5 is not emptied behind their back")
        #expect(s.runnableFeatures.count == 2)
    }

    /// And it says so, naming the feature that holds it.
    @Test func theRefusalIsRecordedWithBothEnds() throws {
        var s = selection([4, 5])
        s.choose(movieID: 77953, for: 4)
        s.choose(movieID: 77953, for: 5)

        let rejection = try #require(s.alreadyChosenElsewhere)
        #expect(rejection.feature == 5)
        #expect(rejection.movieID == 77953)
        #expect(rejection.heldBy == 4)
    }

    /// A refusal describes only the last click.
    @Test func aGoodChoiceClearsTheRefusal() {
        var s = selection([4, 5])
        s.choose(movieID: 77953, for: 4)
        s.choose(movieID: 77953, for: 5)
        #expect(s.alreadyChosenElsewhere != nil)
        s.choose(movieID: 257091, for: 5)
        #expect(s.alreadyChosenElsewhere == nil)
        #expect(s.movieID(for: 5) == 257091)
    }

    @Test func clearingAFeatureClearsTheRefusal() {
        var s = selection([4, 5])
        s.choose(movieID: 77953, for: 4)
        s.choose(movieID: 77953, for: 5)
        s.choose(movieID: nil, for: 5)
        #expect(s.alreadyChosenElsewhere == nil)
    }

    /// Re-picking the film a feature already has is not a duplicate.
    @Test func choosingTheSameFilmForTheSameFeatureIsFine() {
        var s = selection([4, 5])
        s.choose(movieID: 77953, for: 4)
        s.choose(movieID: 77953, for: 4)
        #expect(s.movieID(for: 4) == 77953)
        #expect(s.alreadyChosenElsewhere == nil)
    }

    /// A refusal belongs to the disc it was refused on.
    @Test func aNewDiscClearsTheRefusal() {
        var s = selection([4, 5])
        s.choose(movieID: 77953, for: 4)
        s.choose(movieID: 77953, for: 5)
        s.setFeatures([1, 2])
        #expect(s.alreadyChosenElsewhere == nil)
    }

    /// Freeing the film first is the way through, and it works.
    @Test func changingTheOtherFeatureFirstLetsThePickThrough() {
        var s = selection([4, 5])
        s.choose(movieID: 257091, for: 5)
        s.choose(movieID: 257091, for: 4)   // refused
        #expect(s.movieID(for: 4) == nil)
        s.choose(movieID: nil, for: 5)      // "Change" on the other row
        s.choose(movieID: 257091, for: 4)
        #expect(s.movieID(for: 4) == 257091)
        #expect(s.alreadyChosenElsewhere == nil)
    }
}

/// #0172 — a film that does not fit its title must stop Continue, not wait for
/// the Start gate two steps later to say `runtimeMismatchUnconfirmed`.
@Suite struct MisfitBlocksContinueTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 11,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }

    /// The measured case: Get Hard, 100 minutes, on the 85-minute title.
    @Test func getHardOnTheCampaignsTitleIsAMismatch() {
        let titles = [Self.title(4, seconds: 5122), Self.title(5, seconds: 6012)]
        let verdict = FeatureFit.judge(runtimeMinutes: 100, feature: titles[0],
                                       allFeatures: titles)
        guard case .mismatch(let offBy, let better) = verdict else {
            Issue.record("100 min on an 85-minute title must not pass")
            return
        }
        #expect(offBy > 14)
        #expect(better == 5, "and it names the title it does belong on")
    }

    /// The correct placement still passes, so the gate is not simply closed.
    @Test func theRightPlacementFits() {
        let titles = [Self.title(4, seconds: 5122), Self.title(5, seconds: 6012)]
        #expect(FeatureFit.judge(runtimeMinutes: 85, feature: titles[0],
                                 allFeatures: titles) == .fits)
        #expect(FeatureFit.judge(runtimeMinutes: 100, feature: titles[1],
                                 allFeatures: titles) == .fits)
    }

    /// The wording the settled row now carries — it used to appear only
    /// inside an open search block.
    @Test func theRowCanSayWhereTheFilmBelongs() throws {
        let titles = [Self.title(4, seconds: 5122), Self.title(5, seconds: 6012)]
        let verdict = FeatureFit.judge(runtimeMinutes: 100, feature: titles[0],
                                       allFeatures: titles)
        let wording = try #require(FeatureFit.wording(verdict, positionOfBetterFeature: 2, count: 2))
        #expect(wording.plain == "This looks like Movie 2 of 2, not this one.")
    }
}

/// #0172 — the per-feature library check must run for a film the APP named,
/// not only for one the user is looking at.
///
/// #0161 hung the probe on `FeatureSearchBlock.task`, correct while every
/// feature had a search block. #0169 collapsed a named feature to a plain row
/// with no task, so on a disc the app identifies by itself the probe never ran
/// for either film. `importableFeatureCount` counts an unchecked film as
/// importable, the Start gate read `ready`, and the Get Hard / The Campaign
/// disc sat in the drive on 2026-09-30 with both films already filed as
/// {tmdb-257091} and {tmdb-77953}.
@Suite struct FeatureLibraryProbeRunsTests {

    /// A library folder named the way `MovieMetadata.folderName` names them.
    private static func entry(_ tmdbID: String) -> LibraryEntry {
        let folder = "Film (2000) {tmdb-\(tmdbID)}"
        return LibraryEntry(
            folderName: folder,
            folderPath: "/Movies/\(folder)",
            files: [LibraryFile(name: "Film (2000).mp4", sizeBytes: 1)])
    }

    private static func controller(features: [Int]) -> RipFlowController {
        let flow = RipFlowController()
        flow.adoptFeaturesForTesting(features)
        return flow
    }

    /// Both films held: every feature reports `.present`, nothing is
    /// importable, and that is what makes the disc ejectable.
    @Test func bothFilmsHeldLeavesNothingImportable() async {
        let flow = Self.controller(features: [4, 5])
        flow.chooseForTesting(movieID: 77953, feature: 4)
        flow.chooseForTesting(movieID: 257091, feature: 5)

        let settings = AppSettings(defaults: UserDefaults(suiteName: #function)!)
        settings.plexMediaRoot = "/tmp/does-not-matter"
        for feature in [4, 5] {
            await flow.checkLibraryForFeature(feature, settings: settings) { _, tmdbID in
                .present([Self.entry(tmdbID)])
            }
        }
        #expect(flow.importableFeatureCount == 0)
    }

    /// One held, one not: the disc still has work, so it must not be ejected.
    @Test func oneFilmMissingKeepsTheDisc() async {
        let flow = Self.controller(features: [4, 5])
        flow.chooseForTesting(movieID: 77953, feature: 4)
        flow.chooseForTesting(movieID: 257091, feature: 5)

        let settings = AppSettings(defaults: UserDefaults(suiteName: #function)!)
        settings.plexMediaRoot = "/tmp/does-not-matter"
        await flow.checkLibraryForFeature(4, settings: settings) { _, tmdbID in
            .present([Self.entry(tmdbID)])
        }
        await flow.checkLibraryForFeature(5, settings: settings) { _, _ in .absent }
        #expect(flow.importableFeatureCount == 1)
    }

    /// An unchecked film counts as importable — which is correct, and exactly
    /// why never running the check made the disc look like it had work to do.
    @Test func anUncheckedFilmCountsAsImportable() {
        let flow = Self.controller(features: [4, 5])
        flow.chooseForTesting(movieID: 77953, feature: 4)
        flow.chooseForTesting(movieID: 257091, feature: 5)
        #expect(flow.importableFeatureCount == 2,
                "no answer is not the answer 'already held'")
    }
}
