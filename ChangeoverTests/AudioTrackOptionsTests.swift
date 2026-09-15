import Foundation
import Testing
@testable import Changeover

/// Covers #0027's audio-track picker rules: deduplication of tagged tracks
/// against the real `Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json`
/// capture, plus synthetic cases for shapes that fixture cannot exercise —
/// most importantly the untagged whole-title fallback (the Hornets' Nest
/// silent-MP4 risk this issue's Description calls out first).
struct AudioTrackOptionsTests {

    // MARK: - Helpers

    private func audioStream(
        _ index: Int,
        languageCode: String? = "eng",
        codecId: String = "A_AC3",
        bitrate: String? = "448000",
        channelCount: Int? = 6,
        displayName: String? = "DD Surround 5.1 English",
        flags: Int = 0
    ) -> DiscStream {
        DiscStream(
            index: index, kind: .audio, codecId: codecId,
            languageCode: languageCode, displayName: displayName,
            bitrate: bitrate, channelCount: channelCount, flags: flags
        )
    }

    private func title(_ streams: [DiscStream], index: Int = 9) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: 0, chapterCount: 0, sizeBytes: 0,
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

    // MARK: - Fixture: deduplication

    /// Title 1's five audio streams (`eng 448k 5.1`, `eng 192k stereo`,
    /// duplicate of each, plus `fra 448k 5.1`) reduce to three distinct
    /// offerings — tracks 1, 2 and 4 — with 3 folded into 1 and 5 into 2.
    @Test func fixtureTitle1AudioOptionsDeduplicateToThreeTracks() throws {
        let disc = try Self.fixtureDisc()
        let title1 = try #require(disc.titles.first { $0.index == 1 })

        let options = AudioTrackOptions.options(for: title1)

        #expect(options.map(\.trackNumber) == [1, 2, 4])
        #expect(options.map(\.duplicateTrackNumbers) == [[3], [5], []])
        #expect(options.map(\.languageCode) == ["eng", "eng", "fra"])
        #expect(AudioTrackOptions.isUntagged(title1) == false)
    }

    @Test func fixtureTitle1PreselectionMatchesPreferredLanguages() throws {
        let disc = try Self.fixtureDisc()
        let title1 = try #require(disc.titles.first { $0.index == 1 })
        let options = AudioTrackOptions.options(for: title1)

        #expect(AudioTrackOptions.preselection(options, preferred: ["eng", "spa"], untagged: false) == [1, 2])
        #expect(AudioTrackOptions.preselection(options, preferred: ["fra"], untagged: false) == [4])
        // Nothing matches "spa" on this disc — falls back to the first option.
        #expect(AudioTrackOptions.preselection(options, preferred: ["spa"], untagged: false) == [1])
    }

    // MARK: - Synthetic: the whole-title no-language fallback (Hornets' Nest)

    /// The silent-movie test: a title whose audio streams carry *no*
    /// language tag at all must keep every track rather than dropping to
    /// "first track only" (which looks identical in the UI and is wrong on
    /// a disc with an English and a Spanish track under the hood) or to
    /// nothing at all (a preference filter matching zero tracks).
    @Test func syntheticUntaggedTitleNeverMergesAndKeepsBothTracks() {
        let untitled = title([
            audioStream(1, languageCode: nil, displayName: "DD Surround 5.1"),
            audioStream(2, languageCode: nil, displayName: "DD Surround 5.1"),
        ])

        let options = AudioTrackOptions.options(for: untitled)

        #expect(options.count == 2)
        #expect(options.map(\.trackNumber) == [1, 2])
        #expect(options.allSatisfy { $0.duplicateTrackNumbers.isEmpty })
        #expect(AudioTrackOptions.isUntagged(untitled) == true)

        let preselected = AudioTrackOptions.preselection(options, preferred: ["eng", "spa"], untagged: true)
        #expect(Set(preselected) == Set([1, 2]))
    }

    /// A *single* untagged stream among tagged siblings is not the
    /// whole-title fallback — `isUntagged` stays false, and the untagged
    /// stream is simply never merged with anything.
    @Test func syntheticOneUntaggedStreamAmongTaggedSiblingsIsNotTheWholeTitleFallback() {
        let mixed = title([
            audioStream(1, languageCode: "eng"),
            audioStream(2, languageCode: nil, displayName: "Unknown"),
        ])

        #expect(AudioTrackOptions.isUntagged(mixed) == false)
        let options = AudioTrackOptions.options(for: mixed)
        #expect(options.map(\.trackNumber) == [1, 2])
        #expect(options[1].languageCode == nil)
    }

    // MARK: - Synthetic: commentary is flagged, never merged, never preselected

    @Test func syntheticCommentaryTrackIsNotMergedAndNotPreselected() {
        let withCommentary = title([
            audioStream(1, flags: 0),
            // Otherwise identical metadata, but flags == 1 (commentary):
            // must not merge into track 1 even though every other field matches.
            audioStream(2, flags: 1),
        ])

        let options = AudioTrackOptions.options(for: withCommentary)
        #expect(options.count == 2)
        #expect(options[0].isCommentary == false)
        #expect(options[1].isCommentary == true)
        #expect(options[0].duplicateTrackNumbers.isEmpty)
        #expect(options[1].duplicateTrackNumbers.isEmpty)

        let preselected = AudioTrackOptions.preselection(options, preferred: ["eng"], untagged: false)
        #expect(preselected == [1])
    }

    /// If every option on a title is flagged commentary (a pathological but
    /// possible scan), the first one is still selected — the result is
    /// never empty for a title that has audio.
    @Test func syntheticAllCommentaryTracksStillPreselectsTheFirst() {
        let allCommentary = title([
            audioStream(1, flags: 1),
            audioStream(2, displayName: "Director's Commentary", flags: 2),
        ])
        let options = AudioTrackOptions.options(for: allCommentary)
        #expect(options.allSatisfy { $0.isCommentary })

        let preselected = AudioTrackOptions.preselection(options, preferred: ["eng"], untagged: false)
        #expect(preselected == [1])
    }

    // MARK: - Synthetic: forced (4096) is not treated as commentary

    @Test func forcedFlagIsNotCommentary() {
        let stream = audioStream(1, flags: 4096)
        #expect(stream.isCommentary == false)
        #expect(stream.isForced == true)
    }
}
