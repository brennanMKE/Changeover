// AssetManifest.swift

import Foundation

// #0197 — what `changeoverctl assets` hands back: a manifest naming every file
// it wrote, and the audio and subtitle detail per title.
//
// The manifest is the product, not a courtesy. An agent that has to walk a
// directory to find out what is in it has to encode this app's layout in its
// own code, and then the layout cannot change — so the layout is *reported*
// instead, one entry per file with an absolute path. Reading `manifest.json`
// alone is enough to know what is there and what is missing, which is the test
// this type is written against.
//
// The same value is written to the cache as `manifest.json` and returned over
// XPC, so `assets --json` and the file on disk cannot disagree.

// MARK: - Where the cache lives

/// The temporary directory `assets` writes into, and the names inside it.
///
/// **The system temp directory on purpose**, and the user asked for it in those
/// words: these artifacts are a cache that should be deleted after a while, and
/// `$TMPDIR` is the one place macOS already clears when it needs the space —
/// after a reboot, and under disk pressure, without the app owning a reaper of
/// its own. A reaper is a thing that can be wrong; `$TMPDIR` cannot.
///
/// So **the path is not durable and an agent must not store it across a long
/// gap**. Re-running `assets` is cheap — it is a copy of a few hundred kilobytes
/// and one JSON encode — and it is the only thing that is guaranteed to be
/// right. `docs/cli-for-agents.md` says the same.
///
/// Keyed on the disc, through the same `MenuArchive.slug` the app's own archive
/// uses: lsdvd's `dvddiscid` when there is one, the volume label when there is
/// not. One pressing therefore lands in one directory however many times it goes
/// in, so a second call after the menu read finishes *improves* the first
/// instead of making a rival copy beside it.
public enum AssetCache {

    /// The one directory under `$TMPDIR` every disc's cache sits in, so a human
    /// looking for it has one place to look and a sweep has one thing to delete.
    public static let containerName = "changeover-assets"

    /// The path for one disc's cache. Pure, so the derivation is testable
    /// without writing anything: `root` is the only thing a test has to replace.
    public static func directory(slug: String, root: String = NSTemporaryDirectory()) -> String {
        let container = (root as NSString).appendingPathComponent(containerName)
        return (container as NSString).appendingPathComponent(slug)
    }

    /// The published names inside one disc's cache.
    ///
    /// `scan.json` and `menus/ocr.json` deliberately match the names
    /// `MenuArchive` and `Tools/capture-disc.sh` already write, so one piece of
    /// analysis code reads a hand-captured disc, the app's own archive and this
    /// cache without three sets of filenames.
    public enum Name {
        public static let manifest = "manifest.json"
        public static let scan = "scan.json"
        public static let tracks = "tracks.json"
        public static let menus = "menus"
        public static let structure = "menus/structure.json"
        public static let ocr = "menus/ocr.json"
        public static let derived = "menus/derived.json"
        public static let menuLines = "menus/lines.json"
        public static let stills = "menus/stills"
    }

    /// Joins a published name onto a cache directory. One function so no caller
    /// hand-builds a path and gets the separator wrong on the one platform.
    public static func path(_ name: String, in directory: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }
}

// MARK: - Manifest

/// Everything the app collected about the disc in the drive, as one document.
public struct AssetManifest: Codable, Sendable, Equatable {
    /// Versioned like every other archive document in this project, because
    /// something will read one of these back a year from now.
    public var format: String = "changeover-assets/1"
    public var builtAt: String
    /// The cache directory. This is what `assets` prints in its human form, and
    /// what the worked session in `docs/cli-for-agents.md` captures.
    public var path: String
    /// `manifest.json` itself, named rather than left to be derived, so an agent
    /// handed only this value can point another process at the file.
    public var manifestPath: String
    public var disc: AssetDisc
    public var scan: AssetScanSummary?
    public var menus: AssetMenuSummary
    /// Every file in the cache, with its absolute path.
    public var artifacts: [AssetArtifact]
    /// The audio and subtitle detail, per title. Also written to `tracks.json`,
    /// because an agent that wants only the tracks should not have to hold the
    /// whole manifest — and because the manifest has to stand alone.
    public var titles: [AssetTitleTracks]
    /// What is **not** here and why, in plain sentences.
    ///
    /// The absence of a menu read is the normal case on plenty of discs, so it
    /// cannot be reported as an error and it cannot be reported as nothing: an
    /// agent that sees no `structure.json` and no explanation has to guess
    /// between "this disc has no menus" and "the app is broken". The notes are
    /// how it does not have to.
    public var notes: [String]
    /// The app's own durable archive for this disc (`Settings ▸ Disc archive`),
    /// or `nil` when archiving is switched off. The cache is a copy of it plus
    /// what was only ever in memory; naming the original is what lets someone
    /// check a copy that looks wrong.
    public var archivePath: String?

    public init(
        builtAt: String = BridgeEvent.timestamp(),
        path: String,
        manifestPath: String,
        disc: AssetDisc,
        scan: AssetScanSummary? = nil,
        menus: AssetMenuSummary,
        artifacts: [AssetArtifact] = [],
        titles: [AssetTitleTracks] = [],
        notes: [String] = [],
        archivePath: String? = nil
    ) {
        self.builtAt = builtAt
        self.path = path
        self.manifestPath = manifestPath
        self.disc = disc
        self.scan = scan
        self.menus = menus
        self.artifacts = artifacts
        self.titles = titles
        self.notes = notes
        self.archivePath = archivePath
    }

    /// The artifact with this published name, if it was written.
    public func artifact(named name: String) -> AssetArtifact? {
        artifacts.first { $0.name == name }
    }

    /// The human form. One line per fact, the path first, because a person
    /// running this by hand wants to `cd` into it.
    public var humanLines: [String] {
        var lines = [path]
        lines.append("disc \(disc.label)\(disc.discID.map { " (\($0))" } ?? " (no disc id)")")
        if let scan {
            lines.append(
                "scan \(scan.state) — \(scan.titleCount ?? 0) title(s)"
                    + (scan.mainFeatureIndex.map { ", main feature \($0)" } ?? ", no main feature named")
            )
        } else {
            lines.append("scan — not run yet")
        }
        lines.append("menus \(menus.state)" + (menus.reason.map { " — \($0)" } ?? ""))
        for artifact in artifacts {
            lines.append("  \(artifact.name)")
        }
        for title in titles {
            lines.append(
                "  title \(title.index): \(title.audio.count) audio, "
                    + "\(title.subtitles.count) subtitle group(s)"
                    + (title.audioIsAllUntagged ? " — every audio track is untagged" : "")
            )
        }
        lines.append(contentsOf: notes.map { "note: \($0)" })
        return lines
    }
}

// MARK: - Disc

/// Which disc this cache is about.
///
/// `insertionID` rather than only the disc id, for the reason
/// `BridgeStatusReader.discStatus` gives: two visits by discs with no resolvable
/// identity share a path, a device node and a `discID` of `nil`, and the
/// insertion token is the only thing that tells them apart.
public struct AssetDisc: Codable, Sendable, Equatable {
    public var label: String
    public var discID: String?
    public var insertionID: String
    public var mountPath: String
    /// The cache's directory name, which is also the app archive's. Reported so
    /// an agent can correlate the two without re-deriving the slug rule.
    public var slug: String

    public init(
        label: String,
        discID: String? = nil,
        insertionID: String,
        mountPath: String,
        slug: String
    ) {
        self.label = label
        self.discID = discID
        self.insertionID = insertionID
        self.mountPath = mountPath
        self.slug = slug
    }
}

// MARK: - Scan

/// The scan, summarised. The whole of it is in `scan.json`.
public struct AssetScanSummary: Codable, Sendable, Equatable {
    public var state: String
    public var titleCount: Int?
    public var mainFeatureIndex: Int?
    public var featureDurationSeconds: Int?
    public var warnings: [String]
    public var failure: String?

    public init(
        state: String,
        titleCount: Int? = nil,
        mainFeatureIndex: Int? = nil,
        featureDurationSeconds: Int? = nil,
        warnings: [String] = [],
        failure: String? = nil
    ) {
        self.state = state
        self.titleCount = titleCount
        self.mainFeatureIndex = mainFeatureIndex
        self.featureDurationSeconds = featureDurationSeconds
        self.warnings = warnings
        self.failure = failure
    }
}

// MARK: - Menus

/// How the menu read ended.
public struct AssetMenuSummary: Codable, Sendable, Equatable {
    public enum State {
        public static let idle = "idle"
        public static let reading = "reading"
        public static let ready = "ready"
        public static let unavailable = "unavailable"
    }

    public var state: String
    /// The app's own caption when the read produced nothing, verbatim. It always
    /// ends "The rip is unaffected." — which is the point.
    public var reason: String?
    public var menuCount: Int?
    public var stillCount: Int?
    /// Menu text, page by page, exactly as `DiscEvidence` assembles it for the
    /// app's own inference — not the raw OCR.
    ///
    /// Pages, not one flat list: a DVD menu's structure is evidence, and the Get
    /// Hard disc's entry menu printing the PLAY block once per film is the
    /// strongest signal on the disc that it holds two films. Flattening destroys
    /// that. The count is here; the lines themselves are in `menus/lines.json`,
    /// because a manifest that inlines every menu line stops being a manifest.
    public var menuLineCount: Int?
    /// The title the disc printed on its own menus, when one was read.
    public var titleText: String?

    public init(
        state: String,
        reason: String? = nil,
        menuCount: Int? = nil,
        stillCount: Int? = nil,
        menuLineCount: Int? = nil,
        titleText: String? = nil
    ) {
        self.state = state
        self.reason = reason
        self.menuCount = menuCount
        self.stillCount = stillCount
        self.menuLineCount = menuLineCount
        self.titleText = titleText
    }
}

/// `menus/lines.json` — the menu text, page by page.
public struct AssetMenuLines: Codable, Sendable, Equatable {
    public var format: String = "changeover-menu-lines/1"
    public var pages: [[String]]

    public init(pages: [[String]]) {
        self.pages = pages
    }
}

/// `tracks.json` — the per-title audio and subtitle detail on its own.
public struct AssetTracksDocument: Codable, Sendable, Equatable {
    public var format: String = "changeover-disc-tracks/1"
    public var titles: [AssetTitleTracks]

    public init(titles: [AssetTitleTracks]) {
        self.titles = titles
    }
}

// MARK: - Artifacts

/// One file in the cache.
public struct AssetArtifact: Codable, Sendable, Equatable {
    public enum Kind {
        public static let scan = "scan"
        public static let tracks = "tracks"
        public static let ocr = "ocr"
        public static let structure = "structure"
        public static let derived = "derived"
        public static let menuLines = "menuLines"
        public static let still = "still"
    }

    /// Where it came from, which decides how much to trust it.
    ///
    /// `app` means it was encoded from state the app holds right now, so it is
    /// current by construction. `archive` means it was copied out of the app's
    /// durable archive, where the menu read left it — and the menu read happens
    /// once per disc, so a copy can be older than this call. The distinction
    /// matters when the two disagree.
    public enum Source {
        public static let app = "app"
        public static let archive = "archive"
    }

    /// The published name, relative to the cache directory, e.g.
    /// `menus/stills/vmgm-1.jpg`.
    public var name: String
    public var path: String
    public var kind: String
    public var source: String
    public var byteCount: Int64?

    public init(name: String, path: String, kind: String, source: String, byteCount: Int64? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.source = source
        self.byteCount = byteCount
    }
}

// MARK: - Tracks

/// One title's streams, as an agent needs them.
public struct AssetTitleTracks: Codable, Sendable, Equatable {
    public var index: Int
    public var durationSeconds: Int
    public var chapterCount: Int
    /// Display aspect ratio, about 1.78 for widescreen and about 1.33 for a 4:3
    /// transfer. It is here because of flipper discs, which carry the same film
    /// twice at identical runtimes and are otherwise indistinguishable.
    public var displayAspect: Double?
    public var angleCount: Int?
    /// What the scan's own heuristic suggested: `mainFeature`, `extra`, `ignore`.
    /// A suggestion, never a decision.
    public var suggestedRole: String
    public var isMainFeature: Bool
    /// One entry per *offering*, not per stream — duplicates HandBrake reports
    /// twice are merged the way the app's own picker merges them, and the merged
    /// track numbers are kept in `duplicateTrackNumbers` rather than dropped.
    public var audio: [AssetAudioTrack]
    /// One entry per logical subtitle track. HandBrake reports a separate stream
    /// per aspect-ratio variant, so Fargo's six subtitle tracks arrive as
    /// twelve; grouping them is what makes the count mean something.
    public var subtitles: [AssetSubtitleTrack]
    /// True when **no** audio stream on this title carries a language tag.
    ///
    /// Reported as its own fact because it changes what an agent may conclude:
    /// on such a title the language preference has nothing to match against, and
    /// two identical-looking untagged tracks are exactly what a foreign original
    /// plus an English dub looks like.
    public var audioIsAllUntagged: Bool

    public init(
        index: Int,
        durationSeconds: Int,
        chapterCount: Int,
        displayAspect: Double? = nil,
        angleCount: Int? = nil,
        suggestedRole: String,
        isMainFeature: Bool,
        audio: [AssetAudioTrack] = [],
        subtitles: [AssetSubtitleTrack] = [],
        audioIsAllUntagged: Bool = false
    ) {
        self.index = index
        self.durationSeconds = durationSeconds
        self.chapterCount = chapterCount
        self.displayAspect = displayAspect
        self.angleCount = angleCount
        self.suggestedRole = suggestedRole
        self.isMainFeature = isMainFeature
        self.audio = audio
        self.subtitles = subtitles
        self.audioIsAllUntagged = audioIsAllUntagged
    }
}

/// One audio offering on one title.
public struct AssetAudioTrack: Codable, Sendable, Equatable {
    /// HandBrake's `TrackNumber` for the kept occurrence — the integer an encode
    /// is given.
    public var trackNumber: Int
    /// Identical tagged tracks merged into this one, beyond the first. Always
    /// empty for an untagged track, because untagged streams are never merged.
    public var duplicateTrackNumbers: [Int]
    public var codecID: String?
    /// ISO 639-2, normalised. **`null` means untagged, and untagged is not
    /// English** (#0027). Defaulting it is how a silent MP4 gets made, so
    /// nothing in this pipeline defaults it and nothing reading this should
    /// either.
    public var languageCode: String?
    /// A localised display string. Never branch on it.
    public var languageName: String?
    public var displayName: String
    /// HandBrake's variant axis, distinct from language: `English (Wide Screen)`
    /// and `English (Letterbox)` are two streams, and the parenthetical lives
    /// here rather than folded into the language.
    public var variant: String?
    public var channelCount: Int?
    /// As HandBrake prints it, e.g. `448 Kb/s`. A string because that is what
    /// the scan gives and parsing it would invent precision.
    public var bitrate: String?
    public var isCommentary: Bool
    public var isForced: Bool
    public var isDefault: Bool
    /// The raw flag bits. Known: 1 and 2 commentary, 4096 forced. Kept because
    /// the interpretation is known to be incomplete — at least one more flag
    /// exists upstream — and a consumer should be able to see what was there.
    public var flags: Int

    public init(
        trackNumber: Int,
        duplicateTrackNumbers: [Int] = [],
        codecID: String? = nil,
        languageCode: String? = nil,
        languageName: String? = nil,
        displayName: String,
        variant: String? = nil,
        channelCount: Int? = nil,
        bitrate: String? = nil,
        isCommentary: Bool = false,
        isForced: Bool = false,
        isDefault: Bool = false,
        flags: Int = 0
    ) {
        self.trackNumber = trackNumber
        self.duplicateTrackNumbers = duplicateTrackNumbers
        self.codecID = codecID
        self.languageCode = languageCode
        self.languageName = languageName
        self.displayName = displayName
        self.variant = variant
        self.channelCount = channelCount
        self.bitrate = bitrate
        self.isCommentary = isCommentary
        self.isForced = isForced
        self.isDefault = isDefault
        self.flags = flags
    }
}

/// One logical subtitle track on one title.
public struct AssetSubtitleTrack: Codable, Sendable, Equatable {
    /// The track number an encode would take: the `Wide Screen` variant when
    /// there is one, else the lowest.
    public var trackNumber: Int
    /// Every stream in the group, in track-number order. More than one means the
    /// same subtitles at a different disc framing, not different subtitles.
    public var trackNumbers: [Int]
    public var codecID: String?
    /// ISO 639-2, normalised. `null` means untagged — the same rule as audio.
    public var languageCode: String?
    public var languageName: String?
    public var variants: [String]
    public var isForced: Bool
    public var isCommentary: Bool
    /// A text track (CC608) rather than a bitmap one. MP4 can carry text;
    /// VOBSUB bitmaps it cannot.
    public var isText: Bool

    public init(
        trackNumber: Int,
        trackNumbers: [Int],
        codecID: String? = nil,
        languageCode: String? = nil,
        languageName: String? = nil,
        variants: [String] = [],
        isForced: Bool = false,
        isCommentary: Bool = false,
        isText: Bool = false
    ) {
        self.trackNumber = trackNumber
        self.trackNumbers = trackNumbers
        self.codecID = codecID
        self.languageCode = languageCode
        self.languageName = languageName
        self.variants = variants
        self.isForced = isForced
        self.isCommentary = isCommentary
        self.isText = isText
    }
}
