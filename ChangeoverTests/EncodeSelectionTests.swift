import Foundation
import Testing
@testable import Changeover

/// Covers #0027's `EncodeSelection.make(request:disc:)` — the one place a
/// `RipRequest` meets the scan it was made against — using the real
/// `Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json` capture for the
/// success case and both of its failure modes.
struct EncodeSelectionTests {

    private static func metadata() -> MovieMetadata {
        MovieMetadata(title: "Blade Runner", year: "1982", tmdbID: "78")
    }

    private static func fixtureDisc() throws -> DiscInfo {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json")
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
        // Track 1 is eng, track 4 is fra — normalized, deduplicated, in
        // first-occurrence order.
        #expect(selection.fallbackAudio == .languages(["eng", "fra"]))
        // The fixture's title 1 is ~23.976 fps, not interlaced — no filter.
        let scannedTitle = try #require(disc.titles.first { $0.index == 1 })
        #expect(selection.filter == DeinterlaceDecision.decide(
            frameRate: scannedTitle.frameRate, interlaceDetected: scannedTitle.interlaceDetected
        ))
        #expect(selection.filter == .none)
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
        // Not a rejection case: `EncodeController.AudioSelection.tracks([])`
        // itself falls back to `.sourceDefault` — `make` doesn't need to
        // special-case emptiness, it just has nothing to reject.
        let disc = try Self.fixtureDisc()
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [])

        let selection = try #require(EncodeSelection.make(request: request, disc: disc))
        #expect(selection.audio == .tracks([]))
    }

    /// A selected untagged track means the language preference can't be
    /// trusted for the fallback re-encode either — every track is kept
    /// rather than a partial or wrong language list.
    @Test func makeFallsBackToEveryLanguageWhenAnySelectedTrackIsUntagged() throws {
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
        #expect(selection.fallbackAudio == .languages([]))
    }

    @Test func phase1MatchesTodaysDefaultBehaviourByteForByte() {
        #expect(EncodeSelection.phase1 == EncodeSelection(
            title: .mainFeature, audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none
        ))
    }
}
