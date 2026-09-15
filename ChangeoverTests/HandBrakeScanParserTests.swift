import Foundation
import Testing
@testable import Changeover

/// Covers #0023: the HandBrake `--scan --json` parser, tested against the
/// real capture `Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json`
/// (scanned from the mounted disc on joe, 2026-09-14) plus synthetic edge
/// cases. Pure function — no disc, no process.
struct HandBrakeScanParserTests {

    // MARK: - Fixture loading

    private static func fixtureText() throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json")
            .path
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func parseFixture() throws -> HandBrakeScanParser.Output {
        try Self.parse(Self.fixtureText())
    }

    private static func parse(_ text: String) -> HandBrakeScanParser.Output {
        HandBrakeScanParser.parse(text, volumeName: "DRAGON", driveName: "disk6")
    }

    // MARK: - Real capture

    @Test func parsesTheRealCapture() throws {
        let output = try Self.parseFixture()

        #expect(output.versionString == "1.11.2")
        #expect(output.mainFeatureIndex == 1)
        #expect(output.disc.volumeName == "DRAGON")
        #expect(output.disc.titles.count == 5)
    }

    @Test func mainFeatureTitleCarriesTheVerifiedFacts() throws {
        let output = try Self.parseFixture()
        let title = try #require(output.disc.titles.first { $0.index == 1 })

        // 2:37:58 from the capture's Duration block.
        #expect(title.durationSeconds == 2 * 3600 + 37 * 60 + 58)
        #expect(title.chapterCount == 16)
        #expect(title.angleCount == 1)
        // 27000000 / 1126125 ≈ 23.976 — Fargo-class soft-telecine values
        // that #0016's decision consumes.
        #expect(title.interlaceDetected == false)
        let frameRate = try #require(title.frameRate)
        #expect(abs(frameRate - 23.976) < 0.001)

        // MakeMKV-shaped fields this scan does not report stay empty/nil.
        #expect(title.sizeBytes == 0)
        #expect(title.outputFileName == nil)
        #expect(title.sourceFileName == nil)
        #expect(title.segmentCount == nil)
    }

    @Test func audioStreamsCarryCleanLanguageAndDedupFields() throws {
        let output = try Self.parseFixture()
        let title = try #require(output.disc.titles.first { $0.index == 1 })
        let audio = title.streams.filter { $0.kind == .audio }

        #expect(audio.count == 5)
        let first = try #require(audio.first { $0.index == 1 })
        #expect(first.languageCode == "eng")
        #expect(first.languageName == "English")
        #expect(first.codecId == "ac3")
        #expect(first.bitrate == "448000")
        #expect(first.channelCount == 6)
        #expect(first.displayName == "English (AC3, 5.1 ch, 448 kbps)")
        #expect(!first.isCommentary)
        #expect(!first.isForced)

        // Track 4 is the French track.
        let french = try #require(audio.first { $0.index == 4 })
        #expect(french.languageCode == "fra")
    }

    @Test func subtitleVariantIsSeparatedFromLanguage() throws {
        let output = try Self.parseFixture()
        let title = try #require(output.disc.titles.first { $0.index == 1 })
        let subtitles = title.streams.filter { $0.kind == .subtitle }

        #expect(subtitles.count == 5)
        let first = try #require(subtitles.first { $0.index == 1 })
        // "English (Wide Screen) [VOBSUB]" splits three ways, never folded:
        #expect(first.languageName == "English")
        #expect(first.variant == "Wide Screen")
        #expect(first.languageCode == "eng")
        #expect(first.codecId == "VOBSUB")
        #expect(first.displayName == "English (Wide Screen) [VOBSUB]")

        let spanish = try #require(subtitles.first { $0.index == 4 })
        #expect(spanish.languageCode == "spa")
        #expect(spanish.languageName == "español")
        #expect(spanish.variant == "Wide Screen")
    }

    /// #0033: HandBrake writes `LanguageCode: "und"` verbatim for an
    /// untagged stream (title 4's CC608 track). `DiscStream.languageCode`'s
    /// contract is `nil` for untagged, never the string `"und"` — the
    /// parser must normalize it on the subtitle side.
    @Test func untaggedSubtitleLanguageCodeUndNormalizesToNil() throws {
        let output = try Self.parseFixture()
        let title4 = try #require(output.disc.titles.first { $0.index == 4 })
        let cc608 = try #require(title4.streams.first { $0.kind == .subtitle })

        #expect(cc608.codecId == "CC608")
        #expect(cc608.languageCode == nil)
        #expect(cc608.isTextSubtitle)
    }

    // MARK: - Noise tolerance

    /// The real capture's shape: Version + Progress blocks and libdvdnav
    /// noise before the JSON. A parser that splits on known labels breaks;
    /// this must not.
    @Test func parsesJSONAfterArbitraryNoise() throws {
        let noisy = """
        libdvdnav: vm: dvd_read_name failed
        Version: {"Version": {"Major": 1, "Minor": 11, "Point": 2}, "VersionString": "1.11.2"}
        Progress: {"Scanning": {"Preview": 0, "Progress": 0.0}}
        libdvdnav: DVD disk reports itself with Region mask 0x00fe0000. Regions: 01
        JSON Title Set: {"MainFeature": 2, "TitleList": [{"Index": 2, "Duration": {"Hours": 0, "Minutes": 1, "Seconds": 30}, "ChapterList": [{}], "AngleCount": 1, "InterlaceDetected": true, "FrameRate": {"Num": 30000, "Den": 1001}}]}
        """
        let output = Self.parse(noisy)

        #expect(output.mainFeatureIndex == 2)
        #expect(output.disc.titles.count == 1)
        #expect(output.disc.titles[0].durationSeconds == 90)
        #expect(abs(output.disc.titles[0].frameRate! - 29.97) < 0.001)
    }

    @Test func missingJSONSectionYieldsAnEmptyDiscNotACrash() {
        let noiseOnly = """
        Version: {"Version": {"Major": 1, "Minor": 11, "Point": 2}}
        Progress: {"Scanning": {"Preview": 0, "Progress": 0.0}}
        libdvdnav: DVD disk reports itself with Region mask 0x00fe0000.
        """
        let output = Self.parse(noiseOnly)

        #expect(output.disc.titles.isEmpty)
        #expect(output.mainFeatureIndex == nil)
        #expect(output.versionString == "1.11.2")
    }

    @Test func emptyInputYieldsAnEmptyDisc() {
        let output = Self.parse("")
        #expect(output.disc.titles.isEmpty)
        #expect(output.mainFeatureIndex == nil)
        #expect(output.versionString == nil)
    }

    @Test func mainFeatureAbsentYieldsNil() {
        let json = #"{"TitleList": [{"Index": 1, "Duration": {"Hours": 0, "Minutes": 0, "Seconds": 5}}]}"#
        let output = Self.parse("JSON Title Set: " + json)
        #expect(output.mainFeatureIndex == nil)
        #expect(output.disc.titles.count == 1)
    }

    // MARK: - Attribute mapping

    @Test func commentaryAndForcedMapIntoTheFlagsBitfield() throws {
        let json = """
        {"MainFeature": 1, "TitleList": [{"Index": 1, "Duration": {"Hours": 0, "Minutes": 0, "Seconds": 5},
          "AudioList": [
            {"TrackNumber": 1, "CodecName": "ac3", "LanguageCode": "eng", "Language": "English",
             "Attributes": {"Commentary": true, "Default": false}},
            {"TrackNumber": 2, "CodecName": "ac3", "LanguageCode": "eng", "Language": "English",
             "Attributes": {"Commentary": false, "Default": true, "VisuallyImpaired": true}}
          ],
          "SubtitleList": [
            {"TrackNumber": 1, "SourceName": "VOBSUB", "LanguageCode": "eng",
             "Language": "English (Wide Screen) [VOBSUB]", "Format": "bitmap",
             "Attributes": {"Forced": true, "Wide": true}}
          ]}]}
        """
        let output = Self.parse("JSON Title Set: " + json)
        let title = try #require(output.disc.titles.first)

        let commentary = try #require(title.streams.first { $0.index == 1 })
        #expect(commentary.isCommentary)
        #expect(!commentary.isForced)

        // VisuallyImpaired has no bit yet — it must not surface as
        // commentary or forced, and Default maps to isDefault.
        let impaired = try #require(title.streams.first { $0.index == 2 })
        #expect(!impaired.isCommentary)
        #expect(!impaired.isForced)
        #expect(impaired.isDefault)

        let forced = try #require(title.streams.first { $0.kind == .subtitle })
        #expect(forced.isForced)
        #expect(!forced.isCommentary)
    }

    @Test func variantFallsBackToAttributesWhenLanguageHasNoParenthetical() throws {
        let json = """
        {"TitleList": [{"Index": 1, "Duration": {"Hours": 0, "Minutes": 0, "Seconds": 5},
          "SubtitleList": [
            {"TrackNumber": 1, "SourceName": "VOBSUB", "LanguageCode": "eng",
             "Language": "English", "Format": "bitmap",
             "Attributes": {"Wide": true}},
            {"TrackNumber": 2, "SourceName": "VOBSUB", "LanguageCode": "eng",
             "Language": "English", "Format": "bitmap",
             "Attributes": {"Letterbox": true}}
          ]}]}
        """
        let output = Self.parse("JSON Title Set: " + json)
        let title = try #require(output.disc.titles.first)
        #expect(title.streams.first { $0.index == 1 }?.variant == "Wide Screen")
        #expect(title.streams.first { $0.index == 2 }?.variant == "Letterbox")
    }

    /// A straggler diagnostics line after the JSON payload (stdout and
    /// stderr are merged in ProcessRunner) must not corrupt the parse —
    /// the document is brace-matched, not "everything after the marker".
    @Test func trailingNoiseAfterTheJSONPayloadIsIgnored() {
        let text = #"JSON Title Set: {"MainFeature": 1, "TitleList": [{"Index": 1, "Duration": {"Hours": 0, "Minutes": 0, "Seconds": 5}}]}"# + "\nERROR: a straggler diagnostic line arrived after the payload"
        let output = Self.parse(text)
        #expect(output.mainFeatureIndex == 1)
        #expect(output.disc.titles.count == 1)
    }

    // MARK: - splitVariant

    @Test func splitVariantStripsParentheticalAndCodecTag() {
        #expect(HandBrakeScanParser.splitVariant(from: "English (Wide Screen) [VOBSUB]")
            == (clean: "English", variant: "Wide Screen"))
        #expect(HandBrakeScanParser.splitVariant(from: "español (Letterbox) [VOBSUB]")
            == (clean: "español", variant: "Letterbox"))
        #expect(HandBrakeScanParser.splitVariant(from: "English")
            == (clean: "English", variant: nil))
        #expect(HandBrakeScanParser.splitVariant(from: nil)
            == (clean: nil, variant: nil))
    }
}
