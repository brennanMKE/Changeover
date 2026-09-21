import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// One disc's menu read, end to end: run the helper, render a still per menu,
/// read the stills with Vision, and derive tiers 1 and 2
/// (`docs/menu-intelligence.md` §1).
///
/// **It runs after the scan, never beside it** — one reader on a USB 2.0
/// drive — and nothing in the app waits for it. Every failure returns a
/// `MenuUnavailable`, which is a caption; the rip is byte-identical to what
/// it is today whether this succeeds, fails, times out, or never runs because
/// no helper is installed.
nonisolated enum MenuReader {

    /// Where the helper writes and the stills land.
    ///
    /// The system temp directory, not the Plex volume's working area: this
    /// can hold up to §1.2's 64 MB of menu video per disc, none of it is
    /// wanted once the text has been read, and nothing in `WorkingFiles`'
    /// sweep is shaped to clean it up. `read` removes it when it is done, and
    /// the OS removes it if the app dies first.
    static func workDirectory(discIdentity: String, root: String = NSTemporaryDirectory()) -> String {
        let safe = discIdentity.isEmpty
            ? "disc"
            : discIdentity.replacingOccurrences(of: "/", with: "-")
        let base = (root as NSString).appendingPathComponent("changeover-menus")
        return (base as NSString).appendingPathComponent(safe)
    }

    /// Why a disc with menus produced no stills. `ffmpeg` is the route proven
    /// on the capture host; without it the AVFoundation fallback may or may
    /// not open an MPEG-2 program stream, and the honest caption when it does
    /// not is the one that names the formula.
    static func noStillsReason(ffmpegInstalled: Bool) -> MenuUnavailable {
        ffmpegInstalled
            ? .failed("no menu still could be rendered from this disc")
            : .librariesMissing(["ffmpeg"])
    }

    /// The paths the read needs, captured on MainActor by the caller and
    /// passed in as plain values (`CLAUDE.md`'s MainActor-to-`nonisolated`
    /// rule).
    nonisolated struct Tools: Equatable, Sendable {
        var menudumpPath: String
        var ffmpegPath: String
        var workDirectory: String
        /// Where the disc's text products are kept, or `nil` to keep nothing.
        /// Empty means the same as `nil`, so an unset Settings field disables
        /// collection rather than writing to the filesystem root.
        var archiveRoot: String?
        /// The archive's directory name for this disc.
        var archiveSlug: String

        init(
            menudumpPath: String,
            ffmpegPath: String,
            workDirectory: String,
            archiveRoot: String? = nil,
            archiveSlug: String = "disc"
        ) {
            self.menudumpPath = menudumpPath
            self.ffmpegPath = ffmpegPath
            self.workDirectory = workDirectory
            self.archiveRoot = (archiveRoot?.isEmpty == true) ? nil : archiveRoot
            self.archiveSlug = archiveSlug
        }
    }

    /// Read the disc in the drive.
    ///
    /// - Parameters:
    ///   - featureChapterCount: the settled feature title's chapter count, so
    ///     the names can be checked against it and refused on any mismatch.
    ///   - scanTitles: the titles the scan found, so a button pointing
    ///     somewhere HandBrake does not go is never captioned.
    @concurrent
    static func read(
        discPath: String,
        tools: Tools,
        featureChapterCount: Int?,
        scanTitles: Set<Int>,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> MenuState {
        let structureResult = await MenuHelper.dump(
            path: tools.menudumpPath,
            discPath: discPath,
            outDirectory: tools.workDirectory,
            log: log
        )
        let structure: MenuStructure
        switch structureResult {
        case .failure(let reason):
            return .unavailable(reason)
        case .success(let value):
            structure = value
        }

        if let missing = structure.helper?.missing, !missing.isEmpty {
            // Tier 1 is still real — buttons, targets, chapter counts — so
            // what is derivable is derived and the caption names the formula
            // that would add the rest.
            let partial = MenuIntelligence.derive(
                structure: structure,
                ocr: nil,
                featureChapterCount: featureChapterCount,
                scanTitles: scanTitles
            )
            Task { @MainActor in log("▶ Disc menus: \(MenuUnavailable.librariesMissing(missing).caption)") }
            return partial.isEmpty ? .unavailable(.librariesMissing(missing)) : .ready(partial)
        }

        let ocr = await readStills(structure: structure, tools: tools, log: log)
        let menu = MenuIntelligence.derive(
            structure: structure,
            ocr: ocr,
            featureChapterCount: featureChapterCount,
            scanTitles: scanTitles
        )
        // Keep the text, drop the video. `structure.json` is read back off
        // disk rather than re-encoded so the archive holds the helper's own
        // bytes, which is what the corpus tests and `Tools/menu-derive` parse.
        if let root = tools.archiveRoot {
            let structurePath = (tools.workDirectory as NSString).appendingPathComponent("structure.json")
            let written = MenuArchive.write(
                root: root,
                slug: tools.archiveSlug,
                structureJSON: try? Data(contentsOf: URL(fileURLWithPath: structurePath)),
                ocr: ocr,
                derived: MenuDerived.make(structure: structure, intelligence: menu),
                stillIDs: ocr?.stills.map(\.id) ?? [],
                workDirectory: tools.workDirectory
            )
            if let written {
                Task { @MainActor in log("▶ Disc menus: archived to \(written)") }
            }
        }
        // Up to 64 MB of decrypted menu video, and nothing that cannot be read
        // again off the same disc.
        try? FileManager.default.removeItem(atPath: tools.workDirectory)

        guard !menu.isEmpty else {
            guard ocr == nil else { return .unavailable(.noMenus) }
            return .unavailable(noStillsReason(
                ffmpegInstalled: FileManager.default.isExecutableFile(atPath: tools.ffmpegPath)
            ))
        }
        Task { @MainActor in
            log("▶ Disc menus: \(menu.menuCount) menus, \(menu.stillCount) stills read, \(menu.chapterNames.count) chapter names")
        }
        return .ready(menu)
    }

    // MARK: - Stills and OCR

    /// One still per menu PGC the helper wrote a cell for, read with Vision.
    /// `nil` when nothing could be rendered at all.
    @concurrent
    static func readStills(
        structure: MenuStructure,
        tools: Tools,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> MenuOCRDocument? {
#if canImport(Vision) && canImport(CoreGraphics)
        let frame = structure.frame ?? MenuStructure.Frame(width: 720, height: 480, standard: nil)
        let settings = MenuOCR.Settings()
        var stills: [MenuOCRDocument.Still] = []

        // Every page, not every menu. A scene index is one PGC whose pages are
        // its cells, and the helper writes one cell file per page, named after
        // the still: `<menu-id>.vob` for cell 0, `<menu-id>-cell2.vob` upward.
        // Reading only `menu.id` here is what made the shipped build see page
        // one of Oppenheimer's five and conclude the disc offered four
        // chapters — which `ChapterNames.markers` then discarded for naming
        // fewer than half the film's, so the disc looked like one that prints
        // no names at all.
        for still in structure.menus.flatMap(\.stillIDs) {
            let cell = cellPath(for: still, in: tools.workDirectory)
            guard FileManager.default.fileExists(atPath: cell) else { continue }
            guard let image = await self.still(
                cell: cell,
                output: (tools.workDirectory as NSString).appendingPathComponent("\(still).jpg"),
                ffmpegPath: tools.ffmpegPath
            ) else { continue }
            guard let observations = try? MenuOCR.observations(
                in: image,
                frameWidth: frame.width,
                frameHeight: frame.height,
                settings: settings
            ) else { continue }
            stills.append(MenuOCRDocument.Still(
                id: still,
                frame: frame,
                note: nil,
                observations: observations
            ))
        }

        guard !stills.isEmpty else {
            Task { @MainActor in log("▶ Disc menus: no still could be rendered — chapter names and hints are unavailable") }
            return nil
        }
        return MenuOCRDocument(
            format: "changeover-menu-ocr/1",
            engine: MenuOCRDocument.Engine(
                framework: "Vision",
                api: "VNRecognizeTextRequest",
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                level: "accurate",
                languageCorrection: settings.usesLanguageCorrection,
                languages: settings.languages,
                customWords: settings.customWords.count,
                upscale: settings.upscale,
                minimumTextHeightFraction: settings.minimumTextHeightFraction
            ),
            note: "read in-app after the scan",
            stills: stills
        )
#else
        return nil
#endif
    }

    /// The helper's own naming: `cells/<still-id>.vob`, where the still id is
    /// the menu's id for cell 0 and `<menu-id>-cell<n>` for the pages after
    /// it. One name serves the cell, the still and the OCR record, so a
    /// caption can never be attributed to a page it was not printed on.
    static func cellPath(for stillID: String, in workDirectory: String) -> String {
        let cells = (workDirectory as NSString).appendingPathComponent("cells")
        return (cells as NSString).appendingPathComponent("\(stillID).vob")
    }

    /// `ffmpeg`'s vector for "one I-frame out of this cell" — the same one
    /// `Tools/capture-disc.sh` uses, so the archive and the app render the
    /// same frame. Pure, so it is pinned by a test rather than by a disc.
    static func ffmpegArguments(cell: String, output: String) -> [String] {
        [
            "-v", "error",
            "-i", cell,
            "-vf", "select=eq(pict_type\\,I)",
            "-frames:v", "1",
            // JPEG at a high quality, because this frame is both what Vision
            // reads now and what the archive keeps for re-reading later, and
            // the archive is specified as JPEG (§8.2). `-q:v 2` is visually
            // lossless on a menu's flat artwork and about a tenth the size of
            // the PNG this used to write.
            "-q:v", "2",
            "-y", output,
        ]
    }

#if canImport(CoreGraphics)
    /// One still, by whichever route this Mac can manage: `ffmpeg` when it is
    /// installed (the route proven on the capture host), else AVFoundation on
    /// the decrypted cell. Neither is required; without both there are no
    /// stills, no chapter names and no hints — and an unchanged rip.
    @concurrent
    static func still(cell: String, output: String, ffmpegPath: String) async -> CGImage? {
        if FileManager.default.isExecutableFile(atPath: ffmpegPath) {
            let result = await ProcessRunner.run(
                executablePath: ffmpegPath,
                arguments: ffmpegArguments(cell: cell, output: output),
                watchdog: .absolute(30),
                onLine: { _ in }
            )
            if case .success(let termination) = result, termination.status == 0,
               let image = loadImage(atPath: output) {
                return image
            }
        }
        return decodeWithAVFoundation(cell: cell)
    }

    static func loadImage(atPath path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The no-tool route: AVFoundation on the decrypted MPEG-2 program
    /// stream. Whether it opens a `.vob` at all is the one open question of
    /// §2.4, and it is written as a *fallback* precisely because the answer
    /// is unverified — a `nil` here costs the stills, nothing else.
    static func decodeWithAVFoundation(cell: String) -> CGImage? {
#if canImport(AVFoundation)
        let asset = AVURLAsset(url: URL(fileURLWithPath: cell))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
#else
        return nil
#endif
    }
#endif
}
