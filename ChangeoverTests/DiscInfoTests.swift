import Foundation
import Testing
@testable import Changeover

/// Covers #0022: the disc model round-trips through JSON unchanged, the
/// `flags` derivations behave, `nil` language stays `nil` (the silent-MP4
/// guard), and unknown enum raw values decode leniently. No disc needed.
struct DiscInfoTests {

    // MARK: - Fixtures

    private static func populatedDiscInfo() -> DiscInfo {
        DiscInfo(
            volumeName: "FARGO_SE__16X9",
            driveName: "DVD-optical",
            titles: [
                DiscTitle(
                    index: 0,
                    durationSeconds: 6_911,
                    chapterCount: 16,
                    sizeBytes: 5_848_889_344,
                    outputFileName: "Girl in the Spider's Web, The-B1_t00.mkv",
                    segmentCount: 4,
                    streams: [
                        DiscStream(index: 0, kind: .video, codecId: "V_MPEG2", codecShort: "MPEG-2",
                                   displayName: "B1", isDefault: true),
                        DiscStream(index: 1, kind: .audio, codecId: "A_AC3", codecShort: "AC3",
                                   languageCode: "eng", languageName: "English",
                                   displayName: "DTS 5.1", bitrate: "448 Kb/s",
                                   channelCount: 6, isDefault: true, flags: 0),
                        DiscStream(index: 2, kind: .audio, codecId: "A_AC3", codecShort: "AC3",
                                   languageCode: "eng", languageName: "English",
                                   displayName: "Commentary", flags: 1),
                        DiscStream(index: 3, kind: .subtitle, codecId: "S_VOBSUB",
                                   languageCode: "eng", languageName: "English", flags: 4096),
                        DiscStream(index: 4, kind: .subtitle, codecId: "S_CC608/DVD",
                                   languageCode: nil, languageName: nil),
                    ],
                    suggestedRole: .mainFeature,
                    frameRate: 23.976,
                    interlaceDetected: false
                ),
                DiscTitle(
                    index: 1,
                    durationSeconds: 13,
                    chapterCount: 1,
                    sizeBytes: 12_345_678,
                    outputFileName: "D1_t01.mkv",
                    suggestedRole: .ignore
                ),
            ]
        )
    }

    // MARK: - Round trip

    @Test func populatedDiscInfoRoundTripsThroughJSONUnchanged() throws {
        let original = Self.populatedDiscInfo()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiscInfo.self, from: data)
        #expect(decoded == original)
    }

    /// The silent-MP4 guard: an untagged stream's `nil` languageCode must
    /// survive the wire as `nil`, never become `""` or a default language.
    @Test func nilLanguageCodeRoundTripsAsNilNotEmptyString() throws {
        let stream = DiscStream(index: 0, kind: .subtitle, codecId: "S_CC608/DVD")
        let data = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode(DiscStream.self, from: data)
        #expect(decoded.languageCode == nil)
        #expect(decoded.languageName == nil)

        // And at the disc level, the hornets-nest shape: a whole disc with
        // no attribute 3 anywhere.
        let title = DiscTitle(index: 0, durationSeconds: 1, chapterCount: 1, sizeBytes: 1,
                              outputFileName: "x.mkv",
                              streams: [DiscStream(index: 0, kind: .audio, codecId: "A_AC3")])
        let titleData = try JSONEncoder().encode(title)
        let decodedTitle = try JSONDecoder().decode(DiscTitle.self, from: titleData)
        #expect(decodedTitle.streams[0].languageCode == nil)
    }

    /// A payload from an older host without the #0016 fields decodes to nil
    /// (unknown) rather than failing — additive fields only, forever.
    @Test func olderPayloadWithoutFrameRateDecodesToNil() throws {
        let json = """
        {"index": 0, "durationSeconds": 100, "chapterCount": 1, "sizeBytes": 5,
         "outputFileName": "B1_t00.mkv", "suggestedRole": "mainFeature"}
        """
        let title = try JSONDecoder().decode(DiscTitle.self, from: Data(json.utf8))
        #expect(title.frameRate == nil)
        #expect(title.interlaceDetected == nil)
        #expect(title.streams.isEmpty)
    }

    // MARK: - Duration accessor

    @Test func durationAccessorIsDerivedFromSeconds() {
        let title = DiscTitle(index: 0, durationSeconds: 6_911, chapterCount: 1,
                              sizeBytes: 1, outputFileName: "x.mkv")
        #expect(title.duration == .seconds(6_911))
    }

    // MARK: - Identifiable stability

    @Test func idIsTheIndexNotSomethingElse() {
        let title = DiscTitle(index: 7, durationSeconds: 1, chapterCount: 1,
                              sizeBytes: 1, outputFileName: "x.mkv")
        #expect(title.id == 7)
        let stream = DiscStream(index: 3, kind: .audio, codecId: "A_AC3")
        #expect(stream.id == 3)
    }

    // MARK: - Lenient enum decoding

    @Test func unknownRoleRawValueFallsBackToExtra() throws {
        let json = """
        {"index": 0, "durationSeconds": 100, "chapterCount": 1, "sizeBytes": 5,
         "outputFileName": "x.mkv", "suggestedRole": "someNewRole"}
        """
        let title = try JSONDecoder().decode(DiscTitle.self, from: Data(json.utf8))
        #expect(title.suggestedRole == .extra)
    }

    @Test func unknownKindRawValueFallsBackToUnknown() throws {
        let json = """
        {"index": 0, "kind": "someNewKind", "codecId": "V_NEW"}
        """
        let stream = try JSONDecoder().decode(DiscStream.self, from: Data(json.utf8))
        #expect(stream.kind == .unknown)
    }

    // MARK: - flags derivations

    @Test(arguments: [
        (4096, true, false),   // forced, not commentary
        (1, false, true),      // commentary, not forced
        (2, false, true),      // commentary, not forced
        (0, false, false),     // neither
        (8, false, true),      // unrecognized flag surfaced as commentary
        (4097, true, false),   // forced wins: "some flag other than forced" is false
    ])
    func flagsDeriveForcedAndCommentary(_ flags: Int, _ forced: Bool, _ commentary: Bool) {
        let stream = DiscStream(index: 0, kind: .audio, codecId: "A_AC3", flags: flags)
        #expect(stream.isForced == forced, "flags \(flags): isForced")
        #expect(stream.isCommentary == commentary, "flags \(flags): isCommentary")
    }

    @Test func textSubtitleIsTheCC608Codec() {
        #expect(DiscStream(index: 0, kind: .subtitle, codecId: "S_CC608/DVD").isTextSubtitle)
        #expect(!DiscStream(index: 0, kind: .subtitle, codecId: "S_VOBSUB").isTextSubtitle)
    }
}
