import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0189 — the projection from the app's own values onto the wire shape.
///
/// Every function under test takes plain values and returns plain values, which is
/// the only way any of this is reachable: there is no disc, no HandBrake and no
/// XPC connection here. What is being pinned is the judgement in the mapping —
/// which `FlowStep` payload becomes which string, what `percent` means when a step
/// has no percentage, when `film` is `nil` rather than empty — because those are
/// the decisions a later ticket will build on and the ones that would be silently
/// wrong.
struct BridgeStatusReaderTests {

    // MARK: - Flow step

    /// Hand-written rather than `String(describing:)`, which renders
    /// `insertDisc(Changeover.FlowStep.InsertReason.noDisc)` — a string carrying
    /// the module name, and therefore liable to change for reasons that have
    /// nothing to do with the flow. The wire value has to be stable.
    @Test func stepNamesCarryNoModulePrefixOrPayload() {
        #expect(BridgeStatusReader.name(of: .insertDisc(.noDisc)) == "insertDisc")
        #expect(BridgeStatusReader.name(of: .chooseMovie) == "chooseMovie")
        #expect(BridgeStatusReader.name(of: .confirm) == "confirm")
        #expect(BridgeStatusReader.name(of: .ripping(Self.jobID)) == "ripping")
        #expect(BridgeStatusReader.name(of: .done(Self.jobID)) == "done")
    }

    @Test func insertReasonsBecomeTheDetail() {
        #expect(BridgeStatusReader.detail(of: .insertDisc(.noDisc)) == "noDisc")
        #expect(BridgeStatusReader.detail(of: .insertDisc(.ejecting)) == "ejecting")
        #expect(BridgeStatusReader.detail(of: .insertDisc(.discUnavailable)) == "discUnavailable")
    }

    @Test func theJobIDBecomesTheDetail() {
        #expect(BridgeStatusReader.detail(of: .ripping(Self.jobID)) == Self.jobID.rawValue)
        #expect(BridgeStatusReader.detail(of: .done(Self.jobID)) == Self.jobID.rawValue)
    }

    /// The cases with no payload report no detail rather than an empty string a
    /// consumer would have to decide whether to render.
    @Test func thePayloadlessCasesHaveNoDetail() {
        #expect(BridgeStatusReader.detail(of: .chooseMovie) == nil)
        #expect(BridgeStatusReader.detail(of: .confirm) == nil)
    }

    /// An automatic eject carries the explanation the user never asked for and
    /// would otherwise never learn, so the CLI reports it too.
    @Test func anEjectExplanationBecomesTheDetail() throws {
        let explanation = EjectExplanation(cause: .alreadyInPlex, movie: "Garden State (2004)")
        let detail = try #require(
            BridgeStatusReader.detail(of: .ejected(explanation))
        )
        #expect(detail == explanation.headline)
        #expect(!detail.isEmpty)
    }

    @Test func theFlowStatusCarriesBothSensesOfWhereTheAppIs() {
        let status = BridgeStatusReader.flowStatus(step: .chooseMovie, phase: .selecting)
        #expect(status.step == "chooseMovie")
        #expect(status.discPhase == "selecting")
        #expect(status.discPhaseNumber == 2)
        #expect(status.discPhaseCount == 5)
        #expect(status.discPhaseTitle == DiscPhase.selecting.title)
    }

    // MARK: - Disc

    @Test func noDiscProjectsToNothing() {
        #expect(
            BridgeStatusReader.discStatus(nil, isEjecting: false, unavailable: false, hasMoreWork: false)
                == nil
        )
    }

    /// The insertion token, not the disc id. It is what distinguishes two visits by
    /// discs that share a path, a device node and an unknown identity.
    @Test func theInsertionTokenIsReportedEvenWithNoDiscIdentity() throws {
        let insertion = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/MOVIE"),
            deviceNode: "disk6",
            discID: nil
        )
        let status = try #require(
            BridgeStatusReader.discStatus(
                insertion,
                isEjecting: false,
                unavailable: false,
                hasMoreWork: false
            )
        )
        #expect(status.discID == nil)
        #expect(status.insertionID == insertion.insertionID.uuidString)
        #expect(status.label == "MOVIE")
        #expect(status.mountPath == "/Volumes/MOVIE")
    }

    /// A disc inserted while the screen was locked has no `/Volumes` entry at all,
    /// so `mountURL` holds the raw device and `label` must come from the recovered
    /// one rather than from the last path component — which would read `rdisk4`.
    @Test func anUnmountedDiscReportsItsRecoveredLabel() throws {
        var insertion = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/dev/rdisk4"),
            deviceNode: "disk4",
            discID: nil
        )
        insertion.isMounted = false
        insertion.volumeLabel = "GARDEN_STATE"

        let status = try #require(
            BridgeStatusReader.discStatus(
                insertion,
                isEjecting: false,
                unavailable: false,
                hasMoreWork: false
            )
        )
        #expect(status.isMounted == false)
        #expect(status.label == "GARDEN_STATE")
        #expect(status.mountPath == "/dev/rdisk4")
    }

    @Test func theDiscCarriesTheTransientFlags() throws {
        let status = try #require(
            BridgeStatusReader.discStatus(
                DiscInsertion(
                    mountURL: URL(fileURLWithPath: "/Volumes/MOVIE"),
                    deviceNode: "disk6",
                    discID: "abc"
                ),
                isEjecting: true,
                unavailable: true,
                hasMoreWork: true
            )
        )
        #expect(status.isEjecting)
        #expect(status.unavailable)
        #expect(status.hasMoreWork)
    }

    // MARK: - Scan

    @Test func anIdleScanReportsNothingElse() {
        let status = BridgeStatusReader.scanStatus(.idle, menuState: .idle)
        #expect(status.state == ScanStatus.State.idle)
        #expect(status.titleCount == nil)
        #expect(status.failure == nil)
    }

    @Test func aScannedDiscReportsItsFeatureDuration() {
        let titles = [
            DiscTitle(index: 1, durationSeconds: 6000, chapterCount: 20, sizeBytes: 0, outputFileName: nil),
            DiscTitle(index: 2, durationSeconds: 300, chapterCount: 1, sizeBytes: 0, outputFileName: nil),
        ]
        let result = DiscScanner.Result(
            disc: DiscInfo(volumeName: "MOVIE", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1,
            warnings: ["a warning"]
        )

        let status = BridgeStatusReader.scanStatus(.scanned(result), menuState: .idle)
        #expect(status.state == ScanStatus.State.scanned)
        #expect(status.titleCount == 2)
        #expect(status.mainFeatureIndex == 1)
        #expect(status.featureDurationSeconds == 6000)
        #expect(status.warnings == ["a warning"])
    }

    /// `mainFeatureIndex` is a HandBrake title number, not an array index. Looking
    /// it up by position would report the wrong title's duration on any disc whose
    /// titles do not start at 1 or are not contiguous.
    @Test func theFeatureIsFoundByTitleNumberNotByPosition() {
        let titles = [
            DiscTitle(index: 7, durationSeconds: 1200, chapterCount: 2, sizeBytes: 0, outputFileName: nil),
            DiscTitle(index: 9, durationSeconds: 7200, chapterCount: 24, sizeBytes: 0, outputFileName: nil),
        ]
        let result = DiscScanner.Result(
            disc: DiscInfo(volumeName: "MOVIE", driveName: "disk6", titles: titles),
            mainFeatureIndex: 9,
            warnings: []
        )
        #expect(
            BridgeStatusReader.scanStatus(.scanned(result), menuState: .idle)
                .featureDurationSeconds == 7200
        )
    }

    /// Spelled out rather than `String(describing:)`, because these are the strings
    /// a person reads when a disc will not scan.
    @Test func aMissingToolNamesThePathAndTheFix() {
        let text = BridgeStatusReader.describe(.toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"))
        #expect(text.contains("/opt/homebrew/bin/HandBrakeCLI"))
        #expect(text.contains("brew install handbrake"))
    }

    @Test func everyScanFailureHasItsOwnSentence() {
        let failures: [DiscScanner.Failure] = [
            .toolMissing(path: "/x"),
            .launchFailure("nope"),
            .toolExited(code: 3),
            .jsonMissing,
            .titleSetCorrupted,
            .cancelled,
        ]
        let sentences = failures.map(BridgeStatusReader.describe)
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == failures.count)
    }

    @Test func aFailedScanCarriesTheSentenceAndNoCounts() {
        let status = BridgeStatusReader.scanStatus(.failed(.titleSetCorrupted), menuState: .idle)
        #expect(status.state == ScanStatus.State.failed)
        #expect(status.failure?.contains("unreadable") == true)
        #expect(status.titleCount == nil)
    }

    @Test func hasScannedIsOnlyTrueForAFinishedScan() {
        #expect(!BridgeStatusReader.hasScanned(.idle))
        #expect(!BridgeStatusReader.hasScanned(.scanning))
        #expect(!BridgeStatusReader.hasScanned(.failed(.cancelled)))
        #expect(
            BridgeStatusReader.hasScanned(
                .scanned(
                    DiscScanner.Result(
                        disc: DiscInfo(volumeName: "M", driveName: "d", titles: []),
                        mainFeatureIndex: nil,
                        warnings: []
                    )
                )
            )
        )
    }

    // MARK: - Film

    @Test func noMetadataProjectsToNothing() {
        #expect(
            BridgeStatusReader.filmStatus(nil, resolvedBy: "label", chosenBy: FilmStatus.Chooser.automation, libraryCheck: .idle)
                == nil
        )
    }

    /// Taken from `MovieMetadata` rather than rebuilt, so the names the CLI reports
    /// are the names `PlexOrganizer` will actually write — including the strict
    /// `{tmdb-ID}` folder tag, which is what lets Plex tell apart films sharing a
    /// title.
    @Test func theNamesComeFromMovieMetadataItself() throws {
        let metadata = MovieMetadata(title: "Garden State", year: "2004", tmdbID: "401")
        let film = try #require(
            BridgeStatusReader.filmStatus(
                metadata,
                resolvedBy: "label",
                chosenBy: FilmStatus.Chooser.automation,
                libraryCheck: .idle
            )
        )
        #expect(film.folderName == metadata.folderName)
        #expect(film.fileName == metadata.fileName)
        #expect(film.folderName.contains("{tmdb-401}"))
        #expect(!film.fileName.contains("{tmdb-"))
    }

    /// A film the user picked reports `user`, not whatever the app's own ladder had
    /// most recently concluded. A caller reviewing a choice has to be able to tell
    /// "a person decided this" from "the volume label suggested it".
    @Test func aUserChoiceOverridesTheResolvedBy() throws {
        let film = try #require(
            BridgeStatusReader.filmStatus(
                MovieMetadata(title: "T", year: "2000", tmdbID: "1"),
                resolvedBy: "menuTitle",
                chosenBy: FilmStatus.Chooser.user,
                libraryCheck: .idle
            )
        )
        #expect(film.chosenByUser)
        #expect(film.resolvedBy == "user")
    }

    @Test func theLibraryCheckIsReportedAsItsOutcome() {
        #expect(BridgeStatusReader.describe(.idle) == "idle")
        #expect(BridgeStatusReader.describe(.checking(tmdbID: "401")) == "checking")
        #expect(BridgeStatusReader.describe(.done(tmdbID: "401", .absent)) == "absent")
        #expect(
            BridgeStatusReader.describe(.done(tmdbID: "401", .unreachable(reason: "no mount")))
                == "unreachable"
        )
    }

    // MARK: - Job progress

    /// `nil` is a real answer, not a gap. A metadata-upgrade remux has no
    /// percentage at all, and a consumer must render "working" rather than a zero
    /// that looks like a stalled encode.
    @Test func aRemuxHasNoPercentage() {
        #expect(BridgeStatusReader.percent(of: JobProgress.remux()) == nil)
    }

    /// Muxing is the tail of an encode with no percentage of its own. Reporting its
    /// placeholder fraction would show 100 % while real work continues.
    @Test func muxingHasNoPercentage() {
        let progress = JobProgress(
            unit: .feature,
            encode: HandBrakeProgress(stage: .muxing, fraction: 1, task: 1, taskCount: 1),
            receivedAt: Date()
        )
        #expect(BridgeStatusReader.percent(of: progress) == nil)
    }

    @Test func anEncodeFractionBecomesAPercentage() {
        let progress = JobProgress(
            unit: .feature,
            encode: HandBrakeProgress(stage: .encoding, fraction: 0.425, task: 1, taskCount: 1),
            receivedAt: Date()
        )
        #expect(BridgeStatusReader.percent(of: progress) == 42.5)
    }

    @Test func noProgressMeansNoPercentage() {
        #expect(BridgeStatusReader.percent(of: nil) == nil)
    }

    @Test func unitsAreNamedStably() {
        #expect(BridgeStatusReader.unitName(of: .feature) == "feature")
        #expect(BridgeStatusReader.unitName(of: .fallback) == "fallback")
        #expect(BridgeStatusReader.unitName(of: .remux) == "remux")
        #expect(
            BridgeStatusReader.unitName(of: .extra(index: 2, count: 3, titleIndex: 7)) == "extra"
        )
    }

    /// 1-based, for "extra 2 of 3", and only set for the extras unit.
    @Test func theExtraCountersAreOnlySetForExtras() {
        let extra = JobProgress.Unit.extra(index: 2, count: 3, titleIndex: 7)
        #expect(BridgeStatusReader.extraIndex(of: extra) == 2)
        #expect(BridgeStatusReader.extraCount(of: extra) == 3)
        #expect(BridgeStatusReader.extraIndex(of: .feature) == nil)
        #expect(BridgeStatusReader.extraCount(of: .feature) == nil)
        #expect(BridgeStatusReader.extraIndex(of: nil) == nil)
    }

    // MARK: - Job outcome

    @Test func anOutcomeIsReportedAsItsTerminalPhase() {
        #expect(
            BridgeStatusReader.outcomeName(.succeeded(destination: URL(fileURLWithPath: "/x")))
                == "succeeded"
        )
        #expect(
            BridgeStatusReader.outcomeName(
                .failed(JobFailure(stage: .encode, reason: .cancelled))
            ) == "cancelled"
        )
        #expect(
            BridgeStatusReader.outcomeName(
                .failed(JobFailure(stage: .encode, reason: .diskFull))
            ) == "failed"
        )
        #expect(BridgeStatusReader.outcomeName(nil) == nil)
    }

    /// Through `FailurePresenter`, not a second rendering here: the presenter is
    /// where the wording lives and it already knows that the same reason means
    /// different things at different stages. A copy would let the CLI's answer stop
    /// matching the one on screen.
    @Test func aFailureIsWordedTheWayTheAppWordsIt() throws {
        let failure = JobFailure(stage: .encode, reason: .diskFull)
        let reported = try #require(BridgeStatusReader.failureReason(.failed(failure)))
        #expect(reported == FailurePresenter.headline(for: failure.reason, stage: failure.stage))
        #expect(!reported.isEmpty)
    }

    @Test func aSucceededJobHasNoFailureReason() {
        #expect(
            BridgeStatusReader.failureReason(.succeeded(destination: URL(fileURLWithPath: "/x"))) == nil
        )
        #expect(BridgeStatusReader.failureReason(nil) == nil)
    }

    // MARK: - Start gate

    /// `permitsStart`, never `== .ready`. There are two permitting cases and they
    /// start different jobs; comparing against one of them is exactly the bug that
    /// flag exists to prevent.
    @Test func bothPermittingDecisionsReportAsPermitted() {
        #expect(BridgeStatusReader.startStatus(.ready, autoStartSecondsRemaining: nil).permitted)
        #expect(
            BridgeStatusReader.startStatus(.readyForExtrasOnly, autoStartSecondsRemaining: nil)
                .permitted
        )
    }

    /// The reason is the point of reporting the gate at all: an agent that can only
    /// see a disabled button has to guess.
    @Test func everyRefusalCarriesAReason() {
        for decision in StartDecision.allCases where !decision.permitsStart {
            let status = BridgeStatusReader.startStatus(decision, autoStartSecondsRemaining: nil)
            #expect(!status.permitted, "\(decision) should not be permitted")
            #expect(status.reason != nil, "\(decision) reports no reason")
            #expect(status.decision == decision.rawValue)
        }
    }

    /// Taken verbatim from the app, so the CLI and the window can never word the
    /// same refusal differently.
    @Test func theWordingIsTheAppsOwn() {
        let status = BridgeStatusReader.startStatus(.scanInProgress, autoStartSecondsRemaining: nil)
        #expect(status.reason == StartDecision.scanInProgress.reason)
        #expect(status.plainReason == StartDecision.scanInProgress.plainReason)
    }

    /// Present so an agent can tell "the user has not pressed Start" from "the app
    /// is about to press it for them". Acting on the first and waiting on the
    /// second are different.
    @Test func theCountdownIsReportedWhenOneIsRunning() {
        #expect(
            BridgeStatusReader.startStatus(.ready, autoStartSecondsRemaining: 7)
                .autoStartSecondsRemaining == 7
        )
        #expect(
            BridgeStatusReader.startStatus(.ready, autoStartSecondsRemaining: nil)
                .autoStartSecondsRemaining == nil
        )
    }

    // MARK: - Helpers

    private static let jobID = JobID.make()
}

// MARK: - Library

/// #0189 — the paths and naming conventions `status` reports under `library`.
///
/// Reported because an agent must never guess them: the user chose the media root,
/// it may be a NAS mount, and nothing about it is derivable. The conventions are
/// reported because getting them wrong is worse than failing — a near miss on an
/// extras folder name is a folder Plex scans as a film.
@MainActor
struct BridgeLibraryStatusTests {

    @Test func thePathsAreDerivedFromTheOneRootTheUserSet() {
        let settings = AppSettings(defaults: Self.emptyDefaults())
        settings.plexMediaRoot = "/Volumes/Media/Media"

        let library = BridgeStatusReader.libraryStatus(settings: settings)
        #expect(library.mediaRoot == "/Volumes/Media/Media")
        #expect(library.moviesPath == settings.plexMoviesPath)
        #expect(library.tvShowsPath == settings.plexTVPath)
        #expect(library.moviesPath == "/Volumes/Media/Media/Movies")
        #expect(library.tvShowsPath == "/Volumes/Media/Media/TV Shows")
    }

    /// An unconfigured app reports the empty root rather than inventing a
    /// plausible one. An agent told `/Users/me/Movies` when nothing is configured
    /// would report films missing from a folder that was never the library.
    @Test func anUnconfiguredAppReportsAnEmptyRoot() {
        let settings = AppSettings(defaults: Self.emptyDefaults())
        let library = BridgeStatusReader.libraryStatus(settings: settings)
        #expect(library.mediaRoot.isEmpty)
    }

    /// Taken from `PlexExtra.Kind` rather than written out in the bridge, so a kind
    /// added to the app appears in the CLI's answer without anyone remembering to.
    @Test func theExtrasFoldersComeFromPlexExtraItself() {
        let settings = AppSettings(defaults: Self.emptyDefaults())
        let library = BridgeStatusReader.libraryStatus(settings: settings)
        #expect(library.extrasFolders == PlexExtra.Kind.allCases.map(\.folderName))
        #expect(Set(library.extrasFolders) == PlexExtra.recognisedFolderNames)
    }

    /// The spelling is not cosmetic. Plex excludes these exact names from its movie
    /// scan, so "Behind the Scenes" is an unrecognised folder that gets filed as a
    /// second movie with a nonsense name.
    @Test func theExtrasFoldersAreSpelledAsPlexSpellsThem() {
        let settings = AppSettings(defaults: Self.emptyDefaults())
        let folders = BridgeStatusReader.libraryStatus(settings: settings).extrasFolders
        #expect(folders.contains("Behind The Scenes"))
        #expect(!folders.contains("Behind the Scenes"))
    }

    @Test func theNamingPatternsAreTheStrictPlexConvention() {
        let settings = AppSettings(defaults: Self.emptyDefaults())
        let library = BridgeStatusReader.libraryStatus(settings: settings)
        #expect(library.filmPattern == "Movies/Title (Year) {tmdb-ID}/Title (Year).mp4")
        #expect(library.extraPattern.hasPrefix("Movies/Title (Year) {tmdb-ID}/"))
        #expect(library.episodePattern.hasPrefix("TV Shows/"))
    }

    /// A defaults suite of its own, so a test never reads or writes the developer's
    /// real settings — the same discipline `AppSettingsTests` follows.
    private static func emptyDefaults() -> UserDefaults {
        let suite = "co.sstools.Changeover.bridge-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

/// #0198 — HandBrake's scan is not the encode's progress.
///
/// Reported from an agent session driving joe, build 20261004053501, against
/// Two Towers. `watch --json` showed `job.percent` climbing 0 → 90 % in ten
/// seconds, resetting to 0, and only then the real encode starting at 1 %:
///
///     05:42:00  0%     05:42:09  20% … 05:42:10  90%
///     05:42:11  0%     then "1%, feature, eta 3057s, 83.5 fps"
///
/// Those were HandBrake's `Scanning title 1 of 1, NN %` lines. An agent
/// reading `job.percent` would have concluded the encode was nearly finished
/// after ten seconds and then that it had restarted. Neither happened.
///
/// `muxing` was already excluded for the same reason — a stage whose
/// percentage is not the job's — and `scanning` was simply missed.
@Suite struct ScanProgressIsNotEncodeProgressTests {

    private static func progress(_ stage: HandBrakeProgress.Stage,
                                 _ fraction: Double) -> JobProgress {
        JobProgress(unit: .feature,
                    encode: HandBrakeProgress(stage: stage, fraction: fraction,
                                             task: 1, taskCount: 1),
                    receivedAt: Date())
    }

    /// The reported case, directly.
    @Test func ascanReportsNoPercentage() {
        #expect(BridgeStatusReader.percent(of: Self.progress(.scanning, 0.9)) == nil,
                "90% through the scan is not 90% through the job")
    }

    /// `nil`, never zero. A zero reads as a stalled encode, which is a
    /// different wrong answer rather than no answer.
    @Test func ascanReportsNilRatherThanZero() {
        #expect(BridgeStatusReader.percent(of: Self.progress(.scanning, 0)) == nil)
    }

    /// The encode itself is unchanged — this must not have silenced the
    /// progress a consumer actually wants.
    @Test func theEncodeStillReportsItsPercentage() {
        #expect(BridgeStatusReader.percent(of: Self.progress(.encoding, 0.42)) == 42)
        #expect(BridgeStatusReader.percent(of: Self.progress(.encoding, 0)) == 0)
    }

    /// Muxing was already excluded, for the same reason.
    @Test func muxingStillReportsNoPercentage() {
        #expect(BridgeStatusReader.percent(of: Self.progress(.muxing, 1)) == nil)
    }

    /// And the stage is reported, so a consumer can say "scanning" instead of
    /// inferring it from a number that does not mean what it looks like.
    @Test func thestageIsReportedSoAConsumerCanTellThemApart() {
        #expect(BridgeStatusReader.stageName(of: Self.progress(.scanning, 0.9)) == "scanning")
        #expect(BridgeStatusReader.stageName(of: Self.progress(.encoding, 0.42)) == "encoding")
        #expect(BridgeStatusReader.stageName(of: Self.progress(.muxing, 1)) == "muxing")
        #expect(BridgeStatusReader.stageName(of: nil) == nil)
    }
}
