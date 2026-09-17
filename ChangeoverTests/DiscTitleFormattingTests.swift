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

    /// #0033's #0026 handoff: the summary's subtitle count uses
    /// `SubtitleGrouping.groups(for:)`, so a Wide Screen/Letterbox variant
    /// pair (HandBrake reports these as two separate streams) reads as one
    /// logical subtitle track, not two.
    @Test func summaryCollapsesSubtitleVariantPairsViaSubtitleGrouping() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [
                                stream(1, kind: .audio, languageCode: "eng"),
                                DiscStream(index: 2, kind: .subtitle, codecId: "VOBSUB",
                                           languageCode: "eng", variant: "Wide Screen"),
                                DiscStream(index: 3, kind: .subtitle, codecId: "VOBSUB",
                                           languageCode: "eng", variant: "Letterbox"),
                              ])
        #expect(DiscTitleFormatting.streamSummary(for: title) == "1 audio (eng) · 1 sub")
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

    // MARK: - featureSourceCaption (#0056)

    @Test func featureSourceCaptionIsNilForAScannerAnswer() {
        #expect(DiscTitleFormatting.featureSourceCaption(.scanner) == nil)
    }

    @Test func featureSourceCaptionNamesTheLengthFallbackForALengthAnswer() {
        let caption = DiscTitleFormatting.featureSourceCaption(.length)
        #expect(caption != nil)
        #expect(caption?.contains("45 minutes") == true)
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

    // MARK: - size (#0038 — 0 = unknown per HandBrakeScanParser's documented
    // contract; must never reach ByteCountFormatter and render "Zero KB")

    @Test func sizeOfZeroIsNilNotZeroKB() {
        #expect(DiscTitleFormatting.size(0) == nil)
    }

    @Test func sizeOfANegativeByteCountIsAlsoNil() {
        #expect(DiscTitleFormatting.size(-1) == nil)
    }

    @Test func sizeOfARealByteCountProducesANonEmptyString() {
        // Smoke test only — ByteCountFormatter's exact rendering isn't ours
        // to verify.
        #expect(!(DiscTitleFormatting.size(6_795_724_800) ?? "").isEmpty)
    }

    // MARK: - confirmationDetail (#0038)

    @Test func confirmationDetailOmitsTheSizeSegmentWhenSizeIsUnknown() {
        let title = DiscTitle(index: 3, durationSeconds: 6645, chapterCount: 21, sizeBytes: 0, outputFileName: nil)
        #expect(DiscTitleFormatting.confirmationDetail(index: 3, title: title) == "Title 3 · 1:50:45 · 21 chapters")
    }

    @Test func confirmationDetailAppendsTheSizeSegmentWhenSizeIsKnown() {
        let title = DiscTitle(index: 3, durationSeconds: 6645, chapterCount: 21, sizeBytes: 6_795_724_800, outputFileName: nil)
        let detail = DiscTitleFormatting.confirmationDetail(index: 3, title: title)
        #expect(detail.hasPrefix("Title 3 · 1:50:45 · 21 chapters · "))
        #expect(detail != "Title 3 · 1:50:45 · 21 chapters")
    }

    @Test func confirmationDetailTreatsANegativeSizeAsUnknownToo() {
        let title = DiscTitle(index: 1, durationSeconds: 60, chapterCount: 1, sizeBytes: -1, outputFileName: nil)
        #expect(DiscTitleFormatting.confirmationDetail(index: 1, title: title) == "Title 1 · 0:01:00 · 1 chapters")
    }

    // MARK: - extrasStatusLine (#0038)

    @Test func extrasStatusLineReadsNoneWhenThePlanIsEmpty() {
        #expect(DiscTitleFormatting.extrasStatusLine(ExtrasPlan()) == "Extras: none")
    }

    @Test func extrasStatusLineReportsCountAndRunningDurationTotal() {
        let plan = ExtrasPlan(items: [
            ExtrasPlan.Item(titleIndex: 5, durationSeconds: 1_200, frameRate: nil, interlaceDetected: nil),
            ExtrasPlan.Item(titleIndex: 7, durationSeconds: 1_690, frameRate: nil, interlaceDetected: nil),
        ])
        // 1200 + 1690 = 2890s = 0:48:10.
        #expect(DiscTitleFormatting.extrasStatusLine(plan) == "Extras: 2 · 0:48:10")
    }

    // MARK: - noTitlesMessage (#0039)

    @Test func noTitlesMessageWithNoWarningsOrLastLineIsJustTheHeadline() {
        let message = DiscTitleFormatting.noTitlesMessage(warnings: [], lastLine: nil)
        #expect(message == "The scan read no titles from this disc.")
        // Never the `.none` wording — a distinct statement about the scan,
        // not the disc's contents.
        #expect(!message.contains("no title looks like a feature"))
    }

    @Test func noTitlesMessageIncludesHandBrakesLastLineWhenPresent() {
        let message = DiscTitleFormatting.noTitlesMessage(warnings: [], lastLine: "HandBrake has exited.")
        #expect(message.contains("HandBrake's last line: \"HandBrake has exited.\""))
    }

    @Test func noTitlesMessageOmitsThePermissionsHintWithoutTheLibdvdcssWarning() {
        let message = DiscTitleFormatting.noTitlesMessage(
            warnings: ["3 subtitle decode errors during the scan (non-fatal) — the rip may be missing subtitle data"],
            lastLine: nil
        )
        #expect(!message.contains("Full Disk Access"))
    }

    /// Worded as a possibility, not a diagnosis, per the Plan.
    @Test func noTitlesMessageAddsThePermissionsHintOnlyWithTheLibdvdcssWarning() {
        let message = DiscTitleFormatting.noTitlesMessage(
            warnings: ["libdvdcss could not open the raw device and fell back to the mounted filesystem — this usually works, but a disc that fails here is a CSS error in disguise"],
            lastLine: nil
        )
        #expect(message.contains("Full Disk Access"))
        #expect(message.contains("may not have permission"))
    }

    // MARK: - subtitleSummary (#0140 — the collapsed-disclosure one-liner)

    @Test func subtitleSummaryMatchesTheIssuesWorkedExample() {
        // The Girl in the Spider's Web, 2026-09-16 — the disc that motivated
        // #0140: 21 subtitle rows pushed Start Ripping off the screen.
        #expect(DiscTitleFormatting.subtitleSummary(count: 21) == "21 subtitle tracks, none carried into the output")
    }

    @Test func subtitleSummarySingularizesOneTrack() {
        #expect(DiscTitleFormatting.subtitleSummary(count: 1) == "1 subtitle track, none carried into the output")
    }

    @Test func subtitleSummaryPluralizesZeroTracks() {
        // Not reachable through the view today (`TrackSelectionView` only
        // shows the section when `subtitleGroups` is non-empty), but the
        // function itself should still read grammatically for 0.
        #expect(DiscTitleFormatting.subtitleSummary(count: 0) == "0 subtitle tracks, none carried into the output")
    }
}
