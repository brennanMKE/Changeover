import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0197 — the read verbs: `assets`, `library` and `search`.
///
/// Every decision in them is a pure function over plain values, and this file is
/// why. UI tests are forbidden in this project and the XPC transport is verified
/// by hand, so a seam that can only be exercised with a disc in a drive is a seam
/// with no coverage at all. What is asserted here is the part that can be wrong
/// quietly: the shape of the manifest, where the cache lands, what an untagged
/// language decodes to, and what a disc with no readable menus produces.
@Suite struct BridgeAssetCacheTests {

    // MARK: - Helpers

    private static func scratch() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("bridge-assets-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static func audioStream(
        _ index: Int,
        languageCode: String? = "eng",
        displayName: String? = "DD Surround 5.1 English",
        bitrate: String? = "448000",
        channelCount: Int? = 6,
        flags: Int = 0,
        variant: String? = nil
    ) -> DiscStream {
        DiscStream(
            index: index, kind: .audio, codecId: "A_AC3",
            languageCode: languageCode, languageName: languageCode == nil ? nil : "English",
            displayName: displayName, bitrate: bitrate, variant: variant,
            channelCount: channelCount, flags: flags
        )
    }

    private static func subtitleStream(
        _ index: Int,
        languageCode: String? = "eng",
        variant: String? = nil,
        flags: Int = 0
    ) -> DiscStream {
        DiscStream(
            index: index, kind: .subtitle, codecId: "S_VOBSUB",
            languageCode: languageCode, languageName: languageCode == nil ? nil : "English",
            variant: variant, flags: flags
        )
    }

    private static func title(
        _ index: Int,
        seconds: Int = 6_000,
        chapters: Int = 20,
        streams: [DiscStream] = [],
        role: DiscTitle.Role = .ignore
    ) -> DiscTitle {
        DiscTitle(
            index: index, durationSeconds: seconds, chapterCount: chapters,
            sizeBytes: 1, outputFileName: nil, streams: streams,
            suggestedRole: role, displayAspect: 1.78
        )
    }

    private static func ocrDocument() -> MenuOCRDocument {
        MenuOCRDocument(
            format: "changeover-menu-ocr/1",
            engine: MenuOCRDocument.Engine(
                framework: "Vision", api: "RecognizeTextRequest", os: "test",
                level: "accurate", languageCorrection: false, languages: ["en"],
                customWords: 0, upscale: 1, minimumTextHeightFraction: 0.02
            ),
            note: nil,
            stills: [
                MenuOCRDocument.Still(
                    id: "vtsm-01-lu1-pgc2", frame: nil, note: nil,
                    observations: [
                        TextObservation(text: "PLAY MOVIE", confidence: 1,
                                        rect: PixelRect(minX: 1, minY: 1, maxX: 2, maxY: 2)),
                        TextObservation(text: "SCENE SELECTION", confidence: 1,
                                        rect: PixelRect(minX: 1, minY: 3, maxX: 2, maxY: 4)),
                    ]
                ),
            ]
        )
    }

    /// An archive directory of the shape `MenuArchive` leaves behind: the
    /// helper's own `structure.json`, a `derived.json`, and a still per page.
    private static func seedArchive(root: String, slug: String) throws -> String {
        let menus = MenuArchive.menusDirectory(root: root, slug: slug)
        let stills = (menus as NSString).appendingPathComponent("stills")
        try FileManager.default.createDirectory(atPath: stills, withIntermediateDirectories: true)
        func write(_ text: String, _ relative: String) throws {
            try Data(text.utf8).write(
                to: URL(fileURLWithPath: (menus as NSString).appendingPathComponent(relative))
            )
        }
        try write(#"{"format":"changeover-menu-structure/1"}"#, "structure.json")
        try write(#"{"format":"changeover-menu-derived/1"}"#, "derived.json")
        try write("not really a jpeg", "stills/vtsm-01-lu1-pgc2.jpg")
        try write("ignore me", "stills/notes.txt")
        return MenuArchive.discDirectory(root: root, slug: slug)
    }

    private static func plan(
        directory: String,
        archiveDirectory: String?,
        scanned: Bool = true,
        ocr: MenuOCRDocument? = BridgeAssetCacheTests.ocrDocument(),
        menuState: MenuState = .ready(MenuIntelligence(menuCount: 2, stillCount: 1))
    ) -> BridgeAssetCache.Plan {
        let disc = DiscInfo(
            volumeName: "GARDEN_STATE", driveName: "disk6",
            titles: [
                title(1, seconds: 6_120, streams: [audioStream(1)], role: .mainFeature),
                title(8, seconds: 1_357, streams: [audioStream(1, languageCode: nil)]),
            ]
        )
        let scan = scanned
            ? BridgeAssetCache.scanSummary(
                .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: 1, warnings: []))
            )
            : nil
        let pages = DiscEvidence.make(
            volumeName: "GARDEN_STATE", ocr: ocr, disc: disc, mainFeatureIndex: 1
        ).menuPages
        let menus = BridgeAssetCache.menuSummary(menuState, menuPages: pages)
        return BridgeAssetCache.Plan(
            directory: directory,
            archiveDirectory: archiveDirectory,
            disc: AssetDisc(
                label: "GARDEN_STATE", discID: "8a2b1c",
                insertionID: UUID().uuidString,
                mountPath: "/Volumes/GARDEN_STATE", slug: "8a2b1c"
            ),
            scan: scan,
            discInfo: scanned ? disc : nil,
            mainFeatureIndex: scanned ? 1 : nil,
            ocr: ocr,
            menuPages: pages,
            menus: menus,
            titles: scanned ? BridgeAssetCache.titles(of: disc, mainFeatureIndex: 1) : [],
            notes: BridgeAssetCache.notes(
                scan: scan, menus: menus,
                archiveEnabled: archiveDirectory != nil, hasOCR: ocr != nil
            )
        )
    }

    // MARK: - Where the cache lands

    /// Under `$TMPDIR`, in one container, keyed on the disc — so macOS can clear
    /// it and so two agents asking about one disc get one directory rather than
    /// two.
    @Test func theCacheIsOneContainerUnderTheTempDirectoryKeyedOnTheDisc() {
        let directory = AssetCache.directory(slug: "8a2b1c", root: "/tmp/x")
        #expect(directory == "/tmp/x/changeover-assets/8a2b1c")
        #expect(AssetCache.path(AssetCache.Name.ocr, in: directory)
                == "/tmp/x/changeover-assets/8a2b1c/menus/ocr.json")
    }

    /// The same slug the app's own archive uses, so a cache and an archive copy
    /// of one pressing can be correlated without re-deriving the rule: the disc
    /// id when there is one, the volume label when there is not.
    @Test func theSlugIsTheArchivesOwn() {
        #expect(BridgeAssetCache.directory(discID: "8a2b1c", volumeName: "GARDEN_STATE", root: "/t")
                == "/t/changeover-assets/8a2b1c")
        #expect(BridgeAssetCache.directory(discID: nil, volumeName: "GARDEN_STATE", root: "/t")
                == "/t/changeover-assets/garden_state")
    }

    /// A volume label is attacker-shaped input in the sense that matters: it
    /// comes off the disc, and this path is about to be handed to `removeItem`.
    @Test func aLabelCannotWalkOutOfTheContainer() {
        #expect(BridgeAssetCache.directory(discID: nil, volumeName: "../../etc", root: "/t")
                == "/t/changeover-assets/etc")
        #expect(BridgeAssetCache.directory(discID: nil, volumeName: "BLOODSPORT/2", root: "/t")
                == "/t/changeover-assets/bloodsport-2")
        #expect(BridgeAssetCache.directory(discID: nil, volumeName: "", root: "/t")
                == "/t/changeover-assets/disc")
    }

    // MARK: - The manifest

    /// The manifest names every file that is there, with a path that resolves,
    /// and says which of them came from the app's memory and which were copied
    /// out of the archive.
    @Test func theManifestNamesEveryArtifactWithAPathThatResolves() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let archive = try Self.seedArchive(root: root, slug: "8a2b1c")
        let directory = AssetCache.directory(slug: "8a2b1c", root: root)

        let manifest = await BridgeAssetCache.write(
            Self.plan(directory: directory, archiveDirectory: archive)
        )

        #expect(manifest.format == "changeover-assets/1")
        #expect(manifest.path == directory)
        #expect(manifest.archivePath == archive)

        for name in [
            AssetCache.Name.scan,
            AssetCache.Name.tracks,
            AssetCache.Name.ocr,
            AssetCache.Name.menuLines,
            AssetCache.Name.structure,
            AssetCache.Name.derived,
            "\(AssetCache.Name.stills)/vtsm-01-lu1-pgc2.jpg",
        ] {
            let artifact = try #require(manifest.artifact(named: name), "\(name) should be listed")
            #expect(FileManager.default.fileExists(atPath: artifact.path), "\(name) should exist")
            #expect(artifact.path == AssetCache.path(name, in: directory))
            #expect((artifact.byteCount ?? 0) > 0)
        }

        // Written from live state versus copied out of the archive, because when
        // the two disagree it matters which is which: the archive's copy is as old
        // as the menu read, the app's is current by construction.
        #expect(manifest.artifact(named: AssetCache.Name.scan)?.source == AssetArtifact.Source.app)
        #expect(manifest.artifact(named: AssetCache.Name.structure)?.source
                == AssetArtifact.Source.archive)

        // Anything in the archive's stills folder that is not a still stays there.
        #expect(manifest.artifacts.allSatisfy { !$0.name.hasSuffix("notes.txt") })

        // The manifest does not list itself — `manifestPath` is how it is found,
        // and a self-listing manifest invites a consumer to read it twice.
        #expect(manifest.artifact(named: AssetCache.Name.manifest) == nil)
        #expect(manifest.manifestPath == AssetCache.path(AssetCache.Name.manifest, in: directory))

        // And the file on disk is the same document that came back over XPC, so
        // `assets --json` and `manifest.json` cannot disagree.
        let onDisk = try JSONDecoder().decode(
            AssetManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifest.manifestPath))
        )
        #expect(onDisk == manifest)
    }

    /// Rebuilt, not merged. The manifest promises that nothing it does not name is
    /// in the directory, and that promise breaks the first time an artifact stops
    /// being copyable and a stale one is left sitting beside the new ones.
    @Test func asecondCallRebuildsRatherThanMerging() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = AssetCache.directory(slug: "8a2b1c", root: root)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stale = AssetCache.path("stale.json", in: directory)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: stale))

        _ = await BridgeAssetCache.write(Self.plan(directory: directory, archiveDirectory: nil))

        #expect(!FileManager.default.fileExists(atPath: stale))
    }

    /// The menu lines come through `DiscEvidence`, which is the one place in the
    /// app that turns OCR observations into lines — pages kept apart, because a
    /// menu's structure is evidence and flattening it destroys the strongest
    /// signal a two-film disc gives.
    @Test func themenuLinesAreTheOnesTheAppReasonsOver() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = AssetCache.directory(slug: "8a2b1c", root: root)

        let manifest = await BridgeAssetCache.write(
            Self.plan(directory: directory, archiveDirectory: nil)
        )
        let artifact = try #require(manifest.artifact(named: AssetCache.Name.menuLines))
        let lines = try JSONDecoder().decode(
            AssetMenuLines.self, from: Data(contentsOf: URL(fileURLWithPath: artifact.path))
        )
        #expect(lines.pages == [["PLAY MOVIE", "SCENE SELECTION"]])
        #expect(manifest.menus.menuLineCount == 2)
    }

    // MARK: - A disc with no menus

    /// `structure.json did not decode` is common, and it is not an error.
    ///
    /// Plenty of DVDs carry menu tables libdvdcss cannot read. An agent that sees
    /// no `structure.json` and no explanation has to guess between "this disc has
    /// no menus" and "the app is broken", so the manifest says which — and says it
    /// in the app's own caption, which ends "The rip is unaffected."
    @Test func adiscWithNoReadableMenusIsAnotherNotAFailure() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = AssetCache.directory(slug: "8a2b1c", root: root)

        let manifest = await BridgeAssetCache.write(
            Self.plan(
                directory: directory,
                archiveDirectory: nil,
                ocr: nil,
                menuState: .unavailable(.failed("structure.json did not decode"))
            )
        )

        #expect(manifest.menus.state == AssetMenuSummary.State.unavailable)
        #expect(manifest.menus.reason?.contains("structure.json did not decode") == true)
        #expect(manifest.menus.reason?.contains("The rip is unaffected.") == true)
        #expect(manifest.artifact(named: AssetCache.Name.structure) == nil)
        #expect(manifest.artifact(named: AssetCache.Name.ocr) == nil)
        #expect(manifest.artifact(named: AssetCache.Name.menuLines) == nil)
        #expect(manifest.notes.contains { $0.contains("it is not an error") })

        // The scan and the tracks are still there: a disc with no menus is still a
        // disc with titles, and that is most of what an agent came for.
        #expect(manifest.artifact(named: AssetCache.Name.scan) != nil)
        #expect(manifest.artifact(named: AssetCache.Name.tracks) != nil)
    }

    /// With archiving switched off, the artifacts that only exist in the archive
    /// cannot be copied — and the manifest says so rather than looking like a
    /// disc with no menus.
    @Test func switchedOffArchivingIsNamedAsTheReasonTheStructureIsMissing() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = AssetCache.directory(slug: "8a2b1c", root: root)

        let manifest = await BridgeAssetCache.write(
            Self.plan(directory: directory, archiveDirectory: nil)
        )
        #expect(manifest.artifact(named: AssetCache.Name.structure) == nil)
        #expect(manifest.notes.contains { $0.contains("disc archive is switched off") })
    }

    /// Before the scan lands there is no scan and no track detail, and the
    /// manifest says to come back rather than reporting a disc with no titles.
    @Test func anunscannedDiscIsReportedAsUnscanned() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = AssetCache.directory(slug: "8a2b1c", root: root)

        let manifest = await BridgeAssetCache.write(
            Self.plan(directory: directory, archiveDirectory: nil, scanned: false)
        )
        #expect(manifest.scan == nil)
        #expect(manifest.titles.isEmpty)
        #expect(manifest.artifact(named: AssetCache.Name.scan) == nil)
        #expect(manifest.artifact(named: AssetCache.Name.tracks) == nil)
        #expect(manifest.notes.contains { $0.contains("has not been scanned yet") })
    }

    // MARK: - Tracks

    /// #0027 — an untagged audio track stays untagged all the way onto the wire.
    ///
    /// `null`, never `""` and never `"eng"`. Defaulting an untagged stream to
    /// English is what produces a silent MP4, and an agent reading this manifest
    /// is choosing tracks, so it has to be able to tell "no language tag" from
    /// "English".
    @Test func anuntaggedAudioTrackIsNullOnTheWireAndNeverEnglish() {
        let untagged = Self.title(
            9,
            streams: [
                Self.audioStream(1, languageCode: nil, displayName: "DD Surround 5.1"),
                Self.audioStream(2, languageCode: nil, displayName: "DD Surround 5.1"),
            ]
        )
        let tracks = BridgeAssetCache.tracks(for: untagged, isMainFeature: false)

        #expect(tracks.audioIsAllUntagged)
        #expect(tracks.audio.allSatisfy { $0.languageCode == nil })
        #expect(!tracks.audio.contains { $0.languageCode == "eng" })
        // Two identical-looking untagged tracks are two tracks, because that is
        // exactly what a foreign original plus an English dub looks like.
        #expect(tracks.audio.map(\.trackNumber) == [1, 2])
        #expect(tracks.audio.allSatisfy { $0.duplicateTrackNumbers.isEmpty })

        // And the JSON really does carry `null` — an omitted key and a key set to
        // the empty string are both answers a consumer could misread.
        let encoded = try? JSONEncoder().encode(tracks.audio[0])
        let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!json.contains("\"languageCode\":\"\""))
        #expect(!json.contains("eng"))
    }

    /// A duplicate tagged offering is reported once, with the merged track number
    /// kept rather than dropped — an agent shown twelve tracks where the app
    /// offers six would reasonably conclude the app was hiding something.
    @Test func duplicateTaggedTracksMergeAndKeepTheirNumbers() {
        let doubled = Self.title(
            1,
            streams: [Self.audioStream(1), Self.audioStream(3)]
        )
        let tracks = BridgeAssetCache.tracks(for: doubled, isMainFeature: true)
        #expect(tracks.audio.count == 1)
        #expect(tracks.audio[0].trackNumber == 1)
        #expect(tracks.audio[0].duplicateTrackNumbers == [3])
        #expect(tracks.audio[0].languageCode == "eng")
        #expect(tracks.audio[0].bitrate == "448000")
        #expect(tracks.audio[0].channelCount == 6)
        #expect(tracks.isMainFeature)
    }

    /// #0033 — HandBrake's aspect-ratio variants are one logical subtitle track,
    /// and the variant axis stays visible rather than being folded into the
    /// language.
    @Test func subtitleVariantsCollapseIntoOneGroupThatStillNamesItsVariants() {
        let fargo = Self.title(
            1,
            streams: [
                Self.subtitleStream(1, variant: "Wide Screen"),
                Self.subtitleStream(2, variant: "Letterbox"),
            ]
        )
        let tracks = BridgeAssetCache.tracks(for: fargo, isMainFeature: true)
        #expect(tracks.subtitles.count == 1)
        #expect(tracks.subtitles[0].trackNumbers == [1, 2])
        #expect(tracks.subtitles[0].trackNumber == 1, "the Wide Screen member is the one an encode takes")
        #expect(Set(tracks.subtitles[0].variants) == ["Wide Screen", "Letterbox"])
        #expect(tracks.subtitles[0].languageCode == "eng")
    }

    /// Against real HandBrake output rather than only synthetic streams, because
    /// the shapes that break this are the ones nobody would think to invent.
    @Test func thetrackProjectionSurvivesARealScan() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/dragon-tattoo/scan.json")
            .path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let disc = HandBrakeScanParser.parse(text, volumeName: "DRAGON", driveName: "disk6").disc

        let titles = BridgeAssetCache.titles(of: disc, mainFeatureIndex: 1)
        #expect(titles.count == disc.titles.count)
        #expect(titles.map(\.index) == disc.titles.map(\.index).sorted())
        #expect(titles.first { $0.index == 1 }?.isMainFeature == true)

        // Never the empty string: a consumer branching on `languageCode == nil`
        // would read `""` as a tagged track in a language it does not know.
        #expect(titles.allSatisfy { $0.audio.allSatisfy { $0.languageCode != "" } })
        #expect(titles.allSatisfy { $0.subtitles.allSatisfy { $0.languageCode != "" } })

        // The grouped counts are the picker's counts, not the raw stream counts.
        for title in disc.titles {
            let projected = try #require(titles.first { $0.index == title.index })
            #expect(projected.audio.count == AudioTrackOptions.options(for: title).count)
            #expect(projected.subtitles.count == SubtitleGrouping.groups(for: title).count)
        }
    }

    // MARK: - Summaries

    @Test func afailedScanIsSummarisedInTheAppsOwnWords() {
        let summary = BridgeAssetCache.scanSummary(.failed(.jsonMissing))
        #expect(summary?.state == ScanStatus.State.failed)
        #expect(summary?.failure == BridgeStatusReader.describe(DiscScanner.Failure.jsonMissing))
    }

    @Test func anidleScanIsNoSummaryRatherThanAnEmptyOne() {
        #expect(BridgeAssetCache.scanSummary(.idle) == nil)
    }
}

// MARK: - library

/// #0197 — `library <tmdb-id>`.
@Suite struct BridgeLibraryReaderTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil)
    }

    private static func extra(_ folder: String, _ name: String, seconds: Int?) -> LibraryExtraFile {
        LibraryExtraFile(
            folderName: folder,
            file: LibraryFile(name: name, sizeBytes: 10, durationSeconds: seconds)
        )
    }

    private static let entry = LibraryEntry(
        folderName: "Garden State (2004) {tmdb-401}",
        folderPath: "/Volumes/Media/Media/Movies/Garden State (2004) {tmdb-401}",
        files: [LibraryFile(name: "Garden State (2004) {edition-Director's Cut}.mp4", sizeBytes: 2_000)],
        extras: [
            extra("Behind The Scenes", "making of.mp4", seconds: 1_357),
            extra("Trailers", "teaser.mp4", seconds: nil),
        ]
    )

    /// A library that could not be read is never reported as a library without
    /// the film in it. An agent that collapses the two files a second copy of a
    /// film it already has, the first time the NAS is slow.
    @Test func unreachableIsNeverAbsent() {
        let report = BridgeLibraryReader.report(
            tmdbID: "401",
            moviesPath: "/Volumes/Media/Media/Movies",
            lookup: .unreachable(reason: "The Plex library did not answer in 15 s."),
            discTitles: [Self.title(8, seconds: 1_357)]
        )
        #expect(report.state == LibraryReport.State.unreachable)
        #expect(report.state != LibraryReport.State.absent)
        #expect(report.reason?.contains("did not answer") == true)
        #expect(report.folders.isEmpty)
        // No verdicts either: with no folder there are no extras to judge, and a
        // list of "not held" would read as a judgement that had been made.
        #expect(report.discTitles == nil)
    }

    @Test func absentNamesTheTagItLookedFor() {
        let report = BridgeLibraryReader.report(
            tmdbID: "401", moviesPath: "/m", lookup: .absent, discTitles: []
        )
        #expect(report.state == LibraryReport.State.absent)
        #expect(report.tag == "{tmdb-401}")
        #expect(report.discTitles == nil)
    }

    /// The film's folder, its files, and the extras with their runtimes — plus
    /// the `{edition-…}` tag pulled out, because that tag is the only thing that
    /// tells two cuts of one film apart inside one folder.
    @Test func afiledFilmReportsItsFolderItsFilesAndItsExtras() throws {
        let report = BridgeLibraryReader.report(
            tmdbID: "401",
            moviesPath: "/Volumes/Media/Media/Movies",
            lookup: .present([Self.entry]),
            discTitles: []
        )
        #expect(report.state == LibraryReport.State.filed)
        let folder = try #require(report.folders.first)
        #expect(folder.folderName == "Garden State (2004) {tmdb-401}")
        #expect(folder.files.first?.edition == "Director's Cut")
        #expect(folder.extras.count == 2)
        #expect(folder.extras.first?.folderName == "Behind The Scenes")
        #expect(folder.extras.first?.durationSeconds == 1_357)
        #expect(folder.extras.first?.durationText == "22:37")
        // A runtime that could not be read is `nil`, and that is neither presence
        // nor absence.
        #expect(folder.extras.last?.durationSeconds == nil)
    }

    /// By duration, never by filename. The library copy is called `making of.mp4`
    /// and the disc's title is a number; nothing but the runtime connects them.
    @Test func thediscsTitlesAreJudgedByDurationNotByName() throws {
        let report = BridgeLibraryReader.report(
            tmdbID: "401",
            moviesPath: "/m",
            lookup: .present([Self.entry]),
            discTitles: [
                Self.title(1, seconds: 6_120),
                Self.title(8, seconds: 1_360),
                Self.title(9, seconds: 480),
            ]
        )
        let verdicts = try #require(report.discTitles)
        #expect(verdicts.count == 3)

        let held = try #require(verdicts.first { $0.titleIndex == 8 })
        #expect(held.held, "1360s against a 1357s file is inside the 12s tolerance")
        #expect(held.existingFolder == "Behind The Scenes")
        #expect(held.existingName == "making of.mp4")
        #expect(held.summary == "title 8 (22:40) is already in Behind The Scenes/making of.mp4")

        #expect(verdicts.first { $0.titleIndex == 9 }?.held == false)
        // The feature is reported too, and reported as not filed: a report that
        // silently omitted it would leave an agent wondering whether it had been
        // considered at all.
        #expect(verdicts.first { $0.titleIndex == 1 }?.held == false)
        #expect(verdicts.first { $0.titleIndex == 1 }?.durationSeconds == 6_120)
    }

    /// A tolerance this wide and no wider. Extras on a real disc are minutes
    /// apart — Signs' run 4:51 to 22:37 — so the slack is for a container
    /// rounding to whole seconds, not for guessing.
    @Test func atitleWellOutsideTheToleranceIsNotHeld() throws {
        let report = BridgeLibraryReader.report(
            tmdbID: "401", moviesPath: "/m",
            lookup: .present([Self.entry]),
            discTitles: [Self.title(8, seconds: 1_357 + LibraryExtras.toleranceSeconds + 1)]
        )
        #expect(try #require(report.discTitles).first?.held == false)
    }
}

// MARK: - The command line

/// #0197 — parsing the three read verbs.
///
/// In its own suite rather than appended to `CLIParseTests`: the parser is one
/// pure function and these are the cases the read verbs add to it, most of which
/// are about an argument no other verb takes.
@Suite struct ReadVerbParseTests {

    private func command(_ arguments: String...) throws -> CLICommand {
        try CLIParse.parse(arguments).get().command
    }

    private func failure(_ arguments: String...) throws -> CLIErrorPayload {
        switch CLIParse.parse(arguments) {
        case .failure(let payload): return payload
        case .success(let invocation): throw ParseDidNotFail(command: invocation.command.name)
        }
    }

    private struct ParseDidNotFail: Error { let command: String }

    @Test func assetsTakesNoArgumentAndHasItsOwnDefaultTimeout() throws {
        #expect(try command("assets") == .assets(.init(noLaunch: false, timeout: 30)))
        #expect(try command("assets", "--no-launch", "--timeout", "5")
                == .assets(.init(noLaunch: true, timeout: 5)))
        #expect(try failure("assets", "401").code == BridgeExitCode.usage)
    }

    @Test func libraryTakesExactlyOneTMDBID() throws {
        #expect(try command("library", "401") == .library(.init(tmdbID: "401")))
        #expect(try failure("library").code == BridgeExitCode.usage)
        #expect(try failure("library", "401", "402").code == BridgeExitCode.usage)
    }

    /// A tag is accepted and unwrapped. An agent that has just read `folderName`
    /// out of `status` is holding `{tmdb-401}`, and refusing it would be a puzzle
    /// rather than a safeguard.
    @Test func libraryAcceptsTheTagAnAgentAlreadyHas() throws {
        #expect(try command("library", "{tmdb-401}") == .library(.init(tmdbID: "401")))
        #expect(try command("library", "tmdb-401") == .library(.init(tmdbID: "401")))
    }

    /// A title is not an id, and saying so at the point it was typed is better
    /// than forwarding a tag that matches nothing and reporting the film absent.
    @Test func atitleIsRefusedAsATMDBID() throws {
        let payload = try failure("library", "Garden State")
        #expect(payload.code == BridgeExitCode.usage)
        #expect(payload.hint?.contains("search") == true)
    }

    /// `search Garden State` is what a person types and what an agent composing a
    /// command line from a disc label produces.
    @Test func searchJoinsItsWordsSoQuotesAreOptional() throws {
        #expect(try command("search", "Garden", "State") == .search(.init(term: "Garden State")))
        #expect(try command("search", "Garden State") == .search(.init(term: "Garden State")))
        #expect(try failure("search").code == BridgeExitCode.usage)
    }

    /// `--json` has to be total, including on a usage error for these verbs: the
    /// consumer is a program reading one object per line, and a bare stderr line
    /// would desync it.
    @Test func jsonSurvivesAUsageErrorOnTheReadVerbs() throws {
        switch CLIParse.parse(["library", "--json"]) {
        case .failure(let payload):
            #expect(payload.kind == CLIErrorPayload.Kind.usage)
            #expect(CLIErrorPayload.exitCode(for: payload.kind) == BridgeExitCode.usage)
        case .success:
            throw ParseDidNotFail(command: "library")
        }
    }

    /// The three verbs are in the help, and the help is generated from the same
    /// table the tool dispatches on — which is what makes `changeoverctl help`
    /// the authority on what exists rather than the documentation.
    @Test func thereadVerbsAreInTheHelp() {
        let names = HelpText.payload().commands.map(\.name)
        #expect(names.contains("assets"))
        #expect(names.contains("library"))
        #expect(names.contains("search"))
        #expect(HelpText.payload(topic: "assets").commands.count == 1)
        #expect(HelpText.payload(topic: "assets").topic == "assets")
    }

    /// Each read verb's help says in as many words that it only observes, because
    /// an agent reads the help before it reads the commands.
    @Test func eachreadVerbSaysItOnlyObserves() {
        for name in ["assets", "library", "search"] {
            let command = HelpText.payload(topic: name).commands.first
            #expect(command?.discussion.contains("only observes") == true, "\(name)")
        }
    }
}
