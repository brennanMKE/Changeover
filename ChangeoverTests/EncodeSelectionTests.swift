import Foundation
import Testing
@testable import Changeover

/// Covers #0027's `EncodeSelection.make(request:disc:)` — the one place a
/// `RipRequest` meets the scan it was made against — using the real
/// `Fixtures/discs/dragon-tattoo/scan.json` capture for the
/// success case and both of its failure modes.
struct EncodeSelectionTests {

    private static func metadata() -> MovieMetadata {
        MovieMetadata(title: "Blade Runner", year: "1982", tmdbID: "78")
    }

    private static func fixtureDisc() throws -> DiscInfo {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/dragon-tattoo/scan.json")
            .path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return HandBrakeScanParser.parse(text, volumeName: "DRAGON", driveName: "disk6").disc
    }

    @Test func makeBuildsTracksLanguagesAndFilterFromTheFixture() throws {
        let disc = try Self.fixtureDisc()
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [1, 4])

        let selection = try #require(EncodeSelection.make(request: request, disc: disc))

        #expect(selection.title == .index(1))
        #expect(selection.audio == .tracks([1, 4]))
        // #0027 review: the MakeMKV fallback keeps its verified default audio
        // until `.languages` is checked on real HandBrake.
        #expect(selection.fallbackAudio == .sourceDefault)
        // The fixture's title 1 is ~23.976 fps, not interlaced — no filter.
        let scannedTitle = try #require(disc.titles.first { $0.index == 1 })
        #expect(selection.filter == DeinterlaceDecision.decide(
            frameRate: scannedTitle.frameRate, interlaceDetected: scannedTitle.interlaceDetected
        ))
        #expect(selection.filter == .none)
        // #0035: the chosen title's own scanned duration travels with the
        // selection, for the MakeMKV fallback to match against.
        #expect(selection.featureDurationSeconds == scannedTitle.durationSeconds)
    }

    /// #0059: `keepOriginalAudioTrack` defaults to `false` (AAC stereo
    /// only) and threads through to `AudioSelection.tracks` when the
    /// caller opts in.
    @Test func makeDefaultsToNotKeepingTheOriginalTrack() throws {
        let disc = try Self.fixtureDisc()
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [1, 4])

        let selection = try #require(EncodeSelection.make(request: request, disc: disc))
        #expect(selection.audio == .tracks([1, 4], keepOriginal: false))
    }

    @Test func makeThreadsKeepOriginalAudioTrackIntoTheAudioSelection() throws {
        let disc = try Self.fixtureDisc()
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [1, 4])

        let selection = try #require(EncodeSelection.make(request: request, disc: disc, keepOriginalAudioTrack: true))
        #expect(selection.audio == .tracks([1, 4], keepOriginal: true))
    }

    @Test func makeReturnsNilForAFeatureTitleNotOnTheDisc() throws {
        let disc = try Self.fixtureDisc()
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 99, audioTrackNumbers: [1])

        #expect(EncodeSelection.make(request: request, disc: disc) == nil)
    }

    @Test func makeReturnsNilForAnAudioTrackNumberNotOnTheTitle() throws {
        let disc = try Self.fixtureDisc()
        // Track 9 does not exist on title 1 (its audio streams are 1-5).
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [9])

        #expect(EncodeSelection.make(request: request, disc: disc) == nil)
    }

    @Test func makeAcceptsAnEmptyAudioTrackListAndFallsBackDownstream() throws {
        // `make` only checks that indices resolve. An empty pick on a title
        // with audio is refused by `StartGate` and `JobController.start`
        // (#0027 review), not here.
        let disc = try Self.fixtureDisc()
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [])

        let selection = try #require(EncodeSelection.make(request: request, disc: disc))
        #expect(selection.audio == .tracks([]))
    }

    /// #0027 review: whatever tracks are selected, tagged or not, the MakeMKV
    /// fallback gets `.sourceDefault`, never an unverified `.languages` list.
    @Test func makeGivesTheFallbackSourceDefaultEvenForUntaggedTracks() throws {
        let title = DiscTitle(
            index: 0, durationSeconds: 100, chapterCount: 1, sizeBytes: 0, outputFileName: nil,
            streams: [
                DiscStream(index: 1, kind: .audio, codecId: "A_AC3", languageCode: nil),
                DiscStream(index: 2, kind: .audio, codecId: "A_AC3", languageCode: "eng"),
            ]
        )
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [title])
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 0, audioTrackNumbers: [1, 2])

        let selection = try #require(EncodeSelection.make(request: request, disc: disc))
        #expect(selection.audio == .tracks([1, 2]))
        #expect(selection.fallbackAudio == .sourceDefault)
    }

    @Test func phase1MatchesTodaysDefaultBehaviourByteForByte() {
        #expect(EncodeSelection.phase1 == EncodeSelection(
            title: .mainFeature, audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none
        ))
        // #0035: `.phase1` never had a scan, so there's no known duration —
        // `MakeMKVRipper.rip` falls back to its pre-#0035 "pick the longest"
        // behaviour whenever this is `nil`.
        #expect(EncodeSelection.phase1.featureDurationSeconds == nil)
    }
}
