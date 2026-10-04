import ChangeoverBridge
import Foundation

/// #0197 — assembles the temp cache `changeoverctl assets` prints the path to.
///
/// **Almost nothing here extracts anything.** The scan, the OCR document, the
/// menu structure, the derived menu intelligence and the stills all already
/// exist: `MenuArchive` writes four of them beside each disc and the app holds
/// the other two in memory. What was missing was a single place that says where
/// they all are, in one document, with the per-title track detail beside them —
/// because an agent handed a directory and no manifest has to encode this app's
/// layout in its own code, and then the layout can never change.
///
/// Split the way `BridgeStatusReader` is split, for the same reason. The
/// **projection** half is pure functions from the app's own plain values —
/// a `DiscTitle`, a `MenuState`, a `ScanState` — to the wire types, so the
/// judgement in them (which streams merge, what an untagged language means, when
/// a missing artifact is a note rather than an error) is testable in
/// `ChangeoverTests` with no disc, no HandBrake and no XPC connection. That is
/// the only coverage available: UI tests are forbidden in this project.
///
/// The **writing** half is one `@concurrent` function that takes a ``Plan`` of
/// plain values and does file I/O. `@concurrent` for the reason `LibraryProbe`
/// and `PlexOrganizer.move` are: copying a dozen JPEGs is blocking work with no
/// `await` of its own, and under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a
/// plain `nonisolated async` function would still run it on the caller's actor —
/// freezing the window while an agent asks a question about the disc.
///
/// Every write is best-effort, in the register `MenuArchive` set: a full disk, a
/// read-only `$TMPDIR`, a still that has gone — all of them mean the manifest
/// carries a note and names one fewer artifact, never that the call fails. An
/// `assets` that refuses to answer because one JPEG would not copy is worse than
/// one that answers and says so.
nonisolated enum BridgeAssetCache {

    // MARK: - The plan

    /// Everything the writer needs, captured on MainActor by the caller and
    /// handed over as plain values — `CLAUDE.md`'s MainActor-to-`nonisolated`
    /// rule, the same shape as `MenuReader.Tools`.
    nonisolated struct Plan: Sendable {
        var directory: String
        /// The app's own durable archive directory for this disc, or `nil` when
        /// archiving is switched off in Settings. `structure.json`, `derived.json`
        /// and the stills can only be copied from here: the menu read deletes its
        /// working directory, so after it finishes the archive is the only copy.
        var archiveDirectory: String?
        var disc: AssetDisc
        var scan: AssetScanSummary?
        /// The scanned disc, re-encoded into the cache as `scan.json` in the same
        /// shape `Tools/capture-disc.sh` and `MenuArchive.writeScan` produce, so
        /// one piece of analysis code reads all three.
        var discInfo: DiscInfo?
        var mainFeatureIndex: Int?
        var ocr: MenuOCRDocument?
        var menuPages: [[String]]
        var menus: AssetMenuSummary
        var titles: [AssetTitleTracks]
        var notes: [String]

        init(
            directory: String,
            archiveDirectory: String? = nil,
            disc: AssetDisc,
            scan: AssetScanSummary? = nil,
            discInfo: DiscInfo? = nil,
            mainFeatureIndex: Int? = nil,
            ocr: MenuOCRDocument? = nil,
            menuPages: [[String]] = [],
            menus: AssetMenuSummary,
            titles: [AssetTitleTracks] = [],
            notes: [String] = []
        ) {
            self.directory = directory
            self.archiveDirectory = archiveDirectory
            self.disc = disc
            self.scan = scan
            self.discInfo = discInfo
            self.mainFeatureIndex = mainFeatureIndex
            self.ocr = ocr
            self.menuPages = menuPages
            self.menus = menus
            self.titles = titles
            self.notes = notes
        }
    }

    // MARK: - Writing

    /// Builds one disc's cache and returns the manifest describing it.
    ///
    /// **Rebuilt from scratch on every call**, old directory removed first. The
    /// manifest promises that every artifact it names is there and that nothing
    /// it does not name is; keeping whatever a previous call left behind would
    /// break the second half of that promise the first time a still stopped being
    /// copyable. Rebuilding also means a call made after the menu read finishes
    /// replaces a thinner cache with a complete one rather than merging two
    /// vintages.
    @concurrent
    static func write(_ plan: Plan, fileManager: FileManager = .default) async -> AssetManifest {
        var notes = plan.notes
        var artifacts: [AssetArtifact] = []

        // A derived path, never a given one — but checked anyway before a
        // recursive delete. `MenuArchive.slug` already refuses `..` and strips
        // separators; this is the second lock on the door, because the one thing
        // this function must never do is remove a directory that is not its own.
        if plan.directory.contains("/\(AssetCache.containerName)/") {
            try? fileManager.removeItem(atPath: plan.directory)
        }

        guard
            (try? fileManager.createDirectory(
                atPath: plan.directory, withIntermediateDirectories: true
            )) != nil
        else {
            return AssetManifest(
                path: plan.directory,
                manifestPath: AssetCache.path(AssetCache.Name.manifest, in: plan.directory),
                disc: plan.disc,
                scan: plan.scan,
                menus: plan.menus,
                titles: plan.titles,
                notes: notes + ["the cache directory could not be created at \(plan.directory)"],
                archivePath: plan.archiveDirectory
            )
        }

        let encoder = MenuArchive.encoder()

        /// Encodes a value into the cache and records it, or notes why not.
        func put<Value: Encodable>(_ value: Value, _ name: String, kind: String) {
            guard let data = try? encoder.encode(value) else {
                notes.append("\(name) could not be encoded")
                return
            }
            let path = AssetCache.path(name, in: plan.directory)
            guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else {
                notes.append("\(name) could not be written")
                return
            }
            artifacts.append(
                AssetArtifact(
                    name: name,
                    path: path,
                    kind: kind,
                    source: AssetArtifact.Source.app,
                    byteCount: Int64(data.count)
                )
            )
        }

        /// Copies one file out of the app's archive, or notes why not.
        func copy(_ name: String, from source: String, kind: String) {
            guard fileManager.fileExists(atPath: source) else { return }
            let path = AssetCache.path(name, in: plan.directory)
            try? fileManager.removeItem(atPath: path)
            guard (try? fileManager.copyItem(atPath: source, toPath: path)) != nil else {
                notes.append("\(name) could not be copied from the disc archive")
                return
            }
            artifacts.append(
                AssetArtifact(
                    name: name,
                    path: path,
                    kind: kind,
                    source: AssetArtifact.Source.archive,
                    byteCount: byteCount(of: path, fileManager: fileManager)
                )
            )
        }

        if let discInfo = plan.discInfo {
            put(
                MenuArchive.ArchivedScan(disc: discInfo, mainFeatureIndex: plan.mainFeatureIndex),
                AssetCache.Name.scan,
                kind: AssetArtifact.Kind.scan
            )
        }
        if !plan.titles.isEmpty {
            put(AssetTracksDocument(titles: plan.titles), AssetCache.Name.tracks, kind: AssetArtifact.Kind.tracks)
        }

        let wantsMenus = plan.ocr != nil || !plan.menuPages.isEmpty || plan.archiveDirectory != nil
        if wantsMenus {
            try? fileManager.createDirectory(
                atPath: AssetCache.path(AssetCache.Name.menus, in: plan.directory),
                withIntermediateDirectories: true
            )
        }
        if let ocr = plan.ocr {
            put(ocr, AssetCache.Name.ocr, kind: AssetArtifact.Kind.ocr)
        }
        if !plan.menuPages.isEmpty {
            put(
                AssetMenuLines(pages: plan.menuPages),
                AssetCache.Name.menuLines,
                kind: AssetArtifact.Kind.menuLines
            )
        }

        if let archive = plan.archiveDirectory {
            let menus = (archive as NSString).appendingPathComponent(AssetCache.Name.menus)
            copy(
                AssetCache.Name.structure,
                from: (menus as NSString).appendingPathComponent("structure.json"),
                kind: AssetArtifact.Kind.structure
            )
            copy(
                AssetCache.Name.derived,
                from: (menus as NSString).appendingPathComponent("derived.json"),
                kind: AssetArtifact.Kind.derived
            )

            let sourceStills = (menus as NSString).appendingPathComponent("stills")
            let names = (try? fileManager.contentsOfDirectory(atPath: sourceStills))?.sorted() ?? []
            if !names.isEmpty {
                try? fileManager.createDirectory(
                    atPath: AssetCache.path(AssetCache.Name.stills, in: plan.directory),
                    withIntermediateDirectories: true
                )
            }
            for name in names where (name as NSString).pathExtension.lowercased() == "jpg" {
                copy(
                    "\(AssetCache.Name.stills)/\(name)",
                    from: (sourceStills as NSString).appendingPathComponent(name),
                    kind: AssetArtifact.Kind.still
                )
            }
        }

        let manifestPath = AssetCache.path(AssetCache.Name.manifest, in: plan.directory)
        let manifest = AssetManifest(
            path: plan.directory,
            manifestPath: manifestPath,
            disc: plan.disc,
            scan: plan.scan,
            menus: plan.menus,
            artifacts: artifacts,
            titles: plan.titles,
            notes: notes,
            archivePath: plan.archiveDirectory
        )
        // Written last, so it can name everything else, and not listed among the
        // artifacts it names — a manifest that lists itself invites a consumer to
        // read it twice. `manifestPath` is how it is found.
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: URL(fileURLWithPath: manifestPath))
        }
        return manifest
    }

    private static func byteCount(of path: String, fileManager: FileManager) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64
    }

    // MARK: - Projection: the disc

    /// The cache directory for one disc, keyed on the same slug the app's own
    /// archive uses.
    static func directory(discID: String?, volumeName: String, root: String = NSTemporaryDirectory()) -> String {
        AssetCache.directory(slug: MenuArchive.slug(discID: discID, volumeName: volumeName), root: root)
    }

    static func disc(_ insertion: DiscInsertion) -> AssetDisc {
        AssetDisc(
            label: insertion.label,
            discID: insertion.discID,
            insertionID: insertion.insertionID.uuidString,
            mountPath: insertion.mountURL.path,
            slug: MenuArchive.slug(discID: insertion.discID, volumeName: insertion.label)
        )
    }

    // MARK: - Projection: the scan

    /// The scan, summarised. `nil` while nothing has been scanned yet, because
    /// "no scan" and "a scan that found nothing" are different and an empty
    /// summary would read like the second.
    static func scanSummary(_ state: ScanState) -> AssetScanSummary? {
        switch state {
        case .idle:
            return nil
        case .scanning:
            return AssetScanSummary(state: ScanStatus.State.scanning)
        case .scanned(let result):
            let feature = result.mainFeatureIndex.flatMap { index in
                result.disc.titles.first { $0.index == index }
            }
            return AssetScanSummary(
                state: ScanStatus.State.scanned,
                titleCount: result.disc.titles.count,
                mainFeatureIndex: result.mainFeatureIndex,
                featureDurationSeconds: feature?.durationSeconds,
                warnings: result.warnings
            )
        case .failed(let failure):
            return AssetScanSummary(
                state: ScanStatus.State.failed,
                // The same sentence `status` gives, through
                // `BridgeStatusReader.describe`, so the CLI never words one
                // failure two ways.
                failure: BridgeStatusReader.describe(failure)
            )
        }
    }

    // MARK: - Projection: the menus

    static func menuSummary(_ state: MenuState, menuPages: [[String]]) -> AssetMenuSummary {
        switch state {
        case .idle:
            return AssetMenuSummary(state: AssetMenuSummary.State.idle)
        case .reading:
            return AssetMenuSummary(state: AssetMenuSummary.State.reading)
        case .ready(let menu):
            return AssetMenuSummary(
                state: AssetMenuSummary.State.ready,
                menuCount: menu.menuCount,
                stillCount: menu.stillCount,
                menuLineCount: menuPages.reduce(0) { $0 + $1.count },
                titleText: menu.titleText?.text
            )
        case .unavailable(let reason):
            // The app's own caption, verbatim. It always ends "The rip is
            // unaffected.", which is the sentence that stops an agent treating a
            // disc with no readable menus as a fault.
            return AssetMenuSummary(
                state: AssetMenuSummary.State.unavailable,
                reason: reason.caption
            )
        }
    }

    /// What is missing from this cache and why, in sentences.
    ///
    /// The one that matters is the no-menus note. `structure.json did not decode`
    /// is common — plenty of DVDs have menu tables libdvdcss cannot read — and an
    /// agent that reads a missing `structure.json` as a failure will go looking
    /// for a bug that is not there. `docs/cli-for-agents.md` says so in as many
    /// words; this is the same statement, delivered where it is needed.
    static func notes(
        scan: AssetScanSummary?,
        menus: AssetMenuSummary,
        archiveEnabled: Bool,
        hasOCR: Bool
    ) -> [String] {
        var notes: [String] = []

        if scan == nil {
            notes.append(
                "the disc has not been scanned yet, so there is no scan.json and no track detail — "
                    + "re-run assets once `status` reports the scan as scanned"
            )
        } else if scan?.state == ScanStatus.State.scanning {
            notes.append("the scan is still running, so scan.json and the track detail are incomplete")
        }

        switch menus.state {
        case AssetMenuSummary.State.reading:
            notes.append("the menu read is still running — re-run assets to pick up its artifacts")
        case AssetMenuSummary.State.unavailable:
            notes.append(
                "there are no menu artifacts for this disc: \(menus.reason ?? "the menu read produced nothing"). "
                    + "This is common and it is not an error — identification falls back to the volume "
                    + "label and the runtimes alone."
            )
        case AssetMenuSummary.State.idle:
            notes.append("the menu read has not started, so there are no menu artifacts yet")
        default:
            if !hasOCR {
                notes.append(
                    "the menus were read for their buttons but no text could be read from them, "
                    + "so there is no ocr.json"
                )
            }
        }

        if !archiveEnabled {
            notes.append(
                "the disc archive is switched off in Settings, so the menu structure, the derived "
                    + "menu intelligence and the stills could not be copied — only what the app "
                    + "still holds in memory is here"
            )
        }
        return notes
    }

    // MARK: - Projection: the tracks

    static func titles(of disc: DiscInfo, mainFeatureIndex: Int?) -> [AssetTitleTracks] {
        disc.titles
            .sorted { $0.index < $1.index }
            .map { tracks(for: $0, isMainFeature: $0.index == mainFeatureIndex) }
    }

    static func tracks(for title: DiscTitle, isMainFeature: Bool) -> AssetTitleTracks {
        AssetTitleTracks(
            index: title.index,
            durationSeconds: title.durationSeconds,
            chapterCount: title.chapterCount,
            displayAspect: title.displayAspect,
            angleCount: title.angleCount,
            suggestedRole: title.suggestedRole.rawValue,
            isMainFeature: isMainFeature,
            audio: audio(for: title),
            subtitles: subtitles(for: title),
            audioIsAllUntagged: AudioTrackOptions.isUntagged(title)
        )
    }

    /// One entry per audio *offering*, through `AudioTrackOptions.options`.
    ///
    /// Deliberately the merged list rather than the raw streams. HandBrake reports
    /// the same offering twice on plenty of discs, and an agent shown twelve
    /// tracks where the app offers six would reasonably conclude the app is
    /// hiding something. The merged-away track numbers are kept in
    /// `duplicateTrackNumbers`, so nothing is actually lost — and untagged streams
    /// are never merged in the first place, because two identical-looking untagged
    /// tracks are exactly what a foreign original plus an English dub looks like.
    static func audio(for title: DiscTitle) -> [AssetAudioTrack] {
        let streams = Dictionary(
            title.streams.filter { $0.kind == .audio }.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return AudioTrackOptions.options(for: title).map { option in
            let stream = streams[option.trackNumber]
            return AssetAudioTrack(
                trackNumber: option.trackNumber,
                duplicateTrackNumbers: option.duplicateTrackNumbers,
                codecID: stream?.codecId,
                // `option.languageCode` and not `stream?.languageCode`: the
                // option's is normalised through `LanguageCode.normalize`, which
                // is what collapses `und`, `mul` and the empty tag to the one
                // answer that matters — untagged. Untagged stays `nil` on the
                // wire and must never be defaulted to English (#0027).
                languageCode: option.languageCode,
                languageName: stream?.languageName,
                displayName: option.displayName,
                variant: stream?.variant,
                channelCount: stream?.channelCount,
                bitrate: stream?.bitrate,
                isCommentary: option.isCommentary,
                isForced: stream?.isForced ?? false,
                isDefault: stream?.isDefault ?? false,
                flags: stream?.flags ?? 0
            )
        }
    }

    /// One entry per logical subtitle track, through `SubtitleGrouping.groups`.
    ///
    /// Same argument as the audio: HandBrake reports a stream per aspect-ratio
    /// variant, so Fargo's six subtitle tracks arrive as twelve near-identical
    /// rows. The members are kept, so the variant axis is still visible.
    static func subtitles(for title: DiscTitle) -> [AssetSubtitleTrack] {
        SubtitleGrouping.groups(for: title).map { group in
            AssetSubtitleTrack(
                trackNumber: group.selectedTrackNumber,
                trackNumbers: group.members.map(\.index),
                codecID: group.members.first?.codecId,
                languageCode: group.languageCode,
                languageName: group.languageName,
                variants: group.members.compactMap(\.variant),
                isForced: group.isForced,
                isCommentary: group.isCommentary,
                isText: group.isText
            )
        }
    }
}
