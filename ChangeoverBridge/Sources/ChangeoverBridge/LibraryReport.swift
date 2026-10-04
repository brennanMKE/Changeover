// LibraryReport.swift

import Foundation

// #0197 — what `changeoverctl library <tmdb-id>` answers: is this film filed,
// and what extras does its folder already hold.
//
// Both halves come from `LibraryProbe`, which the app already runs at the
// Confirm step, so this verb adds no new class of filesystem access — it reports
// the answer the window gets. The reason the CLI needs it at all is the one in
// `docs/cli-for-agents.md`: an agent about to commit to a forty-minute encode
// should be able to find out first that the film is already there.

/// Whether a film is in the library, and what is in its folder.
public struct LibraryReport: Codable, Sendable, Equatable {
    /// What the probe concluded.
    ///
    /// `unreachable` is a distinct state and is **never** collapsed into
    /// `absent`: "not there" may only be said after a successful listing, and a
    /// NAS that has not mounted must not read as a clean library. An agent that
    /// treats the two alike will import a second copy of a film it already has
    /// the first time the mount is slow.
    public enum State {
        public static let filed = "filed"
        public static let absent = "absent"
        public static let unreachable = "unreachable"
    }

    public var tmdbID: String
    /// The `Movies/` root that was listed, from `AppSettings`. Reported because
    /// it is per-installation and an agent must never guess it.
    public var moviesPath: String
    /// The exact substring a folder had to contain to match, e.g. `{tmdb-401}`.
    /// Named so a "no" is checkable: the tag is why `{tmdb-78}` does not match
    /// `Blade Runner 2049 (2017) {tmdb-780}`.
    public var tag: String
    public var state: String
    /// Why the library could not be read. Set only when `state` is
    /// `unreachable`.
    public var reason: String?
    /// Every folder carrying the tag. Normally zero or one; more than one means
    /// the library has duplicates filed under different titles, which is worth
    /// seeing rather than hiding behind a first match.
    public var folders: [LibraryFolderReport]
    /// The disc's titles judged against those extras, when there is a scanned
    /// disc in the drive. `nil` when there is nothing to judge.
    public var discTitles: [LibraryExtraVerdict]?

    public init(
        tmdbID: String,
        moviesPath: String,
        tag: String,
        state: String,
        reason: String? = nil,
        folders: [LibraryFolderReport] = [],
        discTitles: [LibraryExtraVerdict]? = nil
    ) {
        self.tmdbID = tmdbID
        self.moviesPath = moviesPath
        self.tag = tag
        self.state = state
        self.reason = reason
        self.folders = folders
        self.discTitles = discTitles
    }

    public var humanLines: [String] {
        var lines: [String] = []
        switch state {
        case State.filed:
            lines.append("tmdb-\(tmdbID) is filed in \(moviesPath)")
        case State.absent:
            lines.append("tmdb-\(tmdbID) is not in \(moviesPath) — no folder carries \(tag)")
        default:
            lines.append("the library could not be read: \(reason ?? "no reason given")")
        }
        for folder in folders {
            lines.append("  \(folder.folderName)")
            for file in folder.files {
                lines.append("    \(file.name)\(file.sizeText.map { " — \($0)" } ?? "")")
            }
            if folder.extras.isEmpty, state == State.filed {
                lines.append("    (no extras filed)")
            }
            for extra in folder.extras {
                lines.append(
                    "    \(extra.folderName)/\(extra.name)"
                        + (extra.durationText.map { " — \($0)" } ?? " — runtime unknown")
                )
            }
        }
        for verdict in discTitles ?? [] {
            lines.append("  \(verdict.summary)")
        }
        return lines
    }
}

/// One folder in `Movies/` carrying the film's `{tmdb-ID}` tag.
public struct LibraryFolderReport: Codable, Sendable, Equatable {
    /// As it is on disk, which is not necessarily what the app would name it: a
    /// copy filed under an older or renamed title carries the same tag.
    public var folderName: String
    public var folderPath: String
    /// The film's own video files. An `{edition-…}` tag on a filename is how
    /// Plex tells two cuts of one film apart, so it is pulled out as a field.
    public var files: [LibraryFileReport]
    /// What is filed in this folder's recognised Plex extras subfolders.
    public var extras: [LibraryExtraReport]

    public init(
        folderName: String,
        folderPath: String,
        files: [LibraryFileReport] = [],
        extras: [LibraryExtraReport] = []
    ) {
        self.folderName = folderName
        self.folderPath = folderPath
        self.files = files
        self.extras = extras
    }
}

/// One video file already in the library.
public struct LibraryFileReport: Codable, Sendable, Equatable {
    public var name: String
    public var sizeBytes: Int64?
    /// ISO-8601, or absent. A string for the reason `BridgeEvent.at` is one: a
    /// `Date` across a process boundary depends on both sides agreeing a decoding
    /// strategy, and a mismatch there fails silently.
    public var modified: String?
    /// The `{edition-…}` tag the filename carries, or `nil` for Plex's unnamed
    /// default — the ordinary release.
    public var edition: String?
    /// Runtime in seconds, when it was measured. The film's own copy is **not**
    /// measured: it is a gigabyte or two and its `moov` atom is at the end of
    /// the file, so over SMB that is a seek for a number the size already
    /// implies. Extras are measured, and that is where this is filled in.
    public var durationSeconds: Int?

    public init(
        name: String,
        sizeBytes: Int64? = nil,
        modified: String? = nil,
        edition: String? = nil,
        durationSeconds: Int? = nil
    ) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.edition = edition
        self.durationSeconds = durationSeconds
    }

    public var sizeText: String? {
        guard let sizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var durationText: String? {
        guard let durationSeconds else { return nil }
        return BridgeDurationText.render(durationSeconds)
    }
}

/// One file filed as an extra of this film.
public struct LibraryExtraReport: Codable, Sendable, Equatable {
    /// The Plex extras subfolder it sits in, spelled exactly as Plex recognises
    /// it — `Behind The Scenes`, not `Behind the Scenes`. The spelling is not
    /// cosmetic: a near miss is a folder Plex scans as a film.
    public var folderName: String
    public var name: String
    public var sizeBytes: Int64?
    public var modified: String?
    /// Runtime in seconds, or `nil` when it could not be read.
    ///
    /// **`nil` is not evidence either way.** A library file with no duration is
    /// skipped by the matcher rather than counted as absent or present, which
    /// leaves the disc's copy looking importable — the safe direction, because
    /// offering an extra someone already has costs a cancellable re-encode,
    /// while hiding one they do not have loses it silently.
    public var durationSeconds: Int?

    public init(
        folderName: String,
        name: String,
        sizeBytes: Int64? = nil,
        modified: String? = nil,
        durationSeconds: Int? = nil
    ) {
        self.folderName = folderName
        self.name = name
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.durationSeconds = durationSeconds
    }

    public var durationText: String? {
        guard let durationSeconds else { return nil }
        return BridgeDurationText.render(durationSeconds)
    }
}

/// One of the disc's titles, judged against what the folder already holds.
///
/// Judged **by duration, never by filename**, and that is the whole reason this
/// is worth reporting. The library copy was named by whatever tool filed it,
/// possibly by hand and possibly years ago, while the disc's own label comes out
/// of a menu read through OCR. Two runtimes agreeing is evidence; two names
/// agreeing is a coincidence waiting to happen, and two names disagreeing proves
/// nothing at all.
public struct LibraryExtraVerdict: Codable, Sendable, Equatable {
    public var titleIndex: Int
    public var durationSeconds: Int
    /// Whether a file of matching runtime is already filed.
    public var held: Bool
    /// The matching file's extras subfolder and name, so the claim is checkable
    /// rather than taken on trust.
    public var existingFolder: String?
    public var existingName: String?
    public var existingDurationSeconds: Int?

    public init(
        titleIndex: Int,
        durationSeconds: Int,
        held: Bool,
        existingFolder: String? = nil,
        existingName: String? = nil,
        existingDurationSeconds: Int? = nil
    ) {
        self.titleIndex = titleIndex
        self.durationSeconds = durationSeconds
        self.held = held
        self.existingFolder = existingFolder
        self.existingName = existingName
        self.existingDurationSeconds = existingDurationSeconds
    }

    public var summary: String {
        let runtime = BridgeDurationText.render(durationSeconds)
        guard held, let existingFolder, let existingName else {
            return "title \(titleIndex) (\(runtime)) is not filed"
        }
        return "title \(titleIndex) (\(runtime)) is already in \(existingFolder)/\(existingName)"
    }
}

// MARK: - Shared rendering

/// `h:mm:ss` / `m:ss`, for the human output of the read verbs.
///
/// In the bridge package rather than borrowed from the app's
/// `DiscTitleFormatting`: the CLI is a separate process that does not link the
/// app, and a second copy of a format string is cheaper than making the app a
/// dependency of its own command-line tool.
public enum BridgeDurationText {
    public static func render(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
