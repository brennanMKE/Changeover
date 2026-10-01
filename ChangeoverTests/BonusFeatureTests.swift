import Foundation
import Testing
@testable import Changeover

/// #0174 — discovering, naming and filing a disc's substantial bonus feature.
///
/// Signs (`vol-signs-8224851968`, captured 2026-10-01) is the disc that asked
/// for this. Title 1 is the film at 1:46:25; title 8 is a 58:54 bonus reel;
/// titles 9–14 are the six featurettes its bonus menu names, each printed with
/// its runtime. #0173 stopped the app calling title 8 a second film and then
/// threw it away — this is the other half of that judgement.
@Suite struct BonusFeatureDiscoveryTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.33)
    }

    /// The disc as captured.
    private static var signs: DiscInfo {
        DiscInfo(volumeName: "Signs", driveName: "disk4", titles: [
            DiscTitle(index: 1, durationSeconds: 6385, chapterCount: 22,
                      sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
            title(8, seconds: 3534),    // the bonus reel — 58:54
            title(9, seconds: 375),     // looking for Signs
            title(10, seconds: 485),    // building Signs
            title(11, seconds: 1357),   // making Signs: a commentary
            title(12, seconds: 516),    // the effects of Signs
            title(13, seconds: 510),    // last voices
            title(14, seconds: 291),    // full circle
        ])
    }

    /// The title #0173 refuses as a second film is the one nominated here.
    @Test func theBonusReelIsFound() {
        let found = BonusFeature.candidates(in: Self.signs, featureIndex: 1)
        #expect(found.map(\.index) == [8])
    }

    /// The film is never its own bonus feature.
    @Test func theFeatureIsNeverNominated() {
        let found = BonusFeature.candidates(in: Self.signs, featureIndex: 1)
        #expect(!found.contains { $0.index == 1 })
    }

    /// The short extras are the user's own business (`ExtrasPlan`), not an
    /// automatic rule's. Only titles over the feature floor come here.
    @Test func shortExtrasAreNotBonusFeatures() {
        let found = BonusFeature.candidates(in: Self.signs, featureIndex: 1)
        #expect(!found.contains { [9, 10, 11, 12, 13, 14].contains($0.index) },
                "22 minutes is an extra, not a bonus feature")
    }

    /// A title long enough to BE a second feature must never be quietly
    /// re-filed as an extra — that is `DiscTitleHeuristic`'s decision, and
    /// silently demoting a film is the worst outcome available here.
    @Test func asecondFeatureIsNotDemotedToAnExtra() {
        let doubleFeature = DiscInfo(volumeName: "D", driveName: "disk4", titles: [
            Self.title(1, seconds: 6012),   // 100m
            Self.title(2, seconds: 5122),   // 85m — ratio 0.852
        ])
        #expect(BonusFeature.candidates(in: doubleFeature, featureIndex: 1).isEmpty)
        #expect(DiscTitleHeuristic.severalFeatures(doubleFeature)?.count == 2)
    }

    /// The two rules are one comparison, so they cannot disagree: every title
    /// is either a second feature or a bonus feature, never both and never
    /// neither.
    @Test func theTwoRulesPartitionTheCandidates() {
        let found = BonusFeature.candidates(in: Self.signs, featureIndex: 1)
        #expect(DiscTitleHeuristic.severalFeatures(Self.signs) == nil)
        #expect(found.count == 1, "the one title over the floor that is not a film")
    }
}

/// #0174 — Plex's extras convention, and why only it may sit under `Movies/`.
@Suite struct PlexExtraNamingTests {

    /// Spelling is not cosmetic: Plex matches these names, and a near miss is
    /// an unrecognised folder, which Plex scans as a film.
    @Test func theFolderNamesAreSpelledAsPlexSpellsThem() {
        #expect(PlexExtra.Kind.behindTheScenes.folderName == "Behind The Scenes")
        #expect(PlexExtra.Kind.deletedScenes.folderName == "Deleted Scenes")
        #expect(PlexExtra.Kind.featurettes.folderName == "Featurettes")
        #expect(PlexExtra.recognisedFolderNames.count == PlexExtra.Kind.allCases.count)
    }

    @Test func recognitionIsCaseInsensitiveButNotLoose() {
        #expect(PlexExtra.isRecognisedFolder("Behind The Scenes"))
        #expect(PlexExtra.isRecognisedFolder("behind the scenes"))
        #expect(!PlexExtra.isRecognisedFolder("Behind The Scene"))
        #expect(!PlexExtra.isRecognisedFolder("Bonus"))
        #expect(!PlexExtra.isRecognisedFolder(".."))
    }

    /// The labels this disc actually prints.
    @Test func signsOwnLabelsGetSensibleKinds() {
        #expect(PlexExtra.kind(forLabel: "looking for Signs") == .behindTheScenes)
        #expect(PlexExtra.kind(forLabel: "building Signs") == .behindTheScenes)
        #expect(PlexExtra.kind(forLabel: "making Signs: a commentary") == .behindTheScenes)
        #expect(PlexExtra.kind(forLabel: "the effects of Signs") == .featurettes)
        #expect(PlexExtra.kind(forLabel: "last voices: the music of Signs") == .featurettes)
        #expect(PlexExtra.kind(forLabel: "full circle") == .featurettes)
    }

    @Test func theOtherKindsAreReachable() {
        #expect(PlexExtra.kind(forLabel: "Deleted Scenes") == .deletedScenes)
        #expect(PlexExtra.kind(forLabel: "Theatrical Trailer") == .trailers)
        #expect(PlexExtra.kind(forLabel: "Interview with the director") == .interviews)
        #expect(PlexExtra.kind(forLabel: "") == .other)
    }

    /// A label is disc text about to become a path component (#0010).
    @Test func alabelIsSanitisedBeforeItIsAPath() {
        #expect(PlexExtra.sanitize("making Signs: a commentary") == "making Signs- a commentary")
        #expect(PlexExtra.sanitize("../../Movies") == "--Movies")
        #expect(PlexExtra.sanitize("..") == "")
        #expect(PlexExtra.sanitize(".hidden") == "hidden")
        #expect(PlexExtra.sanitize("trailing. ") == "trailing")
    }

    @Test func anEmptyLabelStillProducesAUniqueName() {
        #expect(PlexExtra.fileName(label: "", titleIndex: 8, extension: "mp4")
                == "Bonus Feature - t08.mp4")
        #expect(PlexExtra.fileName(label: "full circle", titleIndex: 14, extension: "mp4")
                == "full circle.mp4")
    }
}

/// #0174 — the resolved path, which is what Plex actually reads.
@Suite struct BonusFeatureDestinationTests {

    private static let roots = LibraryRoots(mediaRoot: "/Media")

    private static var signs: MovieMetadata {
        MovieMetadata(title: "Signs", year: "2002", tmdbID: "452")
    }

    @Test func thebonusFeatureLandsInsideTheFilmsFolder() {
        let resolved = LibraryPaths.resolve(
            .bonusFeature(titleIndex: 9, kind: .behindTheScenes, label: "looking for Signs"),
            metadata: Self.signs, roots: Self.roots, sourceExtension: "mp4")
        #expect(resolved.folder == "/Media/Movies/Signs (2002) {tmdb-452}/Behind The Scenes")
        #expect(resolved.file ==
                "/Media/Movies/Signs (2002) {tmdb-452}/Behind The Scenes/looking for Signs.mp4")
    }

    /// The film itself is untouched — the strict convention still holds.
    @Test func thefeatureStillSitsWhereItAlwaysDid() {
        let resolved = LibraryPaths.resolve(
            .feature, metadata: Self.signs, roots: Self.roots, sourceExtension: "mp4")
        #expect(resolved.file == "/Media/Movies/Signs (2002) {tmdb-452}/Signs (2002).mp4")
    }

    /// `.extra` is unchanged: it still goes to the non-Plex Clips tree.
    @Test func theOldExtraDestinationIsUnchanged() {
        let resolved = LibraryPaths.resolve(
            .extra(titleIndex: 9), metadata: Self.signs, roots: Self.roots, sourceExtension: "mp4")
        #expect(resolved.folder == "/Media/Clips/Signs (2002) {tmdb-452}")
    }

    /// A label that tries to climb out of the folder cannot.
    @Test func alabelCannotEscapeTheExtrasFolder() {
        let resolved = LibraryPaths.resolve(
            .bonusFeature(titleIndex: 9, kind: .featurettes, label: "../../../etc/passwd"),
            metadata: Self.signs, roots: Self.roots, sourceExtension: "mp4")
        #expect(resolved.file.hasPrefix("/Media/Movies/Signs (2002) {tmdb-452}/Featurettes/"))
        #expect(!resolved.file.contains(".."))
    }
}

/// #0174 — naming the bonus titles from the labels the disc's menu printed.
@Suite struct MenuExtraLabelTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.33)
    }

    /// The bonus menu's OCR, exactly as captured.
    private static let bonusMenu = [
        "play all",
        "looking for Signs (6:11)",
        "building Signs (8:02)",
        "making Signs: a commentary",
        "by M. Night Shyamalan (22:33)",
        "the effects of Signs (8:31)",
        "last voices: the music›",
        "of Signs (8:26)",
        "full circle (4:48)",
        "bonus",
    ]

    @Test func atrailingRuntimeIsReadOffTheLabel() throws {
        let printed = try #require(MenuExtraLabels.printed(from: "looking for Signs (6:11)"))
        #expect(printed.label == "looking for Signs")
        #expect(printed.seconds == 371)
    }

    @Test func anHourLongRuntimeReads() throws {
        let printed = try #require(MenuExtraLabels.printed(from: "the whole thing (1:22:33)"))
        #expect(printed.seconds == 4953)
    }

    /// A bracket that is not a runtime leaves the label whole — a year and an
    /// edition both live in brackets and neither is a duration.
    @Test func brackersThatAreNotRuntimesAreIgnored() {
        #expect(MenuExtraLabels.printed(from: "Alien (Director's Cut)") == nil)
        #expect(MenuExtraLabels.printed(from: "Signs (2002)") == nil)
        #expect(MenuExtraLabels.printed(from: "play all") == nil)
        // 61:00 IS a duration — 61 minutes. Only the trailing fields are
        // bounded, because the leading one may be hours or minutes.
        #expect(MenuExtraLabels.duration("61:00") == 3660)
        #expect(MenuExtraLabels.duration("6:70") == nil, "seconds over 59 is not a duration")
        #expect(MenuExtraLabels.duration("6:1") == nil, "seconds must be two digits")
    }

    /// The measured result: six labels onto six titles, every one inside five
    /// seconds, no collisions.
    @Test func theSignsBonusMenuNamesEveryBonusTitle() {
        let titles = [
            Self.title(9, seconds: 375), Self.title(10, seconds: 485),
            Self.title(11, seconds: 1357), Self.title(12, seconds: 516),
            Self.title(13, seconds: 510), Self.title(14, seconds: 291),
        ]
        let matches = MenuExtraLabels.match(
            printed: MenuExtraLabels.printedLabels(in: Self.bonusMenu), to: titles)

        #expect(matches.count == 6)
        #expect(matches.map(\.titleIndex) == [9, 10, 11, 12, 13, 14])
        #expect(matches.first { $0.titleIndex == 9 }?.label == "looking for Signs")
        #expect(matches.first { $0.titleIndex == 11 }?.label == "by M. Night Shyamalan",
                "the OCR split this label across two lines — the runtime is on the second")
        #expect(matches.first { $0.titleIndex == 14 }?.label == "full circle")
        for match in matches { #expect(match.offBySeconds <= 5) }
    }

    /// One title, one label — two extras are two different videos.
    @Test func atitleIsNeverNamedTwice() {
        let titles = [Self.title(9, seconds: 375), Self.title(10, seconds: 376)]
        let matches = MenuExtraLabels.match(printed: [
            MenuExtraLabels.Printed(label: "first", seconds: 375),
            MenuExtraLabels.Printed(label: "second", seconds: 375),
        ], to: titles)
        #expect(Set(matches.map(\.titleIndex)).count == matches.count)
    }

    /// A label matching nothing is dropped, not forced onto the nearest title.
    @Test func alabelThatFitsNothingIsDropped() {
        let matches = MenuExtraLabels.match(printed: [
            MenuExtraLabels.Printed(label: "nowhere", seconds: 9_999),
        ], to: [Self.title(9, seconds: 375)])
        #expect(matches.isEmpty)
    }
}
