import Foundation
import Testing
@testable import Changeover

/// Covers #0026's pure formatting helpers backing `DiscTitleListView`: the
/// `H:MM:SS` duration string, the stream summary (and its no-language-tags
/// survival case — the silent-MP4 risk `hornets-nest-min0.txt` exists to
/// test), and the Play All refusal sentence.
struct DiscTitleFormattingTests {

    // MARK: - Helpers

    private func stream(
        _ index: Int,
        kind: DiscStream.Kind,
        languageCode: String? = nil
    ) -> DiscStream {
        DiscStream(index: index, kind: kind, codecId: "A_AC3", languageCode: languageCode)
    }

    // MARK: - duration

    @Test func durationFormatsHoursMinutesSeconds() {
        // Hanna's min0 feature: 1:50:45.
        #expect(DiscTitleFormatting.duration(6645) == "1:50:45")
    }

    @Test func durationUnderAnHourStillShowsTheHoursDigit() {
        #expect(DiscTitleFormatting.duration(65) == "0:01:05")
    }

    @Test func durationOfZeroIsZero() {
        #expect(DiscTitleFormatting.duration(0) == "0:00:00")
    }

    @Test func negativeDurationClampsToZeroRatherThanUnderflowing() {
        #expect(DiscTitleFormatting.duration(-5) == "0:00:00")
    }

    // MARK: - streamSummary

    @Test func summaryListsAudioLanguagesAndSubtitleCount() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [
                                stream(1, kind: .audio, languageCode: "eng"),
                                stream(2, kind: .audio, languageCode: "spa"),
                                stream(3, kind: .subtitle, languageCode: "eng"),
                              ])
        #expect(DiscTitleFormatting.streamSummary(for: title) == "2 audio (eng, spa) · 1 sub")
    }

    @Test func summaryPluralizesSubtitleCount() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [
                                stream(1, kind: .audio, languageCode: "eng"),
                                stream(2, kind: .subtitle),
                                stream(3, kind: .subtitle),
                              ])
        #expect(DiscTitleFormatting.streamSummary(for: title) == "1 audio (eng) · 2 subs")
    }

    /// `hornets-nest-min0.txt`'s feature has zero attribute-3 lines across
    /// every stream — the exact shape that must never render as "()" or a
    /// blank parenthetical, and the exact shape a naive `["eng","spa"]`
    /// filter would turn into a silent MP4 by matching nothing (#0027's
    /// finding this ticket's Notes call out explicitly).
    @Test func summarySurvivesATitleWithNoLanguageTagsAtAll() {
        let title = DiscTitle(index: 9, durationSeconds: 8807, chapterCount: 16, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [
                                stream(1, kind: .audio),
                                stream(2, kind: .audio),
                                stream(3, kind: .subtitle),
                              ])
        #expect(DiscTitleFormatting.streamSummary(for: title) == "2 audio · 1 sub")
    }

    @Test func summaryDeduplicatesRepeatedLanguageCodes() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [
                                stream(1, kind: .audio, languageCode: "eng"),
                                stream(2, kind: .audio, languageCode: "eng"),
                              ])
        #expect(DiscTitleFormatting.streamSummary(for: title) == "2 audio (eng)")
    }

    @Test func summaryOfATitleWithNoStreamsAtAllDoesNotCrashOrRenderEmpty() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil, streams: [])
        #expect(DiscTitleFormatting.streamSummary(for: title) == "no audio or subtitle streams")
    }

    @Test func summaryIgnoresVideoStreamsEntirely() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [
                                stream(0, kind: .video),
                                stream(1, kind: .audio, languageCode: "eng"),
                              ])
        #expect(DiscTitleFormatting.streamSummary(for: title) == "1 audio (eng)")
    }

    // MARK: - playAllMessage

    @Test func playAllMessageNamesTheClusterCountApproximateLengthAndSuspiciousTitle() {
        // Brooklyn Nine-Nine's shape: 8 episodes around 21 minutes summing to
        // title 12's 2:53:18 (10,398s / 8 = 1,299.75s ≈ 22min when rounded).
        let episodes = (1...8).map {
            DiscTitle(index: $0, durationSeconds: 1_300, chapterCount: 4, sizeBytes: 0, outputFileName: nil)
        }
        let feature = DiscTitle(index: 12, durationSeconds: 10_398, chapterCount: 33, sizeBytes: 0, outputFileName: nil)
        let disc = DiscInfo(volumeName: "TV", driveName: "disk6", titles: episodes + [feature])

        let message = DiscTitleFormatting.playAllMessage(index: 12, episodes: Array(1...8), disc: disc)
        #expect(message == "This looks like a TV season disc — 8 titles of about 22 minutes that together match the length of title 12.")
    }

    @Test func playAllMessageWithNoMatchingEpisodeTitlesStillReportsSomething() {
        let disc = DiscInfo(volumeName: "TV", driveName: "disk6", titles: [])
        let message = DiscTitleFormatting.playAllMessage(index: 5, episodes: [1, 2, 3], disc: disc)
        #expect(message == "This looks like a TV season disc — 3 titles of about 0 minutes that together match the length of title 5.")
    }

    // MARK: - size (smoke test only — ByteCountFormatter itself isn't ours to verify)

    @Test func sizeProducesANonEmptyString() {
        #expect(!DiscTitleFormatting.size(6_300_000_000).isEmpty)
    }
}
