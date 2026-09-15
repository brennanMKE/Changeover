import Foundation
import Testing
@testable import Changeover

/// Covers #0033: collapsing HandBrake's per-variant subtitle stream pairs
/// into logical tracks — against the real
/// `Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json` capture plus
/// synthetic cases for shapes that fixture cannot exercise. `synthetic…`
/// tests are hand-built, not observed on a real disc — Fargo itself (the
/// twelve-into-six case from `MakeMKVReplacement-Results.md` §6) has not
/// been captured; see this issue's "Needs hardware" section.
struct SubtitleGroupingTests {

    // MARK: - Helpers

    private func stream(
        _ index: Int,
        languageCode: String? = "eng",
        languageName: String? = nil,
        variant: String? = "Wide Screen",
        codecId: String = "VOBSUB",
        flags: Int = 0
    ) -> DiscStream {
        DiscStream(
            index: index, kind: .subtitle, codecId: codecId,
            languageCode: languageCode, languageName: languageName,
            variant: variant, flags: flags
        )
    }

    private func title(_ streams: [DiscStream]) -> DiscTitle {
        DiscTitle(index: 0, durationSeconds: 0, chapterCount: 0, sizeBytes: 0,
                  outputFileName: nil, streams: streams)
    }

    // MARK: - Fixture

    private static func fixtureDisc() throws -> DiscInfo {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json")
            .path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return HandBrakeScanParser.parse(text, volumeName: "DRAGON", driveName: "disk6").disc
    }

    /// The plan's "New evidence" case: title 1 has three metadata-identical
    /// `English (Wide Screen)` subtitle tracks (1, 2, 5). Grouping by
    /// (language, role) alone would merge them into one row and hide two
    /// real tracks — they must stay separate because there is only one
    /// variant per bucket, not a pair to collapse.
    @Test func fixtureTitle1HasFiveGroupsNotThree() throws {
        let disc = try Self.fixtureDisc()
        let title1 = try #require(disc.titles.first { $0.index == 1 })
        let groups = SubtitleGrouping.groups(for: title1)

        #expect(groups.count == 5)
        let englishGroups = groups.filter { $0.languageCode == "eng" }
        #expect(englishGroups.count == 3)
        #expect(groups.map(\.selectedTrackNumber).sorted() == [1, 2, 3, 4, 5])
        for group in groups {
            #expect(group.members.count == 1)
        }
    }

    /// #0027's `und` normalization for this fixture's title-4 CC608 stream
    /// (done here on the subtitle side, since #0033 needs it and lands
    /// first): `languageCode == nil`, and `isText` picks up HandBrake's
    /// unprefixed `CC608` `SourceName`.
    @Test func fixtureTitle4CC608IsTextWithNoLanguageCode() throws {
        let disc = try Self.fixtureDisc()
        let title4 = try #require(disc.titles.first { $0.index == 4 })
        let groups = SubtitleGrouping.groups(for: title4)

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.isText)
        #expect(group.languageCode == nil)
    }

    // MARK: - syntheticFargo (MakeMKVReplacement-Results.md §6)

    /// Six logical tracks — English, Français, español, English Forced,
    /// Français Forced, English Director's Commentary — each reported twice
    /// (Wide Screen + Letterbox), the documented 12-into-6 finding this
    /// issue exists to fix. Not captured on a real disc; see "Needs
    /// hardware".
    @Test func syntheticFargoTwelveStreamsCollapseToSixGroups() {
        let streams = [
            stream(1, languageCode: "eng", variant: "Wide Screen"),
            stream(2, languageCode: "eng", variant: "Letterbox"),
            stream(3, languageCode: "fra", variant: "Wide Screen"),
            stream(4, languageCode: "fra", variant: "Letterbox"),
            stream(5, languageCode: "spa", variant: "Wide Screen"),
            stream(6, languageCode: "spa", variant: "Letterbox"),
            stream(7, languageCode: "eng", variant: "Wide Screen", flags: 4096),
            stream(8, languageCode: "eng", variant: "Letterbox", flags: 4096),
            stream(9, languageCode: "fra", variant: "Wide Screen", flags: 4096),
            stream(10, languageCode: "fra", variant: "Letterbox", flags: 4096),
            stream(11, languageCode: "eng", variant: "Wide Screen", flags: 1),
            stream(12, languageCode: "eng", variant: "Letterbox", flags: 1),
        ]
        let groups = SubtitleGrouping.groups(for: title(streams))

        #expect(groups.count == 6)
        for group in groups {
            #expect(group.members.count == 2)
            let variants = group.members.compactMap(\.variant).sorted()
            #expect(variants == ["Letterbox", "Wide Screen"])
            let selectedMember = group.members.first { $0.index == group.selectedTrackNumber }
            #expect(selectedMember?.variant == "Wide Screen")
        }

        // The Forced and Commentary groups never merge into plain English.
        let plainEnglish = groups.filter { $0.languageCode == "eng" && !$0.isForced && !$0.isCommentary }
        let forcedEnglish = groups.filter { $0.languageCode == "eng" && $0.isForced }
        let commentaryEnglish = groups.filter { $0.languageCode == "eng" && $0.isCommentary }
        #expect(plainEnglish.count == 1)
        #expect(forcedEnglish.count == 1)
        #expect(commentaryEnglish.count == 1)
    }

    // MARK: - Shape edge cases (synthetic)

    @Test func syntheticUnevenVariantCountsFallBackToOneGroupPerStream() {
        let streams = [
            stream(1, variant: "Wide Screen"),
            stream(2, variant: "Wide Screen"),
            stream(3, variant: "Letterbox"),
        ]
        let groups = SubtitleGrouping.groups(for: title(streams))
        #expect(groups.count == 3)
        for group in groups { #expect(group.members.count == 1) }
    }

    @Test func syntheticSingleVariantKeepsItsOwnGroup() {
        let streams = [stream(1, variant: "PanScan")]
        let groups = SubtitleGrouping.groups(for: title(streams))
        #expect(groups.count == 1)
        #expect(groups[0].members[0].variant == "PanScan")
        #expect(groups[0].selectedTrackNumber == 1)
    }

    /// "Wide Screen" and "Letterbox" are what the one captured disc emits,
    /// not a closed vocabulary — an unrecognized label is a variant to
    /// carry through, not a parse failure, so it still pairs by position.
    @Test func syntheticUnknownVariantLabelPairsByPositionWithWideScreen() {
        let streams = [
            stream(1, variant: "Wide Screen"),
            stream(2, variant: "Foo"),
        ]
        let groups = SubtitleGrouping.groups(for: title(streams))
        #expect(groups.count == 1)
        #expect(groups[0].members.count == 2)
        #expect(groups[0].selectedTrackNumber == 1)
    }

    @Test func syntheticNilVariantStaysItsOwnGroup() {
        let streams = [stream(1, variant: nil)]
        let groups = SubtitleGrouping.groups(for: title(streams))
        #expect(groups.count == 1)
        #expect(groups[0].members[0].variant == nil)
    }

    @Test func syntheticNoStreamIsEverLost() {
        let streams = [
            stream(1, languageCode: "eng", variant: "Wide Screen"),
            stream(2, languageCode: "eng", variant: "Letterbox"),
            stream(3, languageCode: "eng", variant: "Wide Screen"),
            stream(4, languageCode: "fra", variant: "PanScan"),
        ]
        let groups = SubtitleGrouping.groups(for: title(streams))
        let total = groups.reduce(0) { $0 + $1.members.count }
        #expect(total == streams.count)
    }

    /// #0027 review: the bucket key goes through `LanguageCode.normalize`,
    /// so a `fre` stream and a `fra` stream from the same logical track pair
    /// across variants instead of splitting into two rows.
    @Test func syntheticBibliographicAndTerminologicCodesBucketTogether() {
        let streams = [
            stream(1, languageCode: "fre", variant: "Wide Screen"),
            stream(2, languageCode: "fra", variant: "Letterbox"),
        ]
        let groups = SubtitleGrouping.groups(for: title(streams))
        #expect(groups.count == 1)
        #expect(groups.first?.languageCode == "fra")
    }

    @Test func groupsForATitleWithNoSubtitlesIsEmpty() {
        let groups = SubtitleGrouping.groups(for: title([]))
        #expect(groups.isEmpty)
    }
}
