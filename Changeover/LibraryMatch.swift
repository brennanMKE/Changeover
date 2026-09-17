import Foundation

/// #0062 — what one file already in the Plex library looks like to us.
/// `durationSeconds` is `nil` today and exists so adding it later is not a
/// wire change: HandBrake writes the `moov` atom at the *end* of the file, so
/// measuring a 1–2 GB library copy over SMB is a seek to its tail for a number
/// the size already implies.
nonisolated struct LibraryFile: Equatable, Sendable, Codable {
    let name: String
    let sizeBytes: Int64?
    let modified: Date?
    var durationSeconds: Int?

    init(name: String, sizeBytes: Int64? = nil, modified: Date? = nil, durationSeconds: Int? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.durationSeconds = durationSeconds
    }
}

/// One folder in `Movies/` carrying the movie's `{tmdb-ID}` tag.
nonisolated struct LibraryEntry: Equatable, Sendable, Codable {
    /// As on disk — which is not necessarily `MovieMetadata.folderName`: a
    /// copy filed under an older or renamed title carries the same tag.
    let folderName: String
    let folderPath: String
    /// Video files only, name-sorted.
    let files: [LibraryFile]
}

/// #0062 — the answer to "is this film already in Plex?".
///
/// `.unreachable` is a distinct case on purpose and is **never** collapsed
/// into `.absent`: "not there" may only ever be said after a successful
/// listing. A drive that is not mounted must not read as a clean library.
nonisolated enum LibraryLookup: Equatable, Sendable, Codable {
    case absent
    /// At least one matched folder holding at least one video file.
    case present([LibraryEntry])
    /// The root is missing or unmounted, the listing threw, or it timed out.
    case unreachable(reason: String)
}

/// #0062 — the pure half of the library check: no filesystem at all.
///
/// Plex naming here is strict and the `{tmdb-ID}` tag is unique per film
/// (`MovieMetadata.folderName`, `LibraryPaths.resolve`), so "is this film in
/// the library?" is a tag match over one directory listing. Matching on the
/// tag rather than the whole folder name also catches a copy filed under a
/// different title — TMDB renamed it, or an older tool named it.
nonisolated enum LibraryMatch {

    /// Folder names carrying **exactly** `{tmdb-<id>}`, in listing order.
    ///
    /// The closing brace is what makes this prefix-safe: `{tmdb-78}` must
    /// never match `Blade Runner 2049 (2017) {tmdb-780}`, and `{tmdb-178}`
    /// must never match `{tmdb-78}`. Both would file a new encode on top of
    /// a different film's warning — or, worse, suppress the warning for the
    /// film that really is there.
    static func folders(in names: [String], tmdbID: String) -> [String] {
        let tag = tag(for: tmdbID)
        return names.filter { $0.contains(tag) }
    }

    /// The exact substring a folder for `tmdbID` must contain.
    static func tag(for tmdbID: String) -> String { "{tmdb-\(tmdbID)}" }

    /// Plex's own video extension set, not ours — a library copy this app
    /// never wrote (an `.mkv` from an older tool) still counts as "already
    /// there".
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mkv", "avi", "mov", "ts"]

    static func isVideoFile(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Turns matched folders and their raw file listings into a lookup.
    ///
    /// A matched folder holding no video file — empty, or only a poster and a
    /// `.nfo` — is **not** a duplicate: nothing there would be overwritten,
    /// so warning about it would be a stop-and-ask with nothing behind it.
    static func lookup(folders: [(name: String, path: String, files: [LibraryFile])]) -> LibraryLookup {
        let entries: [LibraryEntry] = folders.compactMap { folder in
            let videos = folder.files
                .filter { isVideoFile($0.name) }
                .sorted { $0.name < $1.name }
            guard !videos.isEmpty else { return nil }
            return LibraryEntry(folderName: folder.name, folderPath: folder.path, files: videos)
        }
        return entries.isEmpty ? .absent : .present(entries)
    }
}
