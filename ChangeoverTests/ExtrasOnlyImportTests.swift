import Foundation
import Testing
@testable import Changeover

// MARK: - The pure seams

/// Covers #0186: importing only a disc's bonus features into a film the
/// library already holds.
///
/// The user, 2026-09-30: "we want to support users who have already used their
/// discs to import the main feature but now want to also bring in bonus
/// features." #0185 stopped the app ejecting such a disc; this is the half that
/// lets the extras come off it.
///
/// The whole hazard lives in one sentence: an extras-only run must never file
/// anything over the film's own file in Plex. That copy was made from a disc
/// the user may no longer have, `PlexOrganizer.move` replaces whatever is at
/// `.feature`'s path on purpose (#0012), and there is no undo. So the first
/// three tests here are about a *value not existing*, not about a check being
/// remembered.
struct ExtrasOnlyIntentTests {

    /// The guarantee, stated as the type's own behaviour.
    ///
    /// `LibraryDestination.feature` is the only value in the app that resolves
    /// to the film's own file. `DVDPipeline.run()` binds this with `if let`, so
    /// for `.extrasOnly` the compiler will not enter the branch that holds the
    /// HandBrake pass over the disc, #0037's duration check, #0015's fallback
    /// and the `PlexOrganizer.move` call. Falsify by returning `.feature` from
    /// both cases and watching `theExistingFilmFileIsNeverADestination` below
    /// start overwriting a file.
    @Test func anExtrasOnlyRunHasNoFeatureDestinationAtAll() {
        #expect(JobIntent.extrasOnly.featureDestination == nil)
        #expect(JobIntent.film.featureDestination == .feature)
    }

    /// And the extras themselves never could name it: `ExtrasPlan.Item`
    /// produces only `.extra` or `.bonusFeature`, whatever it was built from.
    @Test func noExtraCanResolveToTheFeaturesOwnDestination() {
        let clip = ExtrasPlan.Item(titleIndex: 7, durationSeconds: 300,
                                   frameRate: nil, interlaceDetected: nil)
        let bonus = ExtrasPlan.Item(titleIndex: 8, durationSeconds: 3_534,
                                    frameRate: nil, interlaceDetected: nil,
                                    filing: .bonusFeature(kind: .behindTheScenes, label: "making Signs"))
        #expect(clip.destination == .bonusFeature(titleIndex: 7, kind: .other, label: ""))
        #expect(bonus.destination == .bonusFeature(titleIndex: 8, kind: .behindTheScenes, label: "making Signs"))
        for item in [clip, bonus] {
            #expect(item.destination != .feature)
        }
    }

    /// `.film` is the default, so every construction site that predates this
    /// ticket means what it always meant: a run that encodes the film.
    ///
    /// Deliberately NOT a test about decoding an older *recorded* request.
    /// Nothing in this app encodes or decodes a `RipRequest` — `Codable` is
    /// here for the Phase 4 wire and for round-trip tests — so there is no
    /// stored history to stay compatible with, and asserting one pins a
    /// fiction. Swift's synthesised decoder does not fall back to a property's
    /// default for a missing key, as `extraTitleIndices` demonstrates, so the
    /// test that claimed otherwise was describing the opposite of the truth.
    @Test func anOrdinaryRequestIsAFilmRunWithoutSayingSo() throws {
        let json = """
        {"id": 452, "title": "Signs", "release_date": "2002-08-02", "poster_path": null}
        """.data(using: .utf8)!
        let metadata = MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
        let request = RipRequest(metadata: metadata,
                                 featureTitleIndex: 1, audioTrackNumbers: [1])
        #expect(request.intent == JobIntent.film)
        #expect(!request.isExtrasOnly)
        #expect(request.intent.featureDestination == LibraryDestination.feature,
                "an ordinary run still has a feature to file")
    }

    /// And the intent survives a round trip, which is what `Codable` is for.
    @Test func theIntentSurvivesARoundTrip() throws {
        let json = """
        {"id": 452, "title": "Signs", "release_date": "2002-08-02", "poster_path": null}
        """.data(using: .utf8)!
        let metadata = MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
        var request = RipRequest(metadata: metadata,
                                 featureTitleIndex: 1, extraTitleIndices: [8],
                                 audioTrackNumbers: [1])
        request.intent = .extrasOnly
        let decoded = try JSONDecoder().decode(
            RipRequest.self, from: try JSONEncoder().encode(request))
        #expect(decoded.intent == JobIntent.extrasOnly)
        #expect(decoded.isExtrasOnly)
        #expect(decoded == request)
    }
}

/// #0186 — `LibraryPaths.filmFolder` is the one writer of "the film's folder",
/// and these pin that the folder an extras-only run *checks for* is the folder
/// a bonus feature is actually filed inside. Two copies of that expression is
/// how #0172's class of bug starts, and here a disagreement would mean checking
/// one folder and writing into another.
struct ExtrasOnlyDestinationTests {

    static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 452, "title": "Signs", "release_date": "2002-08-02", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    static let roots = LibraryRoots(mediaRoot: "/Volumes/Plex")

    @Test func theFilmFolderIsWhereTheFeatureIsFiled() throws {
        let metadata = try Self.metadata()
        let folder = LibraryPaths.filmFolder(metadata: metadata, roots: Self.roots)
        #expect(folder == "/Volumes/Plex/Movies/Signs (2002) {tmdb-452}")
        #expect(LibraryPaths.resolve(.feature, metadata: metadata, roots: Self.roots,
                                     sourceExtension: "mp4").folder == folder)
    }

    /// #0174/#0178's path, unchanged — and its *parent* is the folder the
    /// extras-only precondition demands.
    @Test func aBonusFeatureIsFiledInsideThatSameFilmFolder() throws {
        let metadata = try Self.metadata()
        let folder = LibraryPaths.filmFolder(metadata: metadata, roots: Self.roots)
        let resolved = LibraryPaths.resolve(
            .bonusFeature(titleIndex: 11, kind: .behindTheScenes, label: "making Signs: a commentary"),
            metadata: metadata, roots: Self.roots, sourceExtension: "mp4"
        )
        #expect(resolved.folder == folder + "/Behind The Scenes")
        #expect(resolved.file == folder + "/Behind The Scenes/making Signs- a commentary.mp4")
        #expect((resolved.folder as NSString).deletingLastPathComponent == folder)
    }

    /// A clip still goes to the non-Plex `Clips` tree, which is outside the
    /// film's folder entirely — so an extras-only run whose only ticked title
    /// is an unnamed clip writes nothing under `Movies/` at all.
    @Test func anUnnamedExtraLandsUnderOtherInsideTheFilmFolder() throws {
        let metadata = try Self.metadata()
        let resolved = LibraryPaths.resolve(.bonusFeature(titleIndex: 7, kind: .other, label: ""), metadata: metadata,
                                            roots: Self.roots, sourceExtension: "mp4")
        #expect(resolved.file
                == "/Volumes/Plex/Movies/Signs (2002) {tmdb-452}/Other/Bonus Feature - t07.mp4",
                "#0192 — an unnamed extra is filed with its film, not hidden in Clips")
        #expect(resolved.folder.hasPrefix(Self.roots.moviesPath),
                "#0192 — every extra is inside the Plex library now, with its film")
    }
}

/// #0186 — the precondition, and the sentence it refuses with.
struct ExtrasOnlyReadinessTests {

    static let folder = "/Volumes/Plex/Movies/Signs (2002) {tmdb-452}"

    @Test func aTickedExtraAndAFolderThatIsThereIsReady() {
        let readiness = ExtrasOnlyImport.readiness(filmFolder: Self.folder, exists: true, extraCount: 2)
        #expect(readiness == .ready)
        #expect(ExtrasOnlyImport.refusal(for: readiness) == nil)
    }

    /// Requirement: refuse rather than invent a folder.
    ///
    /// Creating it would be the app making a film folder out of a TMDB id the
    /// user's library does not use — and Plex would then show a film folder
    /// holding featurettes and no film, while the copy they actually have sat
    /// untouched under its own name. A refusal is recoverable; that is not.
    @Test func aMissingFilmFolderRefusesAndNamesThePath() throws {
        let readiness = ExtrasOnlyImport.readiness(filmFolder: Self.folder, exists: false, extraCount: 2)
        #expect(readiness == .noFilmFolder(path: Self.folder))

        let failure = try #require(ExtrasOnlyImport.refusal(for: readiness))
        // `.preflight` is load-bearing: the check runs before this job creates
        // anything, and `.preflight` is the one stage whose disposition
        // (`.nothingCreated`) neither deletes nor keeps a working folder.
        #expect(failure.stage == .preflight)
        #expect(WorkingFiles.disposition(for: .failed(failure), jobDirectoryCreated: false) == .nothingCreated)
        guard case .unknown(let detail) = failure.reason else {
            Issue.record("expected .unknown, got \(failure.reason)")
            return
        }
        #expect(detail.contains(Self.folder))
        // The person has to be able to act on it, so the sentence says what to
        // do and says the library was left alone.
        #expect(detail.contains("Import the film itself first"))
        #expect(detail.contains("Nothing was created, moved or replaced."))
    }

    /// A folder path that exists as a *file* reads as absent, so the run
    /// refuses now rather than letting `createDirectory` fail later, after the
    /// extras have already been encoded.
    @Test func aPathThatIsAFileCountsAsNoFolder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtrasOnlyReadiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("not-a-folder")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        #expect(await ExtrasOnlyImport.folderExists(dir.path))
        #expect(await ExtrasOnlyImport.folderExists(file.path) == false)
        #expect(await ExtrasOnlyImport.folderExists(dir.appendingPathComponent("nope").path) == false)
    }

    /// Nothing ticked is not a success with zero extras — it is a job that
    /// would open the drive, write a working folder and claim it had imported
    /// something.
    @Test func nothingTickedRefuses() throws {
        let readiness = ExtrasOnlyImport.readiness(filmFolder: Self.folder, exists: true, extraCount: 0)
        #expect(readiness == .nothingTicked)
        let failure = try #require(ExtrasOnlyImport.refusal(for: readiness))
        #expect(failure.stage == .preflight)
    }

    /// Order matters for the sentence the user reads: with nothing ticked there
    /// is nothing to say about a folder, whether or not it is there.
    @Test func nothingTickedOutranksAMissingFolder() {
        #expect(ExtrasOnlyImport.readiness(filmFolder: Self.folder, exists: false, extraCount: 0)
                == .nothingTicked)
    }
}

// MARK: - The Start gate

/// #0186 — the gate. An extras-only run has to be a *legitimate, labelled*
/// outcome, and it must not be reachable by ticking "Replace the Existing
/// File", which means something else entirely.
struct ExtrasOnlyStartGateTests {

    static let entry = LibraryEntry(
        folderName: "Signs (2002) {tmdb-452}",
        folderPath: "/Volumes/Plex/Movies/Signs (2002) {tmdb-452}",
        files: [LibraryFile(name: "Signs (2002).mp4")]
    )
    static let present = LibraryCheck.done(tmdbID: "452", .present([Self.entry]))
    static let extrasOnlyAck = ExtrasOnlyAcknowledgement(movieID: 452, folderPath: Self.entry.folderPath)
    static let replaceAck = ReplaceAcknowledgement(movieID: 452, folderPath: Self.entry.folderPath)

    static func scanned() -> ScanState {
        let titles = [
            DiscTitle(index: 1, durationSeconds: 6_060, chapterCount: 20, sizeBytes: 0, outputFileName: nil),
            DiscTitle(index: 11, durationSeconds: 3_534, chapterCount: 1, sizeBytes: 0, outputFileName: nil),
        ]
        return .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "SIGNS", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1, warnings: []))
    }

    static func decide(
        libraryCheck: LibraryCheck = Self.present,
        replaceAcknowledgement: ReplaceAcknowledgement? = nil,
        extrasOnlyAcknowledgement: ExtrasOnlyAcknowledgement? = nil,
        tickedExtras: Int = 0,
        featureChoices: FeatureChoices = FeatureChoices()
    ) -> StartDecision {
        StartGate.decide(
            hasMovieSelected: true,
            isRunning: false,
            hasDisc: true,
            scanState: Self.scanned(),
            selectedTitleIndex: 1,
            selectedAudioTrackNumbers: [],
            runtimeLookup: .unavailable(movieID: 452, reason: .noRuntimeOnTMDB),
            mismatchAcknowledgement: nil,
            libraryCheck: libraryCheck,
            replaceAcknowledgement: replaceAcknowledgement,
            featureChoices: featureChoices,
            extrasOnlyAcknowledgement: extrasOnlyAcknowledgement,
            tickedExtras: tickedExtras
        )
    }

    /// #0143's refusal is untouched for the disc it was written for: a film
    /// already in Plex, with nothing else on the disc asked for.
    @Test func aPlainDuplicateWithNothingTickedIsStillRefused() {
        #expect(Self.decide() == .duplicateUnacknowledged)
        #expect(Self.decide().permitsStart == false)
    }

    /// Ticking an extra is not consent to anything. Before #0186 the user's
    /// only way forward was a button that overwrites the film; the fix must not
    /// be a *second* silent path to a job they did not ask for.
    @Test func tickingAnExtraWithoutPressingTheButtonChangesNothing() {
        #expect(Self.decide(tickedExtras: 3) == .duplicateUnacknowledged)
    }

    /// And the button alone is not enough either: with nothing ticked the run
    /// would encode nothing and file nothing.
    @Test func theButtonWithNothingTickedIsNotAStart() {
        #expect(Self.decide(extrasOnlyAcknowledgement: Self.extrasOnlyAck, tickedExtras: 0)
                == .duplicateUnacknowledged)
    }

    /// Both together: a legitimate, labelled start.
    @Test func aTickedExtraPlusTheButtonPermitsAnExtrasOnlyRun() {
        let decision = Self.decide(extrasOnlyAcknowledgement: Self.extrasOnlyAck, tickedExtras: 2)
        #expect(decision == .readyForExtrasOnly)
        #expect(decision.permitsStart)
        // Labelled, not silent: this is the one enabled state whose behaviour
        // differs from "rip this movie", so it says so in both registers.
        #expect(decision.reason?.contains("extras only") == true)
        #expect(decision.plainReason?.isEmpty == false)
    }

    /// **"Replace the Existing File" still means a full re-rip.**
    ///
    /// Checked first in `libraryDecision`, so a disc carrying both answers is
    /// never quietly downgraded to "just the extras" — the user asked for the
    /// film, and Start says `.ready`, which is a `.film` job.
    @Test func replaceStillMeansAFullReRipAndOutranksTheExtrasOnlyAnswer() {
        #expect(Self.decide(replaceAcknowledgement: Self.replaceAck) == .ready)
        #expect(Self.decide(replaceAcknowledgement: Self.replaceAck,
                            extrasOnlyAcknowledgement: Self.extrasOnlyAck,
                            tickedExtras: 2) == .ready)
    }

    /// #0032's lesson, applied to the new acknowledgement: an answer given for
    /// one film — or for another folder of the same film — must never permit a
    /// run here.
    @Test func anAcknowledgementForAnotherFilmOrFolderIsNotHonoured() {
        #expect(Self.decide(
            extrasOnlyAcknowledgement: ExtrasOnlyAcknowledgement(movieID: 78, folderPath: Self.entry.folderPath),
            tickedExtras: 2) == .duplicateUnacknowledged)
        #expect(Self.decide(
            extrasOnlyAcknowledgement: ExtrasOnlyAcknowledgement(movieID: 452, folderPath: "/Volumes/Plex/Movies/somewhere else"),
            tickedExtras: 2) == .duplicateUnacknowledged)
    }

    /// The upgrade button rewrites the library file by remux, which is the one
    /// thing an extras-only import promises not to do. `decideUpgrade` passes
    /// no extras-only acknowledgement at all, so its shared `libraryDecision`
    /// call can never answer `.readyForExtrasOnly`.
    @Test func theUpgradeDecisionCanNeverSayExtrasOnly() {
        #expect(StartGate.libraryDecision(Self.present, replaceAcknowledgement: nil)
                == .duplicateUnacknowledged)
        #expect(StartGate.libraryDecision(Self.present, replaceAcknowledgement: Self.replaceAck)
                == .ready)
    }

    /// #0167's whole-disc refusal yields to it too, for the same reason #0185
    /// stopped the automatic eject firing: "every film on this disc is already
    /// in Plex" stopped being the same statement as "nothing to import" the
    /// moment the app learned to take a making-of.
    @Test func everyFilmAlreadyInPlexYieldsToATickedAndAcknowledgedExtra() {
        let choices = FeatureChoices(featureCount: 2, chosenCount: 2, importableCount: 0)
        #expect(Self.decide(featureChoices: choices) == .everyFilmAlreadyInPlex)
        #expect(Self.decide(extrasOnlyAcknowledgement: Self.extrasOnlyAck,
                            tickedExtras: 1,
                            featureChoices: choices) == .readyForExtrasOnly)
        // And a disc that still has a film to import is unaffected — the film
        // comes first and its own extras ride along with it.
        #expect(Self.decide(extrasOnlyAcknowledgement: Self.extrasOnlyAck,
                            tickedExtras: 1,
                            featureChoices: FeatureChoices(featureCount: 2, chosenCount: 2, importableCount: 1))
                == .ready)
    }

    /// Ordered last, like #0143's own refusal: an extras-only start must never
    /// be offered before the disc has even been scanned, or in place of an
    /// earlier refusal the person has to act on first.
    @Test func theExtrasOnlyAnswerIsStillRankedBehindEveryOtherRefusal() {
        #expect(StartGate.decide(
            hasMovieSelected: true, isRunning: true, hasDisc: true,
            scanState: Self.scanned(), selectedTitleIndex: 1, selectedAudioTrackNumbers: [],
            runtimeLookup: .unavailable(movieID: 452, reason: .noRuntimeOnTMDB),
            mismatchAcknowledgement: nil, libraryCheck: Self.present,
            extrasOnlyAcknowledgement: Self.extrasOnlyAck, tickedExtras: 2) == .jobRunning)
        #expect(StartGate.decide(
            hasMovieSelected: true, isRunning: false, hasDisc: true,
            scanState: .scanning, selectedTitleIndex: nil, selectedAudioTrackNumbers: [],
            runtimeLookup: .unavailable(movieID: 452, reason: .noRuntimeOnTMDB),
            mismatchAcknowledgement: nil, libraryCheck: Self.present,
            extrasOnlyAcknowledgement: Self.extrasOnlyAck, tickedExtras: 2) == .scanInProgress)
    }

    /// `canStart` is the `Bool` view of the same answer, and it has to admit
    /// both permitting cases — a control that asked `== .ready` would leave the
    /// new one disabled with a caption saying Start works.
    @Test func canStartAdmitsBothPermittingDecisions() {
        func canStart(extrasOnly: ExtrasOnlyAcknowledgement?, ticked: Int) -> Bool {
            StartGate.canStart(
                hasMovieSelected: true, isRunning: false, hasDisc: true,
                scanState: Self.scanned(), selectedTitleIndex: 1, selectedAudioTrackNumbers: [],
                runtimeLookup: .unavailable(movieID: 452, reason: .noRuntimeOnTMDB),
                mismatchAcknowledgement: nil, libraryCheck: Self.present,
                extrasOnlyAcknowledgement: extrasOnly, tickedExtras: ticked)
        }
        #expect(canStart(extrasOnly: nil, ticked: 2) == false)
        #expect(canStart(extrasOnly: Self.extrasOnlyAck, ticked: 2))
    }
}

// MARK: - The notice that offers it

/// #0186 — the panel. A film already in Plex used to offer exactly one action:
/// replace a file the user did not want replaced.
struct ExtrasOnlyNoticeTests {

    static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 452, "title": "Signs", "release_date": "2002-08-02", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    static let entry = ExtrasOnlyStartGateTests.entry
    static let present = ExtrasOnlyStartGateTests.present
    static let ack = ExtrasOnlyStartGateTests.extrasOnlyAck

    @Test func theOfferAppearsOnlyWhenSomethingIsTicked() throws {
        let metadata = try Self.metadata()
        let without = try #require(DuplicatePresentation.notice(
            check: Self.present, acknowledgement: nil, metadata: metadata, now: Date()))
        #expect(without.offersExtrasOnly == false)
        #expect(without.offersReplace)

        let with = try #require(DuplicatePresentation.notice(
            check: Self.present, acknowledgement: nil, metadata: metadata, now: Date(),
            tickedExtras: 3))
        #expect(with.offersExtrasOnly)
        // Both ways out are offered: this never takes the re-rip away.
        #expect(with.offersReplace)
        #expect(with.plainLines.contains { $0.contains("just the extras") })
    }

    /// Once pressed, the panel's job is reassurance about the file that is
    /// already there — that is the thing the user was afraid of.
    @Test func onceAcknowledgedTheNoticeSaysTheFilmIsLeftAlone() throws {
        let metadata = try Self.metadata()
        let notice = try #require(DuplicatePresentation.notice(
            check: Self.present, acknowledgement: nil, metadata: metadata, now: Date(),
            extrasOnlyAcknowledgement: Self.ack, tickedExtras: 2))
        #expect(notice.kind == .acknowledged)
        #expect(notice.tone == .success)
        #expect(notice.offersExtrasOnly == false)
        #expect(notice.offersReplace == false)
        #expect(notice.plainHeadline == "OK — only the extras will be brought in.")
        #expect(notice.headline.contains(metadata.fileName))
        #expect(notice.headline.contains("2 extras"))
    }

    /// Replace wins here too, so the panel and `StartGate` can never be
    /// describing different jobs.
    @Test func replaceOutranksTheExtrasOnlyAnswerInTheNoticeToo() throws {
        let metadata = try Self.metadata()
        let notice = try #require(DuplicatePresentation.notice(
            check: Self.present,
            acknowledgement: ReplaceAcknowledgement(movieID: 452, folderPath: Self.entry.folderPath),
            metadata: metadata, now: Date(),
            extrasOnlyAcknowledgement: Self.ack, tickedExtras: 2))
        #expect(notice.kind == .acknowledged)
        #expect(notice.plainHeadline == "OK — the existing copy will be replaced.")
    }

    /// A copy filed under an older or renamed title carries the same
    /// `{tmdb-…}` tag, so it is a perfectly good duplicate to *replace* — and
    /// there is nowhere inside it for an extra to go. Plex reads extras from
    /// the film's own folder, and inventing a second folder beside the one the
    /// user has is exactly what #0186 refuses to do.
    ///
    /// So the offer is withheld and the reason is said instead. A button
    /// certain to refuse is worse than no button.
    @Test func aCopyFiledUnderAnotherNameIsNotOfferedAnExtrasOnlyImport() throws {
        let renamed = LibraryEntry(
            folderName: "Signs (2002) {tmdb-452} old",
            folderPath: "/Volumes/Plex/Movies/Signs (2002) {tmdb-452} old",
            files: [LibraryFile(name: "Signs (2002).mp4")])
        let notice = try #require(DuplicatePresentation.notice(
            check: .done(tmdbID: "452", .present([renamed])),
            acknowledgement: nil, metadata: try Self.metadata(), now: Date(),
            tickedExtras: 2))
        #expect(notice.offersExtrasOnly == false)
        // Replace is still there: the film IS a duplicate, and re-ripping it is
        // still a thing the user may want.
        #expect(notice.offersReplace)
        #expect(notice.plainLines.contains { $0.contains("filed under a different name") })
    }

    /// An answer given for another film does not change the panel either.
    @Test func anAcknowledgementForAnotherFilmLeavesTheOfferStanding() throws {
        let notice = try #require(DuplicatePresentation.notice(
            check: Self.present, acknowledgement: nil, metadata: try Self.metadata(), now: Date(),
            extrasOnlyAcknowledgement: ExtrasOnlyAcknowledgement(movieID: 78, folderPath: Self.entry.folderPath),
            tickedExtras: 2))
        #expect(notice.kind == .present)
        #expect(notice.offersExtrasOnly)
    }
}

// MARK: - JobController's failsafes at the point of harm

/// #0186 — `StartGate` disables the button; these are `start`'s own guards for
/// a request that reaches it anyway, the pattern #0034's disc-identity guard
/// and §7.4's empty-upgrade guard established.
@MainActor
struct ExtrasOnlyStartRefusalTests {

    static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/SIGNS"),
        deviceNode: "disk6",
        discID: "signs-disc-id")

    static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 452, "title": "Signs", "release_date": "2002-08-02", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json),
                             selectionDisc: Self.disc)
    }

    static func controller() -> JobController {
        let controller = JobController(
            runner: { _, _ in .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject)
        let titles = [
            DiscTitle(index: 1, durationSeconds: 6_060, chapterCount: 20, sizeBytes: 0, outputFileName: nil),
            DiscTitle(index: 11, durationSeconds: 3_534, chapterCount: 1, sizeBytes: 0, outputFileName: nil),
        ]
        controller.insertedDisc = Self.disc
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "SIGNS", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1, warnings: []))
        controller.selectTitle(1, settings: AppSettings())
        return controller
    }

    /// Nothing ticked means nothing to do, and a job that encodes nothing would
    /// still open the drive and claim success.
    @Test func anExtrasOnlyRequestWithNothingTickedIsRefused() throws {
        let controller = Self.controller()
        var request = RipRequest(metadata: try Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [])
        request.intent = .extrasOnly
        #expect(controller.start(request: request, settings: AppSettings()) == false)
        #expect(controller.isRunning == false)
        #expect(controller.logLines.contains { $0.contains("Nothing is ticked to bring in") })
    }

    /// A stale tick that no longer resolves against the held scan is dropped by
    /// `ExtrasPlan.make` — which, for an extras-only job, leaves nothing at all,
    /// so this is the same refusal rather than a run with an empty plan.
    @Test func anExtrasOnlyRequestWhoseTicksAllResolveAwayIsRefused() throws {
        let controller = Self.controller()
        var request = RipRequest(metadata: try Self.metadata(), featureTitleIndex: 1,
                                 extraTitleIndices: [99], audioTrackNumbers: [])
        request.intent = .extrasOnly
        #expect(controller.start(request: request, settings: AppSettings()) == false)
    }

    /// An upgrade rewrites the library file; an extras-only import promises not
    /// to touch it. One request claiming both is incoherent, and the safe
    /// reading of an incoherent request is to run neither.
    @Test func aRequestThatIsBothAnUpgradeAndExtrasOnlyIsRefused() throws {
        let controller = Self.controller()
        var request = RipRequest(metadata: try Self.metadata(), featureTitleIndex: 1,
                                 extraTitleIndices: [11], audioTrackNumbers: [])
        request.intent = .extrasOnly
        // A NON-EMPTY upgrade, deliberately. `UpgradePlan.isEmpty` is true with
        // no chapters and no audio, and §7.4's empty-upgrade guard sits above
        // this one — so an empty plan is refused for being empty and never
        // reaches the contradiction this test is about.
        request.upgrade = UpgradePlan(
            filePath: "/Volumes/Plex/Movies/Signs (2002) {tmdb-452}/Signs (2002).mp4",
            audio: [AudioTag(track: 0, language: "eng", title: "English")])
        #expect(controller.start(request: request, settings: AppSettings()) == false)
        #expect(controller.logLines.contains { $0.contains("cannot both upgrade") })
    }

    /// And the ordinary case still starts, carrying the intent through to the
    /// runner — `DVDPipeline` is the only thing that acts on it, so this is the
    /// one hand-off that has to be right.
    @Test func anExtrasOnlyRequestWithATickedExtraStartsAndCarriesItsIntent() async throws {
        var seen: JobIntent?
        var seenExtras: Int?
        let controller = JobController(
            runner: { context, _ in
                seen = context.intent
                seenExtras = context.extras.items.count
                context.phase(.extras)
                return .succeeded(destination: URL(fileURLWithPath: "/Volumes/Plex/Movies/Signs (2002) {tmdb-452}"))
            },
            ejector: PipelineTestSupport.fakeEject)
        let titles = [
            DiscTitle(index: 1, durationSeconds: 6_060, chapterCount: 20, sizeBytes: 0, outputFileName: nil),
            DiscTitle(index: 11, durationSeconds: 3_534, chapterCount: 1, sizeBytes: 0, outputFileName: nil),
        ]
        controller.insertedDisc = Self.disc
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "SIGNS", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1, warnings: []))
        controller.selectTitle(1, settings: AppSettings())

        // #0186: nothing here should write to the user's real menu archive —
        // `start` records the naming choice for a real rip, and the path
        // defaults to the home directory.
        let settings = AppSettings()
        settings.menuArchivePath = ""

        var request = RipRequest(metadata: try Self.metadata(), featureTitleIndex: 1,
                                 extraTitleIndices: [11], audioTrackNumbers: [])
        request.intent = .extrasOnly
        #expect(controller.start(request: request, settings: settings))
        var spins = 0
        while controller.isRunning && spins < 200_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")

        #expect(seen == .extrasOnly)
        #expect(seenExtras == 1)
        // `starting → extras → succeeded`: the phase path an extras-only run
        // takes, and the reason #0186 widened `JobPhase.allowedTransitions`.
        #expect(controller.currentJobState?.phase == .succeeded)
    }
}
