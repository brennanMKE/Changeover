import Foundation
import Testing
@testable import Changeover

/// #0178 — the pipeline half of #0174: a bonus feature that is actually
/// encoded and actually filed into the film's own Plex folder.
///
/// #0174 built the judgement (`BonusFeature`), the convention (`PlexExtra`),
/// the destination (`LibraryDestination.bonusFeature`) and the organizer's
/// narrowed #0031 guard, and said plainly that none of it was wired to the
/// pipeline. Everything it decided was therefore still thrown away: Signs
/// went into the library as one 1:46:25 film, and its 58:54 bonus reel and
/// six named featurettes stayed on the disc.
///
/// These suites cover the seam that closes that gap — `ExtrasPlan.Filing` —
/// and they are the only coverage available, because UI tests are forbidden
/// in this project. So the rules live in plain values and are asserted here.
@Suite struct BonusFeatureFilingTests {

    private static func title(_ index: Int, _ seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil)
    }

    /// Signs as captured (`vol-signs-8224851968`, 2026-10-01): the film, the
    /// 58:54 bonus reel, and the six featurettes its bonus menu names.
    private static var signs: DiscInfo {
        DiscInfo(volumeName: "Signs", driveName: "disk4", titles: [
            title(1, 6385), title(8, 3534), title(9, 375), title(10, 485),
            title(11, 1357), title(12, 516), title(13, 510), title(14, 291),
        ])
    }

    private static let signsMetadata = MovieMetadata(title: "Signs", year: "2002", tmdbID: "452")
    private static let roots = LibraryRoots(mediaRoot: "/Media")

    private static func resolved(_ item: ExtrasPlan.Item) -> LibraryPaths.Resolved {
        LibraryPaths.resolve(item.destination, metadata: signsMetadata,
                             roots: roots, sourceExtension: "mp4")
    }

    // MARK: - The path a named extra now takes

    /// The whole point of the ticket, in one assertion: the disc said what
    /// title 9 is, so title 9 goes beside the film where Plex will show it as
    /// part of the film.
    @Test func anamedExtraIsFiledInsideTheFilmsOwnFolder() throws {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [9], disc: Self.signs,
                                   labels: [9: "looking for Signs"])
        let item = try #require(plan.items.first)

        #expect(item.filing == .bonusFeature(kind: .behindTheScenes, label: "looking for Signs"))
        #expect(item.destination == .bonusFeature(titleIndex: 9, kind: .behindTheScenes,
                                                  label: "looking for Signs"))
        #expect(Self.resolved(item).file ==
                "/Media/Movies/Signs (2002) {tmdb-452}/Behind The Scenes/looking for Signs.mp4")
        #expect(plan.bonusFeatureCount == 1)
    }

    /// The 58:54 reel `BonusFeature.candidates` nominates and #0173 refuses
    /// as a second film — the title this ticket exists for.
    @Test func thebonusReelLandsBesideTheFilmToo() throws {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [8], disc: Self.signs,
                                   labels: [8: "The Making of Signs"])
        let item = try #require(plan.items.first)
        #expect(item.durationSeconds == 3534, "the duration comes off the scan, not the label")
        #expect(Self.resolved(item).file ==
                "/Media/Movies/Signs (2002) {tmdb-452}/Behind The Scenes/The Making of Signs.mp4")
    }

    /// #0031 is unchanged for everything the disc did not name: no label, no
    /// name to show a person, so `Clips` — exactly where it went before.
    @Test func anunnamedExtraStillGoesToClips() throws {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [9], disc: Self.signs)
        let item = try #require(plan.items.first)
        #expect(item.filing == .clip)
        #expect(item.destination == .extra(titleIndex: 9))
        #expect(Self.resolved(item).folder == "/Media/Clips/Signs (2002) {tmdb-452}")
        #expect(plan.bonusFeatureCount == 0)
    }

    /// A label that sanitises to nothing is not a label. `".."` leaves no
    /// name at all, and a nameless file in a Plex extras folder is worse than
    /// the same file in `Clips` — Plex would show the film an unexplained
    /// object with nothing to call it.
    @Test func alabelThatSanitisesAwayFallsBackToAClip() throws {
        for empty in ["..", "", "   ", "-", "/"] {
            let plan = ExtrasPlan.make(featureIndex: 1, requested: [9], disc: Self.signs,
                                       labels: [9: empty])
            let item = try #require(plan.items.first)
            #expect(item.filing == .clip, "“\(empty)” is not a name")
        }
    }

    /// A label is disc text about to become a path component (#0010). It may
    /// be filed beside the film, but it may not climb out of the extras
    /// folder to get there.
    @Test func alabelCannotEscapeTheExtrasFolder() throws {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [9], disc: Self.signs,
                                   labels: [9: "../../../etc/passwd"])
        let item = try #require(plan.items.first)
        let file = Self.resolved(item).file
        #expect(file.hasPrefix("/Media/Movies/Signs (2002) {tmdb-452}/"))
        #expect(!file.contains(".."))
        // And whichever extras folder it lands in is one Plex reads as
        // extras rather than as a film — the organizer's own guard.
        let leaf = (Self.resolved(item).folder as NSString).lastPathComponent
        #expect(PlexExtra.isRecognisedFolder(leaf))
    }

    // MARK: - #0028: a label is believed only about a title the scan confirms

    /// The labels are a dictionary keyed by title index, and the index is
    /// looked up only after it has been checked against the scan. So a label
    /// cannot pull a title into the plan…
    @Test func alabelNeverAddsATitleTheScanDoesNotHave() {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [99], disc: Self.signs,
                                   labels: [99: "the making of nothing"])
        #expect(plan.items.isEmpty, "title 99 is not on this disc, label or no label")
    }

    /// …and cannot slide onto a neighbouring one. Requesting title 9 with a
    /// label for title 10 leaves title 9 unnamed, not named "building Signs"
    /// — the wrong name would put the wrong video in the film's own folder
    /// under a name a person would trust.
    @Test func alabelForAnotherTitleNeverAttachesToThisOne() throws {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [9], disc: Self.signs,
                                   labels: [10: "building Signs"])
        let item = try #require(plan.items.first)
        #expect(item.titleIndex == 9)
        #expect(item.filing == .clip)
    }

    /// The feature is dropped before any label is read, so a disc that names
    /// its own film cannot file that film as its own extra — a whole feature
    /// hidden inside its own folder is the #0034 data-loss shape.
    @Test func thefeatureIsNeverFiledAsItsOwnExtra() {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [1, 9], disc: Self.signs,
                                   labels: [1: "Signs", 9: "looking for Signs"])
        #expect(plan.items.map(\.titleIndex) == [9])
    }

    /// Everything the plan already guaranteed still holds with labels in
    /// hand: dedupe, sort, and durations off the scan.
    @Test func thesixFeaturettesResolveInDiscOrderWithTheirOwnNames() {
        let labels = [9: "looking for Signs", 10: "building Signs",
                      11: "making Signs: a commentary", 12: "the effects of Signs",
                      13: "last voices: the music of Signs", 14: "full circle"]
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [14, 9, 11, 9, 10, 13, 12],
                                   disc: Self.signs, labels: labels)

        #expect(plan.items.map(\.titleIndex) == [9, 10, 11, 12, 13, 14])
        #expect(plan.bonusFeatureCount == 6)
        #expect(plan.items.compactMap(\.label) == [
            "looking for Signs", "building Signs", "making Signs: a commentary",
            "the effects of Signs", "last voices: the music of Signs", "full circle",
        ])
        // The colon is Finder's separator and never reaches a path (#0010).
        let commentary = plan.items.first { $0.titleIndex == 11 }!
        #expect(Self.resolved(commentary).file ==
                "/Media/Movies/Signs (2002) {tmdb-452}/Behind The Scenes/making Signs- a commentary.mp4")
    }

    // MARK: - Where the labels come from

    /// #0174's measured path, now producing the map `make` consumes: the
    /// runtimes the bonus menu printed, bound one to one to scanned titles.
    @Test func thelabelMapComesOffTheDiscsOwnMenu() {
        let menu = [
            "play all",
            "looking for Signs (6:11)",
            "building Signs (8:02)",
            "making Signs: a commentary",
            "by M. Night Shyamalan (22:33)",
            "the effects of Signs (8:31)",
            "last voices: the music›",
            "of Signs (8:26)",
            "full circle (4:48)",
        ]
        let titles = Self.signs.titles.filter { $0.index >= 9 }
        let labels = ExtrasPlan.labels(printedOn: menu, titles: titles)

        #expect(labels.keys.sorted() == [9, 10, 11, 12, 13, 14])
        #expect(labels[9] == "looking for Signs")
        #expect(labels[14] == "full circle")

        // End to end: the menu names them, the plan files them, each in the
        // subfolder its own name earns.
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [9, 12], disc: Self.signs,
                                   labels: labels)
        #expect(plan.items.map { Self.resolved($0).folder } == [
            "/Media/Movies/Signs (2002) {tmdb-452}/Behind The Scenes",
            "/Media/Movies/Signs (2002) {tmdb-452}/Featurettes",
        ])
    }

    /// A menu that prints no runtimes names nothing, and the job runs exactly
    /// as it did before this ticket.
    @Test func amenuWithNoPrintedRuntimesNamesNothing() {
        let labels = ExtrasPlan.labels(printedOn: ["play all", "special features", "set up"],
                                       titles: Self.signs.titles)
        #expect(labels.isEmpty)
    }

    /// The Confirm step used to promise every extra would be "filed outside
    /// the Plex library". That sentence survives unchanged for an all-clip
    /// plan — still the common case — and stops being told when it is false.
    @Test func theconfirmStepStopsPromisingEveryExtraIsFiledOutsidePlex() {
        let clipsOnly = ExtrasPlan.make(featureIndex: 1, requested: [9, 10], disc: Self.signs)
        #expect(DiscTitleFormatting.extrasSummaryWording(clipsOnly).detail?
            .hasSuffix("filed outside the Plex library") == true)

        let mixed = ExtrasPlan.make(featureIndex: 1, requested: [9, 10], disc: Self.signs,
                                    labels: [9: "looking for Signs"])
        let detail = DiscTitleFormatting.extrasSummaryWording(mixed).detail
        // #0182 dropped "by the disc": a bonus feature the user named files
        // the same way and did not come off a menu.
        #expect(detail?.contains("1 named, filed with the movie as extras") == true)
        #expect(detail?.contains("the other 1 filed outside the Plex library") == true)
        // The running total itself is label-independent, so nothing the user
        // was already reading moves.
        #expect(DiscTitleFormatting.extrasSummaryWording(mixed).plain
                == DiscTitleFormatting.extrasSummaryWording(clipsOnly).plain)
    }

    /// #0175's interrogation is the other label source. Only what the disc
    /// corroborated counts, and a *film* is never one of them: filing a
    /// feature as another film's extra would bury it.
    @Test func aninterrogationContributesOnlyCorroboratedNonFilms() {
        var understanding = DiscInterrogation.Understanding()
        understanding.films = [.init(question: .films, titleIndex: 1, label: "Signs")]
        understanding.bonusFeatures = [
            .init(question: .bonusFeature, titleIndex: 8, label: "The Making of Signs", offBySeconds: 4),
        ]
        understanding.extras = [
            .init(question: .extras, titleIndex: 9, label: "looking for Signs", offBySeconds: 4),
        ]
        understanding.unverified = [.init(question: .extras, label: "DREAMSCAPE")]

        let labels = ExtrasPlan.labels(from: understanding)
        #expect(labels == [8: "The Making of Signs", 9: "looking for Signs"])
        #expect(labels[1] == nil, "a film is imported as a film, never as its own extra")
        #expect(!labels.values.contains("DREAMSCAPE"),
                "an uncorroborated name is the one thing #0175 exists to keep out")
    }
}

// MARK: - The same thing against a real filesystem

/// #0178 end to end through `DVDPipeline.run()`, driven against
/// `Fixtures/stub-HandBrakeCLI.sh` the same way `ExtrasPipelineTests` drives
/// the `Clips` path — no disc, no real HandBrakeCLI, no Plex.
@Suite(.serialized)
struct BonusFeaturePipelineTests {

    // MARK: - Helpers (same shapes as ExtrasPipelineTests)

    private static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BonusFeaturePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func copyStub(into dir: URL) throws -> String {
        let name = "stub-HandBrakeCLI.sh"
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        try "EXIT_DIR_INPUT=0".write(toFile: dest.path + ".conf", atomically: true, encoding: .utf8)
        return dest.path
    }

    private static func makeFakeDisc(in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent("FAKE_DISC")
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("VIDEO_TS"),
                                                withIntermediateDirectories: true)
        return disc
    }

    private static func files(directlyIn dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private static func jobDirectories(under dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("job-") }
    }

    /// Title 2 is the named bonus feature; title 3 is an unnamed clip. Both
    /// run through the one extras loop — that is the design claim this suite
    /// exists to pin.
    private static let items: [ExtrasPlan.Item] = [
        ExtrasPlan.Item(titleIndex: 2, durationSeconds: 300, frameRate: nil,
                        interlaceDetected: nil,
                        filing: .bonusFeature(kind: .behindTheScenes, label: "looking for Signs")),
        ExtrasPlan.Item(titleIndex: 3, durationSeconds: 400, frameRate: nil,
                        interlaceDetected: nil),
    ]

    /// #0037: the stub writes a text placeholder, not a real `.mp4`, so stand
    /// in for `AVURLAsset`. Keyed off the `" - tNN.mp4"` suffix `DVDPipeline`
    /// still names every extra's *working* file with — #0178 deliberately
    /// left the working name index-based, and this is what proves it.
    private static let measurer: @Sendable (URL) async throws -> Int = { url in
        for item in Self.items
        where url.lastPathComponent.hasSuffix(" - t\(String(format: "%02d", item.titleIndex)).mp4") {
            return item.durationSeconds
        }
        return 0
    }

    private static func pipeline(
        root: URL,
        settings: AppSettings,
        items: [ExtrasPlan.Item],
        metadata: MovieMetadata,
        log: @escaping @MainActor (String) -> Void
    ) throws -> DVDPipeline {
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault,
                                       fallbackAudio: .sourceDefault, filter: .none),
            extras:   ExtrasPlan(items: items),
            log:      log,
            measureDuration: measurer
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        return pipeline
    }

    // MARK: - A bonus feature really lands in the film's folder

    @Test func abonusFeatureLandsInThePlexExtrasSubfolderAndAClipStillGoesToClips() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = try Self.copyStub(into: root)

        var logged: [String] = []
        let metadata = try Self.metadata()
        let pipeline = try Self.pipeline(root: root, settings: settings, items: Self.items,
                                         metadata: metadata, log: { logged.append($0) })

        let outcome = await pipeline.run()
        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }

        let movieFolder = URL(fileURLWithPath: settings.plexMoviesPath)
            .appendingPathComponent(metadata.folderName)

        // The film, and one extras subfolder — nothing else, and in
        // particular no stray video beside the feature for Plex to scan as a
        // second film.
        #expect(try Self.files(directlyIn: movieFolder) == ["Behind The Scenes", metadata.fileName])
        // The bonus feature, under the name the disc printed.
        #expect(try Self.files(directlyIn: movieFolder.appendingPathComponent("Behind The Scenes"))
                == ["looking for Signs.mp4"])
        // `Movies/` itself still holds exactly one folder: the film's.
        #expect(try FileManager.default.contentsOfDirectory(atPath: settings.plexMoviesPath)
                == [metadata.folderName])
        // The unnamed clip is untouched by this ticket.
        #expect(try Self.files(directlyIn: URL(fileURLWithPath: settings.clipsPath)
                                   .appendingPathComponent(metadata.folderName))
                == ["\(metadata.baseName) - t03.mp4"])

        #expect(logged.contains { $0.contains("“looking for Signs” → ") })
        #expect(logged.contains { $0.hasPrefix("✓ Extras: 2 of 2") && $0.contains("beside the film") })
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
    }

    // MARK: - A bonus feature whose move fails never fails the job

    /// `extras → succeeded` is a legal edge (#0041) and #0031's rule is that
    /// a failed extra is logged, deleted and forgotten. #0178 must not have
    /// quietly bought a new way to lose a finished film: the feature is
    /// already in Plex by the time the loop runs, so a bonus feature that
    /// cannot be filed changes nothing about the outcome.
    ///
    /// The failure is arranged the bluntest honest way — a plain **file**
    /// sitting where the `Behind The Scenes` folder needs to be, so
    /// `createDirectory` cannot succeed.
    @Test func abonusFeatureThatCannotBeFiledStillLeavesTheJobSucceeded() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = try Self.copyStub(into: root)

        let metadata = try Self.metadata()
        let movieFolder = URL(fileURLWithPath: settings.plexMoviesPath)
            .appendingPathComponent(metadata.folderName)
        try FileManager.default.createDirectory(at: movieFolder, withIntermediateDirectories: true)
        try "not a folder".write(to: movieFolder.appendingPathComponent("Behind The Scenes"),
                                 atomically: true, encoding: .utf8)

        var logged: [String] = []
        let pipeline = try Self.pipeline(root: root, settings: settings, items: Self.items,
                                         metadata: metadata, log: { logged.append($0) })

        let outcome = await pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("a bonus feature that could not be filed must not fail the job, got \(outcome)")
            return
        }
        // The film is in Plex, where it was before the extras loop ran.
        #expect(destination == movieFolder.appendingPathComponent(metadata.fileName))
        #expect(FileManager.default.fileExists(atPath: destination.path))

        // The blocking file is still a file — nothing clobbered it, and no
        // video was written beside the feature.
        #expect(try Self.files(directlyIn: movieFolder) == ["Behind The Scenes", metadata.fileName])
        let blocked = movieFolder.appendingPathComponent("Behind The Scenes")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: blocked.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)

        // The other extra still went where it was going.
        #expect(try Self.files(directlyIn: URL(fileURLWithPath: settings.clipsPath)
                                   .appendingPathComponent(metadata.folderName))
                == ["\(metadata.baseName) - t03.mp4"])

        // Logged, deleted, counted — and nothing left in the working folder,
        // because an extra's source is the disc, not the working copy (#0031).
        #expect(logged.contains { $0.contains("Extra title 2 failed to move into") })
        #expect(logged.contains { $0.hasPrefix("✓ Extras: 1 of 2") })
        #expect(!logged.contains { $0.contains("Could not remove the partial extra") })
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
    }
}

/// #0180 — the model's names reach the pipeline, as a fallback behind the
/// disc's own printed ones.
///
/// `ExtrasPlan.labels(from:)` was written in #0178 for exactly this and called
/// from nowhere. That is the shape that left the whole OCR rung dead for a day
/// in #0171: a well-tested function with no reachable caller is
/// indistinguishable from a working feature.
@Suite struct ModelExtraLabelsReachThePlanTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.33)
    }

    private static func understanding(
        extras: [(Int, String)] = [], bonus: [(Int, String)] = []
    ) -> DiscInterrogation.Understanding {
        var u = DiscInterrogation.Understanding()
        u.extras = extras.map {
            DiscInterrogation.Finding(question: .extras, titleIndex: $0.0, label: $0.1)
        }
        u.bonusFeatures = bonus.map {
            DiscInterrogation.Finding(question: .bonusFeature, titleIndex: $0.0, label: $0.1)
        }
        return u
    }

    /// A corroborated extra the model named becomes a label.
    @Test func acorroboratedModelExtraBecomesALabel() {
        let labels = ExtrasPlan.labels(from: Self.understanding(extras: [(9, "The Making Of")]))
        #expect(labels[9] == "The Making Of")
    }

    /// A film is never filed as another film's extra — the #0034 data-loss
    /// shape.
    @Test func afilmFindingNeverBecomesAnExtraLabel() {
        var u = Self.understanding(extras: [(9, "a featurette")])
        u.films = [DiscInterrogation.Finding(question: .films, titleIndex: 1, label: "Signs")]
        let labels = ExtrasPlan.labels(from: u)
        #expect(labels[1] == nil)
        #expect(labels[9] == "a featurette")
    }

    /// An unverified claim carries no name anywhere.
    @Test func anUnverifiedClaimNeverBecomesALabel() {
        var u = Self.understanding()
        u.unverified = [DiscInterrogation.Claim(question: .extras, label: "DREAMSCAPE")]
        #expect(ExtrasPlan.labels(from: u).isEmpty)
    }

    /// And a named extra files beside the film rather than in Clips.
    @Test func amodelNamedExtraFilesAsABonusFeature() {
        let disc = DiscInfo(volumeName: "Signs", driveName: "d", titles: [
            Self.title(1, seconds: 6385), Self.title(9, seconds: 375),
        ])
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [9], disc: disc,
                                   labels: [9: "The Making Of"])
        let item = plan.items.first
        #expect(item?.isBonusFeature == true)
        if case .bonusFeature(let kind, let label) = item?.filing {
            #expect(kind == .behindTheScenes)
            #expect(label == "The Making Of")
        } else {
            Issue.record("a named extra must file beside the film")
        }
    }

    /// The disc's own printed page outranks the model. Two independent
    /// readings agreeing beats one reading checked against the clock.
    @Test func aprintedNameIsNotOverwrittenByAModelName() {
        // `labels(printedOn:)` wins for title 9; the model only fills title 10.
        let titles = [Self.title(9, seconds: 375), Self.title(10, seconds: 485)]
        let printed = ExtrasPlan.labels(
            printedOn: ["looking for Signs (6:11)"], titles: titles)
        #expect(printed[9] == "looking for Signs")
        #expect(printed[10] == nil, "nothing printed a time for this one")

        var merged = printed
        for (index, label) in [9: "WRONG", 10: "building Signs"] where merged[index] == nil {
            merged[index] = label
        }
        #expect(merged[9] == "looking for Signs", "the printed name stands")
        #expect(merged[10] == "building Signs", "and the model fills the gap")
    }
}
