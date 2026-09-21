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

    // MARK: - runtimeCaption (#0061 — moved off the retired MetadataEntryView)

    @Test func noRuntimeCaptionBeforeAMovieIsChosen() {
        #expect(DiscTitleFormatting.runtimeCaption(.idle) == nil)
    }

    @Test func aLoadingLookupSaysSo() {
        #expect(DiscTitleFormatting.runtimeCaption(.loading(movieID: 275)) == "Checking TMDB runtime…")
    }

    @Test func aLoadedRuntimeIsShownInHoursAndMinutes() {
        #expect(DiscTitleFormatting.runtimeCaption(.loaded(movieID: 275, runtimeMinutes: 98)) == "TMDB runtime 1h 38m")
        #expect(DiscTitleFormatting.runtimeCaption(.loaded(movieID: 275, runtimeMinutes: 45)) == "TMDB runtime 45m")
        #expect(DiscTitleFormatting.runtimeCaption(.loaded(movieID: 275, runtimeMinutes: 120)) == "TMDB runtime 2h 0m")
    }

    /// #0032's rule: the caption must never read like a pass when the check
    /// did not run. Every `.unavailable` reason says "will not run".
    @Test func anUnavailableLookupNeverReadsLikeAPass() {
        let reasons: [RuntimeCrossCheck.NotRunReason] = [
            .missingAPIKey, .pending, .lookupFailed("timed out"), .noRuntimeOnTMDB, .noFeatureTitle,
        ]
        for reason in reasons {
            let caption = DiscTitleFormatting.runtimeCaption(.unavailable(movieID: 275, reason: reason))
            #expect(caption?.hasPrefix("Runtime cross-check will not run — ") == true)
            #expect(caption?.contains("TMDB runtime ") != true)
        }
        #expect(
            DiscTitleFormatting.runtimeCaption(.unavailable(movieID: 275, reason: .lookupFailed("timed out")))
                == "Runtime cross-check will not run — timed out"
        )
    }

    // MARK: - scanFailureMessage (#0061 — moved off DiscTitleListView)

    @Test func everyScanFailureHasItsOwnSentence() {
        let failures: [DiscScanner.Failure] = [
            .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"),
            .launchFailure("permission denied"),
            .toolExited(code: 3),
            .jsonMissing,
            .titleSetCorrupted,
            .cancelled,
        ]
        let messages = failures.map(DiscTitleFormatting.scanFailureMessage)
        #expect(Set(messages).count == failures.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(messages[0].contains("/opt/homebrew/bin/HandBrakeCLI"))
        #expect(messages[2] == "The disc scan failed (HandBrakeCLI exited with status 3).")
        #expect(messages[5] == "The scan was cancelled.")
    }

    // MARK: - The plain register (docs/plain-language-ui.md §3.3)
    //
    // Every assertion above is untouched: these are the plain siblings, one
    // per function, with the precise string kept verbatim as the detail.

    @Test func plainDurationRoundsToWholeMinutes() {
        #expect(DiscTitleFormatting.plainDuration(5_872) == "1h 38m")
        #expect(DiscTitleFormatting.plainDuration(2_890) == "48m")
        #expect(DiscTitleFormatting.plainDuration(0) == "0m")
        // Rounds, never truncates: 89 seconds is nearer a minute than none.
        #expect(DiscTitleFormatting.plainDuration(89) == "1m")
        #expect(DiscTitleFormatting.plainDuration(-10) == "0m")
    }

    @Test func plainFeatureLineNamesNeitherTheIndexNorTheChapters() {
        let title = DiscTitle(index: 3, durationSeconds: 5_872, chapterCount: 21, sizeBytes: 6_800_000_000, outputFileName: nil)
        #expect(DiscTitleFormatting.plainFeatureLine(title: title) == "The movie · 1h 38m")
        // The precise line is untouched and still carries all four facts.
        #expect(DiscTitleFormatting.confirmationDetail(index: 3, title: title).contains("21 chapters"))
    }

    @Test func everyScanFailureHasItsOwnPlainSentenceToo() {
        let failures: [DiscScanner.Failure] = [
            .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"),
            .launchFailure("permission denied"),
            .toolExited(code: 3),
            .jsonMissing,
            .titleSetCorrupted,
            .cancelled,
        ]
        let plain = failures.map(DiscTitleFormatting.plainScanFailureMessage)
        #expect(plain.allSatisfy { !$0.isEmpty })
        // No path, no exit status: the one that named a path now names
        // Settings instead.
        #expect(plain[0] == "A program Changeover needs isn't installed. Open Settings to fix it.")
        #expect(plain[2] == "The disc couldn't be read. Try Scan Again, or clean the disc.")
        // A cancel already met the plain register, so the pair collapses.
        #expect(plain[5] == "The scan was cancelled.")
        #expect(DiscTitleFormatting.scanFailureWording(.cancelled).lines(showingDetails: true) == ["The scan was cancelled."])
        // …and every other one keeps the verbatim sentence beneath it.
        #expect(DiscTitleFormatting.scanFailureWording(.toolExited(code: 3)).detail
                == "The disc scan failed (HandBrakeCLI exited with status 3).")
    }

    /// The permissions hint and HandBrake's last line stay in the detail,
    /// verbatim — the plain sentence is constant.
    @Test func plainNoTitlesMessageIsConstantAndTheHintStaysInTheDetail() {
        let wording = DiscTitleFormatting.noTitlesWording(
            warnings: ["libdvdcss could not open the raw device"],
            lastLine: "scan: 0 valid title(s) found"
        )
        #expect(wording.plain == "Nothing playable was found on this disc. Try Scan Again, or clean the disc.")
        #expect(wording.detail?.contains("Full Disk Access") == true)
        #expect(wording.detail?.contains("scan: 0 valid title(s) found") == true)
    }

    @Test func plainFeatureSourceCaptionOnlyExistsForTheLengthFallback() {
        #expect(DiscTitleFormatting.plainFeatureSourceCaption(.scanner) == nil)
        #expect(DiscTitleFormatting.featureSourceWording(.scanner) == nil)
        let wording = try? #require(DiscTitleFormatting.featureSourceWording(.length))
        #expect(wording?.plain == "Changeover guessed this is the movie because it's the only long part of the disc. Check the length looks right.")
        #expect(wording?.detail == DiscTitleFormatting.featureSourceCaption(.length))
    }

    @Test func plainExtrasLineRoundsTheTotalToMinutes() {
        #expect(DiscTitleFormatting.plainExtrasLine(ExtrasPlan(items: [])) == "Extras: none")
        let plan = ExtrasPlan(items: [
            ExtrasPlan.Item(titleIndex: 5, durationSeconds: 1_200, frameRate: nil, interlaceDetected: nil),
            ExtrasPlan.Item(titleIndex: 7, durationSeconds: 1_690, frameRate: nil, interlaceDetected: nil),
        ])
        #expect(DiscTitleFormatting.plainExtrasLine(plan) == "Extras: 2 · 48m")
        // The running total's precise form is untouched.
        #expect(DiscTitleFormatting.extrasStatusLine(plan) == "Extras: 2 · 0:48:10")
        #expect(DiscTitleFormatting.extrasSummaryWording(plan).plain == "Extras: 2 · 48m")
        #expect(DiscTitleFormatting.extrasSummaryWording(plan).detail?.contains("filed outside the Plex library") == true)
    }

    @Test func plainPlayAllMessageDropsTheClusterArithmetic() {
        let titles = (1...9).map { DiscTitle(index: $0, durationSeconds: 1_260, chapterCount: 5, sizeBytes: 0, outputFileName: nil) }
        let disc = DiscInfo(volumeName: "TV_S1_D1", driveName: "disk6", titles: titles)
        let wording = DiscTitleFormatting.playAllWording(index: 1, episodes: [2, 3, 4], disc: disc)
        #expect(wording.plain == "This looks like a TV disc, not a movie. Pick the part you want below.")
        #expect(wording.detail == DiscTitleFormatting.playAllMessage(index: 1, episodes: [2, 3, 4], disc: disc))
    }

    /// The `.none` sentence moved off `DiscTitleListView` so it gains a test.
    @Test func theNoFeatureSentenceKeepsItsVerbatimFormAsTheDetail() {
        #expect(DiscTitleFormatting.noFeatureWording.plain.contains("Pick it below"))
        #expect(DiscTitleFormatting.noFeatureWording.detail
                == "This disc did not identify itself — no title looks like a feature. That can happen on a TV disc with no Play All title, or a feature under 45 minutes. Choose one below.")
    }

    @Test func plainLanguagesNamesLanguagesRatherThanCountingStreams() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [
                                stream(1, kind: .audio, languageCode: "eng"),
                                stream(2, kind: .audio, languageCode: "spa"),
                                stream(3, kind: .subtitle, languageCode: "eng"),
                              ])
        if Locale.current.language.languageCode?.identifier == "en" {
            #expect(DiscTitleFormatting.plainLanguages(for: title) == "English, Spanish")
        }
        // Never a parenthetical, and never an ISO code.
        #expect(!DiscTitleFormatting.plainLanguages(for: title).contains("("))
        #expect(!DiscTitleFormatting.plainLanguages(for: title).contains("eng"))
    }

    /// Hornet's Nest's shape: no audio stream carries a language tag at all,
    /// so there is no name to give — and the fallback must not render "()".
    @Test func plainLanguagesSurvivesATitleWithNoLanguageTagsAtAll() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0,
                              outputFileName: nil,
                              streams: [stream(1, kind: .audio), stream(2, kind: .audio)])
        #expect(DiscTitleFormatting.plainLanguages(for: title) == "2 audio tracks")
        #expect(!DiscTitleFormatting.plainLanguages(for: title).contains("()"))
    }

    @Test func plainLanguagesOfATitleWithNoAudioSaysSo() {
        let title = DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0, outputFileName: nil)
        #expect(DiscTitleFormatting.plainLanguages(for: title) == "No sound")
    }

    /// The subtitle caption is constant on purpose: it states #0036's fact
    /// about the *output*, which is the surprise. The count is the detail.
    @Test func thePlainSubtitleLineIsConstantAndTheCountIsTheDetail() {
        #expect(DiscTitleFormatting.subtitleWording(count: 6).plain == "Subtitles aren't copied to Plex yet.")
        #expect(DiscTitleFormatting.subtitleWording(count: 6).detail == "6 subtitle tracks, none carried into the output")
        #expect(DiscTitleFormatting.subtitleWording(count: 1).plain == DiscTitleFormatting.subtitleWording(count: 21).plain)
    }

    @Test func plainRuntimeCaptionSaysListedLengthNotTheDatabasesName() {
        #expect(DiscTitleFormatting.plainRuntimeCaption(.idle) == nil)
        #expect(DiscTitleFormatting.plainRuntimeCaption(.loading(movieID: 275)) == "Checking the movie's length…")
        #expect(DiscTitleFormatting.plainRuntimeCaption(.loaded(movieID: 275, runtimeMinutes: 98)) == "Listed length 1h 38m")
        // Never reads like a pass when the check did not run.
        #expect(DiscTitleFormatting.plainRuntimeCaption(.unavailable(movieID: 275, reason: .missingAPIKey))
                == "Couldn't check the movie's length.")
        let wording = DiscTitleFormatting.runtimeWording(.unavailable(movieID: 275, reason: .lookupFailed("timed out")))
        #expect(wording?.detail == "Runtime cross-check will not run — timed out")
    }

    // MARK: - The runtime verdict, moved off DiscTitleListView

    @Test func theConsistentVerdictIsATickAndTheDeltaIsTheDetail() throws {
        let title = DiscTitle(index: 1, durationSeconds: 5_886, chapterCount: 21, sizeBytes: 0, outputFileName: nil)
        let wording = try #require(DiscTitleFormatting.runtimeVerdictWording(title: title, verdict: .consistent(deltaSeconds: 14)))
        #expect(wording.plain == "✓ Length matches.")
        #expect(wording.detail == "Title 1 matches the TMDB runtime (Δ +14s)")
    }

    /// Both signs, in minutes, with the direction said out loud — the
    /// arithmetic the plain sentence rests on.
    @Test func theMismatchVerdictSaysHowFarOffAndInWhichDirection() throws {
        let title = DiscTitle(index: 1, durationSeconds: 4_000, chapterCount: 21, sizeBytes: 0, outputFileName: nil)

        let shorter = try #require(DiscTitleFormatting.runtimeVerdictWording(title: title, verdict: .mismatch(deltaSeconds: -1_832)))
        #expect(shorter.plain.hasPrefix("This part is about 31 minutes shorter than the movie should be."))
        #expect(shorter.detail == "Title 1 does not match the TMDB runtime (Δ -1832s) — check this is the right title.")

        let longer = try #require(DiscTitleFormatting.runtimeVerdictWording(title: title, verdict: .mismatch(deltaSeconds: 1_832)))
        #expect(longer.plain.hasPrefix("This part is about 31 minutes longer than the movie should be."))
        #expect(longer.detail == "Title 1 does not match the TMDB runtime (Δ +1832s) — check this is the right title.")
    }

    /// The movie card's own caption already says the check did not run;
    /// repeating it here was the redundant second line the first pass flagged.
    @Test func aCheckThatDidNotRunAddsNoVerdictLine() {
        let title = DiscTitle(index: 1, durationSeconds: 4_000, chapterCount: 21, sizeBytes: 0, outputFileName: nil)
        #expect(DiscTitleFormatting.runtimeVerdictWording(title: title, verdict: .notRun(.missingAPIKey)) == nil)
    }
}
