import Foundation
import Testing
@testable import Changeover

/// Covers #0186 end to end: `DVDPipeline.run()` with `intent == .extrasOnly`
/// encodes and files the ticked extras into a film the library already holds,
/// and **never touches that film's own file**.
///
/// Driven against `Fixtures/stub-HandBrakeCLI.sh` the way `ExtrasPipelineTests`
/// and `BonusFeaturePipelineTests` are — no disc, no real HandBrakeCLI, no
/// Plex. `ARGV_LOG` is what makes the central claim checkable rather than
/// merely plausible: every invocation of the stub is recorded, so "the feature
/// was never encoded" is an assertion about what actually ran.
@Suite(.serialized)
struct ExtrasOnlyPipelineTests {

    // MARK: - Helpers (same shapes as the two sibling pipeline suites)

    static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 452, "title": "Signs", "release_date": "2002-08-02", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtrasOnlyPipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The stub, with an `ARGV_LOG` so every invocation is recorded.
    static func copyStub(into dir: URL, argvLog: URL, extraConf: [String] = []) throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub-HandBrakeCLI.sh")
        let dest = dir.appendingPathComponent("stub-HandBrakeCLI.sh")
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        let conf = ["EXIT_DIR_INPUT=0", "ARGV_LOG=\(argvLog.path)"] + extraConf
        try conf.joined(separator: "\n").write(toFile: dest.path + ".conf", atomically: true, encoding: .utf8)
        return dest.path
    }

    static func makeFakeDisc(in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent("SIGNS")
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("VIDEO_TS"),
                                                withIntermediateDirectories: true)
        return disc
    }

    static func files(directlyIn dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    static func jobDirectories(under dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("job-") }
    }

    static func argvLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Title 11 is a named bonus feature (Signs' 58-minute reel), title 7 an
    /// unnamed clip — both run through the one shared extras loop, which is
    /// the design claim #0186 inherits from `ExtrasPlan.Filing`.
    static let items: [ExtrasPlan.Item] = [
        ExtrasPlan.Item(titleIndex: 7, durationSeconds: 300, frameRate: nil, interlaceDetected: nil),
        ExtrasPlan.Item(titleIndex: 11, durationSeconds: 3_534, frameRate: nil, interlaceDetected: nil,
                        filing: .bonusFeature(kind: .behindTheScenes, label: "making Signs")),
    ]

    /// #0037: the stub writes a text placeholder, not a real `.mp4`, so stand
    /// in for `AVURLAsset`. Keyed off the `" - tNN.mp4"` suffix `DVDPipeline`
    /// names every extra's *working* file with.
    static let measurer: @Sendable (URL) async throws -> Int = { url in
        for item in Self.items
        where url.lastPathComponent.hasSuffix(" - t\(String(format: "%02d", item.titleIndex)).mp4") {
            return item.durationSeconds
        }
        return 0
    }

    /// The film, already in the library, with contents nothing in this ticket
    /// may change. Returns the file's URL.
    @discardableResult
    static func seedExistingFilm(settings: AppSettings, metadata: MovieMetadata) throws -> URL {
        let folder = URL(fileURLWithPath: LibraryPaths.filmFolder(
            metadata: metadata, roots: settings.libraryRoots))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(metadata.fileName)
        try Self.sentinel.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Deliberately not something the stub could ever produce, so a
    /// replacement is unmistakable.
    static let sentinel = "ripped in 2019, from a disc that is now in a box in the loft"

    /// An extras-only pipeline over `disc`. The caller overrides `eject` and
    /// `reportPhase` after construction where it cares about them, the way the
    /// sibling pipeline suites do.
    static func pipeline(
        root: URL,
        settings: AppSettings,
        metadata: MovieMetadata,
        items: [ExtrasPlan.Item],
        log: @escaping @MainActor (String) -> Void,
        disc: URL
    ) -> DVDPipeline {
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     disc,
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault,
                                       fallbackAudio: .sourceDefault, filter: .none),
            extras:   ExtrasPlan(items: items),
            intent:   .extrasOnly,
            log:      log,
            measureDuration: Self.measurer
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        return pipeline
    }

    // MARK: - The one thing that must never happen

    /// **The existing film file is never a destination in an extras-only run.**
    ///
    /// The film is seeded with text no HandBrake stub could ever write, the
    /// extras are filed beside it, and the film is read back byte for byte. The
    /// `ARGV_LOG` then proves *why* it survived rather than merely that it did:
    /// the stub was invoked twice, once per extra, and never for the feature —
    /// no `--title 1`, no `--main-feature`. There is no `.feature` destination
    /// in this run to move anything to (`JobIntent.featureDestination`).
    ///
    /// Falsify by making `JobIntent.extrasOnly.featureDestination` return
    /// `.feature`: the sentinel is replaced by the stub's placeholder and this
    /// fails on the first assertion.
    @Test func anExtrasOnlyRunFilesTheExtrasAndLeavesTheExistingFilmByteForByte() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let argvLog = root.appendingPathComponent("argv.log")
        settings.handbrakePath = try Self.copyStub(into: root, argvLog: argvLog)

        let metadata = try Self.metadata()
        let film = try Self.seedExistingFilm(settings: settings, metadata: metadata)
        let filmModified = try FileManager.default.attributesOfItem(atPath: film.path)[.modificationDate] as? Date

        var logged: [String] = []
        var phases: [JobPhase] = []
        var ejected: [URL] = []
        let disc = try Self.makeFakeDisc(in: root)
        var pipeline = Self.pipeline(
            root: root, settings: settings, metadata: metadata, items: Self.items,
            log: { logged.append($0) }, disc: disc)
        pipeline.reportPhase = { phases.append($0) }
        pipeline.eject = { url in ejected.append(url); return .ejected }

        let outcome = await pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }

        // 1. The film is exactly as it was.
        #expect(try String(contentsOf: film, encoding: .utf8) == Self.sentinel)
        #expect(try FileManager.default.attributesOfItem(atPath: film.path)[.modificationDate] as? Date
                == filmModified)

        // 2. The extras landed where #0174/#0178 put them.
        let folder = URL(fileURLWithPath: LibraryPaths.filmFolder(metadata: metadata, roots: settings.libraryRoots))
        #expect(try Self.files(directlyIn: folder) == ["Behind The Scenes", "Other", metadata.fileName])
        #expect(try Self.files(directlyIn: folder.appendingPathComponent("Behind The Scenes"))
                == ["making Signs.mp4"])
        #expect(try Self.files(directlyIn: folder.appendingPathComponent("Other"))
                == ["Bonus Feature - t07.mp4"],
                "#0192 — the extra nothing named is filed with the film too")
        // And `Movies/` still holds exactly the one folder it held before.
        #expect(try FileManager.default.contentsOfDirectory(atPath: settings.plexMoviesPath)
                == [metadata.folderName])

        // 3. The feature was never encoded. Two invocations, one per extra.
        let invocations = Self.argvLines(argvLog)
        #expect(invocations.count == 2, "\(invocations)")
        #expect(invocations.allSatisfy { !$0.contains("--main-feature") })
        #expect(invocations.contains { $0.contains("--title 7") })
        #expect(invocations.contains { $0.contains("--title 11") })
        #expect(invocations.allSatisfy { !$0.contains("--title 1 ") })

        // 4. The destination is the film's own folder — honest, and a folder
        //    "Reveal in Finder" opens on something.
        #expect(destination == folder)

        // 5. `starting → extras → succeeded`: no `encoding`, no `organizing`,
        //    because nothing was encoded for the film and nothing was moved
        //    for it. This is the edge #0186 added to `JobPhase`.
        #expect(phases == [.extras])

        // 6. The disc comes out, like any other finished job (#0005).
        #expect(ejected == [disc])

        // 7. And the working folder is disposed, leaving nothing for the next
        //    job's sweep to report.
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)

        #expect(logged.contains { $0.hasPrefix("✓ Extras only:") })
        #expect(logged.contains { $0.contains("The film's own file was not touched.") })
        // Nothing in the log claims a feature encode happened.
        #expect(logged.allSatisfy { !$0.hasPrefix("✓ Encode complete") })
        #expect(logged.allSatisfy { !$0.hasPrefix("▶ Deinterlace") })
    }

    // MARK: - No folder, no run

    /// Requirement: refuse with a clear reason rather than inventing a folder.
    ///
    /// The library has the film under a different id, or not at all. Creating
    /// `Movies/Signs (2002) {tmdb-452}/` here would leave a film folder holding
    /// featurettes and no film — and HandBrake would have run for an hour first.
    @Test func anExtrasOnlyRunRefusesWhenTheFilmsFolderIsNotInTheLibrary() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let argvLog = root.appendingPathComponent("argv.log")
        settings.handbrakePath = try Self.copyStub(into: root, argvLog: argvLog)

        let metadata = try Self.metadata()
        // `Movies/` exists (preflight needs it) but holds a *different* film:
        // the same title filed under another id, which is the realistic shape
        // of this failure.
        try FileManager.default.createDirectory(
            atPath: (settings.plexMoviesPath as NSString).appendingPathComponent("Signs (2002) {tmdb-999}"),
            withIntermediateDirectories: true)

        var logged: [String] = []
        var ejected: [URL] = []
        var pipeline = Self.pipeline(
            root: root, settings: settings, metadata: metadata, items: Self.items,
            log: { logged.append($0) }, disc: try Self.makeFakeDisc(in: root))
        pipeline.eject = { url in ejected.append(url); return .ejected }

        let outcome = await pipeline.run()

        let failure = try #require(outcome.failure)
        #expect(failure.stage == .preflight)
        guard case .unknown(let detail) = failure.reason else {
            Issue.record("expected .unknown, got \(failure.reason)")
            return
        }
        #expect(detail.contains(LibraryPaths.filmFolder(metadata: metadata, roots: settings.libraryRoots)))

        // Nothing was invented: the folder is still absent and the library is
        // exactly as it was.
        #expect(try FileManager.default.contentsOfDirectory(atPath: settings.plexMoviesPath)
                == ["Signs (2002) {tmdb-999}"])
        #expect(FileManager.default.fileExists(
            atPath: (settings.plexMediaRoot as NSString).appendingPathComponent("Clips")) == false,
            "#0192 — nothing creates a Clips tree any more")
        // Nothing was encoded — the refusal is before HandBrake, not after an
        // hour of it. (The only stub invocation is preflight's `--help`, which
        // the stub answers before the argv log.)
        #expect(Self.argvLines(argvLog).isEmpty)
        // And no working folder was created, so there is nothing for the next
        // job's sweep to report.
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
        // A failed job never ejects (#0005 only ejects on success), so the disc
        // stays in for a second attempt.
        #expect(ejected.isEmpty)
        #expect(logged.contains { $0.contains("Import the film itself first") })
    }

    /// The same refusal when the path is taken by a *file* — `createDirectory`
    /// would have failed later, after the extras were already encoded.
    @Test func aFileWhereTheFilmsFolderShouldBeIsAlsoARefusal() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let argvLog = root.appendingPathComponent("argv.log")
        settings.handbrakePath = try Self.copyStub(into: root, argvLog: argvLog)

        let metadata = try Self.metadata()
        try FileManager.default.createDirectory(atPath: settings.plexMoviesPath,
                                                withIntermediateDirectories: true)
        try "not a folder".write(
            toFile: LibraryPaths.filmFolder(metadata: metadata, roots: settings.libraryRoots),
            atomically: true, encoding: .utf8)

        let pipeline = Self.pipeline(
            root: root, settings: settings, metadata: metadata, items: Self.items,
            log: { _ in }, disc: try Self.makeFakeDisc(in: root))

        let outcome = await pipeline.run()
        #expect(outcome.failure?.stage == .preflight)
        #expect(Self.argvLines(argvLog).isEmpty)
    }

    /// Nothing ticked is refused by the pipeline too, not only by the gate and
    /// `JobController.start` — the failsafe at the point of harm.
    @Test func anExtrasOnlyRunWithAnEmptyPlanIsRefused() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = try Self.copyStub(into: root, argvLog: root.appendingPathComponent("argv.log"))

        let metadata = try Self.metadata()
        let film = try Self.seedExistingFilm(settings: settings, metadata: metadata)

        let pipeline = Self.pipeline(
            root: root, settings: settings, metadata: metadata, items: [],
            log: { _ in }, disc: try Self.makeFakeDisc(in: root))

        let outcome = await pipeline.run()
        #expect(outcome.failure?.stage == .preflight)
        #expect(try String(contentsOf: film, encoding: .utf8) == Self.sentinel)
    }

    // MARK: - A failed extra still leaves the job succeeded

    /// #0031's rule and #0041's `extras → succeeded` edge, unchanged for an
    /// extras-only run — the loop is the same one copy of the code.
    ///
    /// The film the job files beside is one the library already had, which is
    /// why `ExtrasOnlyImport.readiness` refuses before any of this starts: "a
    /// failed extra never changes the outcome" is only acceptable while
    /// something *is* in Plex to be the outcome.
    @Test func aFailedExtraStillLeavesAnExtrasOnlyJobSucceeded() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let argvLog = root.appendingPathComponent("argv.log")
        // Title 7 fails after writing a partial; title 11 succeeds.
        settings.handbrakePath = try Self.copyStub(
            into: root, argvLog: argvLog,
            extraConf: ["FAIL_TITLES=7", "FAIL_EXIT=2", "FAIL_WRITE_PARTIAL=1"])

        let metadata = try Self.metadata()
        let film = try Self.seedExistingFilm(settings: settings, metadata: metadata)

        var logged: [String] = []
        let pipeline = Self.pipeline(
            root: root, settings: settings, metadata: metadata, items: Self.items,
            log: { logged.append($0) }, disc: try Self.makeFakeDisc(in: root))

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        // The one that worked is filed; the one that failed left nothing.
        let folder = URL(fileURLWithPath: LibraryPaths.filmFolder(metadata: metadata, roots: settings.libraryRoots))
        #expect(try Self.files(directlyIn: folder.appendingPathComponent("Behind The Scenes"))
                == ["making Signs.mp4"])
        #expect(try Self.files(directlyIn: URL(fileURLWithPath: settings.plexMoviesPath)
            .appendingPathComponent(metadata.folderName).appendingPathComponent("Other")
                                   .appendingPathComponent(metadata.folderName)).isEmpty)
        // The film is still untouched, which is the part that matters most when
        // something has gone wrong.
        #expect(try String(contentsOf: film, encoding: .utf8) == Self.sentinel)
        #expect(logged.contains { $0.hasPrefix("✓ Extras: 1 of 2") })
        // The partial is deleted, so the job directory is disposed clean.
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
    }

    // MARK: - The ordinary run is unchanged

    /// The same disc, the same extras, `intent == .film`: the feature IS
    /// encoded and IS filed, over the copy that was already there. The
    /// difference between the two runs is one value, and this is the other half
    /// of that claim — without it, "nothing was overwritten" could be true
    /// because nothing ever is.
    @Test func anOrdinaryRunStillEncodesTheFeatureAndReplacesTheExistingFile() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let argvLog = root.appendingPathComponent("argv.log")
        settings.handbrakePath = try Self.copyStub(into: root, argvLog: argvLog)

        let metadata = try Self.metadata()
        let film = try Self.seedExistingFilm(settings: settings, metadata: metadata)

        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault,
                                       fallbackAudio: .sourceDefault, filter: .none),
            extras:   ExtrasPlan(items: Self.items),
            log:      { _ in },
            measureDuration: Self.measurer
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()
        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        // Three invocations now: the feature plus both extras.
        #expect(Self.argvLines(argvLog).count == 3)
        #expect(Self.argvLines(argvLog).contains { $0.contains("--title 1 ") })
        // And the library file really was replaced — which is #0012's
        // behaviour, on purpose, and exactly what an extras-only run avoids.
        #expect(try String(contentsOf: film, encoding: .utf8) != Self.sentinel)
    }
}
