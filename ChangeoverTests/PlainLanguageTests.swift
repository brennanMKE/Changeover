import Foundation
import Testing
@testable import Changeover

/// `docs/plain-language-ui.md` §8 — the plain register's own coverage: the
/// formatters it needs, the two-register carrier, and the sweep that keeps a
/// later, well-meant, precise sentence from creeping back into the default
/// view.
///
/// Pure seams only. No view is tested and no UI test is written or run
/// (`docs/ui-test-crash-prevention.md`).
struct PlainLanguageTests {

    // MARK: - Formatters

    @Test func minutesRoundsToTheNearestMinute() {
        #expect(PlainLanguage.minutes(1832) == "about 31 minutes")
        #expect(PlainLanguage.minutes(-1832) == "about 31 minutes")
        #expect(PlainLanguage.minutes(150) == "about 3 minutes")
    }

    /// Below 90 seconds the exact number is the kind of thing Details keeps.
    @Test func minutesUnderNinetySecondsIsAboutAMinute() {
        #expect(PlainLanguage.minutes(0) == "about a minute")
        #expect(PlainLanguage.minutes(14) == "about a minute")
        #expect(PlainLanguage.minutes(89) == "about a minute")
        #expect(PlainLanguage.minutes(90) == "about 2 minutes")
    }

    @Test func minutesOverAnHourSpeaksInHours() {
        #expect(PlainLanguage.minutes(3_900) == "about 1 hour 5 minutes")
        #expect(PlainLanguage.minutes(3_600) == "about 1 hour")
        #expect(PlainLanguage.minutes(7_260) == "about 2 hours 1 minute")
    }

    @Test func elapsedIsWholeMinutes() {
        #expect(PlainLanguage.elapsed(2_472) == "41 minutes")
        #expect(PlainLanguage.elapsed(59) == "under a minute")
        #expect(PlainLanguage.elapsed(0) == "under a minute")
        #expect(PlainLanguage.elapsed(60) == "1 minute")
        #expect(PlainLanguage.elapsed(3_900) == "1 h 5 min")
    }

    /// Names, never ISO codes. Pinned only where the host runs in English —
    /// the lookup is `Locale.current`'s, exactly as the audio picker's always
    /// was, and a non-English host legitimately answers differently.
    @Test func languageNameResolvesACode() {
        #expect(PlainLanguage.languageName(nil) == nil)
        #expect(PlainLanguage.languageName("") == nil)
        if Locale.current.language.languageCode?.identifier == "en" {
            #expect(PlainLanguage.languageName("spa") == "Spanish")
            #expect(PlainLanguage.languageName("eng") == "English")
        } else {
            #expect(PlainLanguage.languageName("spa") != nil)
        }
    }

    @Test func andListJoinsLikeASentence() {
        #expect(PlainLanguage.andList([]) == "")
        #expect(PlainLanguage.andList(["a"]) == "a")
        #expect(PlainLanguage.andList(["a", "b"]) == "a and b")
        #expect(PlainLanguage.andList(["a", "b", "c"]) == "a, b and c")
    }

    // MARK: - The carrier

    /// A `detail` equal to `plain` is the "this string already met the plain
    /// register" case; repeating it under itself would read as a bug.
    @Test func wordingNeverRepeatsADetailEqualToItsPlainText() {
        let same = Wording(plain: "The scan was cancelled.", detail: "The scan was cancelled.")
        #expect(same.lines(showingDetails: true) == ["The scan was cancelled."])
        #expect(same.lines(showingDetails: false) == ["The scan was cancelled."])

        let pair = Wording(plain: "Short.", detail: "Long and precise.")
        #expect(pair.lines(showingDetails: false) == ["Short."])
        #expect(pair.lines(showingDetails: true) == ["Short.", "Long and precise."])

        #expect(Wording.plainOnly("Only.").lines(showingDetails: true) == ["Only."])
    }

    // MARK: - The forbidden-terms sweep

    /// The list itself must actually catch what it claims to.
    @Test func theSweepCatchesToolNamesAndDiscVocabulary() {
        #expect(PlainLanguage.violations(in: "HandBrake exited with status 3").isEmpty == false)
        #expect(PlainLanguage.violations(in: "Title 1 matches the TMDB runtime (Δ +14s)").isEmpty == false)
        #expect(PlainLanguage.violations(in: "Pick a title.").contains("title"))
        // "subtitle" is an ordinary English word and must survive.
        #expect(PlainLanguage.violations(in: "Subtitles aren't copied to Plex yet.").isEmpty)
        #expect(PlainLanguage.violations(in: "Put a DVD in the drive first.").isEmpty)
    }

    @Test func everyStartDecisionsPlainReasonIsPlain() {
        for decision in StartDecision.allCases {
            guard let plain = decision.plainReason else { continue }
            #expect(PlainLanguage.violations(in: plain).isEmpty, "\(decision): \(plain)")
        }
    }

    /// Rule 6: a caption beside Start has to fit two lines at the 560-point
    /// minimum. The #0140 reviewer's worst case was 103 characters.
    @Test func everyPlainStartCaptionIsShortEnoughToSitBesideStart() {
        for decision in StartDecision.allCases {
            guard let plain = decision.plainReason else { continue }
            #expect(plain.count <= 90, "\(decision) is \(plain.count) characters: \(plain)")
        }
    }

    /// `nil` exactly for `.ready` and for the two cases that only ever appear
    /// inside the upgrade card, which the plain register does not draw.
    @Test func onlyReadyAndTheUpgradeOnlyCasesHaveNoPlainReason() {
        for decision in StartDecision.allCases {
            let expected: Bool = switch decision {
            case .ready, .ffmpegMissing, .fileCheckInProgress: true
            default: false
            }
            #expect((decision.plainReason == nil) == expected, "\(decision)")
        }
    }

    private static let sampleReasons: [FailureReason] = [
        .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"),
        .toolMissing(path: ""),
        .toolLaunchFailed("no such file"),
        .toolIncompatible(detail: "unknown option (--no-such-flag)"),
        .toolExited(code: 1),
        .noTitlesProduced,
        .destinationUnwritable(path: "/Volumes/Plex/Movies"),
        .destinationUnwritable(path: "/Volumes/Plex"),
        .diskFull,
        .activationExpired,
        .discUnreadable,
        .cancelled,
        .unknown("HandBrakeCLI exited with status 3"),
    ]

    /// The one documented exemption: `.activationExpired` names MakeMKV
    /// because the person has to open that app to fix it, so the name *is*
    /// the instruction.
    @Test func everyPlainFailureHeadlineIsPlain() {
        for reason in Self.sampleReasons {
            for stage: JobStage in [.encode, .rip, .preflight, .organize] {
                let plain = FailurePresenter.plainHeadline(for: reason, stage: stage)
                #expect(!plain.isEmpty, "\(reason) at \(stage)")
                let violations = PlainLanguage.violations(in: plain)
                if reason == .activationExpired {
                    #expect(violations == ["MakeMKV"], "\(reason) at \(stage): \(plain)")
                } else {
                    #expect(violations.isEmpty, "\(reason) at \(stage): \(plain)")
                }
            }
        }
    }

    /// The `.unknown` detail is a machine's word for it every time, so the
    /// plain headline never quotes it.
    @Test func thePlainUnknownHeadlineNeverQuotesTheMachinesDetail() {
        let plain = FailurePresenter.plainHeadline(for: .unknown("HandBrakeCLI exited with status 3"), stage: .encode)
        #expect(plain == "Something went wrong.")
    }

    @Test func everyScanStripsPlainSentenceIsPlain() {
        let failures: [DiscScanner.Failure] = [
            .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"),
            .launchFailure("no such file"),
            .toolExited(code: 3),
            .jsonMissing,
            .titleSetCorrupted,
            .cancelled,
        ]
        var states: [ScanState] = [.scanning] + failures.map { ScanState.failed($0) }
        states.append(Self.scanned(titles: []))
        states.append(Self.scanned(titles: [Self.title(1, seconds: 6_645)], mainFeatureIndex: 1))
        states.append(Self.scanned(titles: [Self.title(1, seconds: 600), Self.title(2, seconds: 700)]))

        for state in states {
            guard let line = ScanStatusLine.line(for: state) else { continue }
            #expect(PlainLanguage.violations(in: line.plain).isEmpty, "\(state): \(line.plain)")
        }
    }

    @Test func everyDuplicateNoticesPlainSentencesArePlain() throws {
        let metadata = MovieMetadata(title: "Air", year: "2023", tmdbID: "964960")
        let entry = LibraryEntry(
            folderName: "Air (2023) {tmdb-964960}",
            folderPath: "/Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}",
            files: [LibraryFile(name: "Air (2023).mp4", sizeBytes: 1_420_000_000, modified: Date(timeIntervalSince1970: 1_788_000_000))]
        )
        let renamed = LibraryEntry(folderName: "Air (2023)", folderPath: "/Movies/Air (2023)", files: entry.files)
        let checks: [LibraryCheck] = [
            .checking(tmdbID: "964960"),
            .done(tmdbID: "964960", .unreachable(reason: "the volume is not mounted")),
            .done(tmdbID: "964960", .present([entry])),
            .done(tmdbID: "964960", .present([renamed])),
            .done(tmdbID: "964960", .present([entry, renamed])),
        ]
        for check in checks {
            guard let notice = DuplicatePresentation.notice(
                check: check, acknowledgement: nil, metadata: metadata, now: Date(timeIntervalSince1970: 1_789_000_000)
            ) else { continue }
            #expect(PlainLanguage.violations(in: notice.plainHeadline).isEmpty, "\(notice.kind): \(notice.plainHeadline)")
            for line in notice.plainLines {
                #expect(PlainLanguage.violations(in: line).isEmpty, "\(notice.kind): \(line)")
            }
        }
    }

    @Test func everyMenuUnavailableSaysNothingInThePlainRegister() {
        let reasons: [MenuUnavailable] = [
            .helperMissing(path: "/usr/local/bin/changeover-menudump"),
            .librariesMissing(["libdvdread", "libdvdcss"]),
            .noMenus,
            .failed("the helper timed out"),
        ]
        for reason in reasons {
            #expect(MenuStatusLine.plainLines(.unavailable(reason), scanFeatureTitle: 1).isEmpty, "\(reason)")
        }
        #expect(MenuStatusLine.plainLines(.reading, scanFeatureTitle: 1).isEmpty)
        #expect(MenuStatusLine.plainLines(.idle, scanFeatureTitle: 1).isEmpty)
    }

    @Test func theProgressAndOutcomeSentencesArePlain() {
        let sentences = [
            JobPresentation.plainETA(seconds: 30),
            JobPresentation.plainETA(seconds: 2_729),
            JobPresentation.plainETA(seconds: 3_900),
            JobPresentation.plainElapsed(2_472),
            DiscTitleFormatting.plainNoTitlesMessage,
            DiscTitleFormatting.plainPlayAllMessage,
            DiscTitleFormatting.plainSubtitleLine,
            DiscTitleFormatting.plainFeatureLabel,
            DiscTitleFormatting.noFeatureWording.plain,
            DiscTitleFormatting.acknowledgedWording.plain,
            UpgradePresentation.plainDeclinedSentence,
            UpgradePresentation.plainActionTitle,
            CancelPolicy.Decision.refuse(reason: CancelPolicy.Decision.organizingRefusal).plainRefusalReason ?? "",
        ]
        for sentence in sentences {
            #expect(PlainLanguage.violations(in: sentence).isEmpty, "\(sentence)")
        }
    }

    // MARK: - Fixtures

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 12, sizeBytes: 0, outputFileName: nil)
    }

    private static func scanned(titles: [DiscTitle], mainFeatureIndex: Int? = nil) -> ScanState {
        .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles),
            mainFeatureIndex: mainFeatureIndex,
            warnings: [],
            lastLine: nil
        ))
    }
}
