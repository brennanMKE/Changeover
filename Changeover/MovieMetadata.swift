import Foundation

/// Plain value type constructed from a TMDB search result.
/// Drives the Plex folder and file names for the encoded output.
///
/// `Codable`/`Hashable`/`Sendable` since #0027: `RipRequest` embeds one and
/// needs both to cross the wire in Phase 4. `nonisolated` at the type level
/// for the same reason `RipRequest`/`DiscInfo` are — it has to reach the
/// `nonisolated` `EncodeController`/`PlexOrganizer` under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and — unlike the app target —
/// `ChangeoverTests` does not set that build setting, so its ~15 existing
/// `MovieMetadata(from:)` call sites (plain, non-`async`, non-`@MainActor`
/// helper functions) need this to stay a plain value conversion rather than
/// an actor-isolated one. `TMDBMovie` is itself a plain `Sendable`-shaped
/// value type, so nothing about this conversion actually needs MainActor.
nonisolated struct MovieMetadata: Codable, Hashable, Sendable {
    let title:  String
    let year:   String
    let tmdbID: String
    /// Which cut of the film this disc holds — "Collector's Edition",
    /// "Director's Cut", "Extended" — or `nil` for the ordinary release.
    ///
    /// Plex keeps every cut of a film in **one** folder and tells them apart
    /// by an `{edition-…}` tag on the filename, so this never changes
    /// `folderName`: The Jackal and The Jackal collector's edition are one
    /// movie with two editions, not two movies.
    var edition: String? = nil
    /// The disc identity this selection was made for, when the caller has
    /// one to attach — #0034. `JobController.start` compares this against
    /// the disc actually in the drive as a defence-in-depth check, backing
    /// up `RipFlowController`'s own reset-on-disc-swap. `start` refuses `nil`
    /// (fails closed); it stays optional only for metadata that never reaches
    /// `start`, such as the folder-name preview and pipeline tests.
    let selectionDisc: DiscInsertion?

    init(from movie: TMDBMovie, selectionDisc: DiscInsertion? = nil, edition: String? = nil) {
        self.title  = movie.title
        self.year   = movie.yearText
        self.tmdbID = String(movie.id)
        self.selectionDisc = selectionDisc
        self.edition = MovieMetadata.normalizedEdition(edition)
    }

    /// Plain memberwise init — for tests, `RipRequest` decoding, and any
    /// future caller with no `TMDBMovie` on hand.
    init(
        title: String,
        year: String,
        tmdbID: String,
        selectionDisc: DiscInsertion? = nil,
        edition: String? = nil
    ) {
        self.title = title
        self.year = year
        self.tmdbID = tmdbID
        self.selectionDisc = selectionDisc
        self.edition = MovieMetadata.normalizedEdition(edition)
    }

    /// Trim an edition name, drop an empty one, and make it safe to sit in a
    /// filename. `}` in particular would close Plex's tag early and leave the
    /// rest of the name dangling outside it.
    nonisolated static func normalizedEdition(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return pathSafe(trimmed)
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
    }

    /// Plex folder name, e.g. "Blade Runner (1982) {tmdb-78}"
    nonisolated var folderName: String {
        "\(Self.pathSafe(title)) (\(year)) {tmdb-\(tmdbID)}"
    }

    /// "Title (Year)" with no extension and no `{tmdb-ID}` tag — the shared
    /// stem `fileName` and #0031's `.extra` naming both build on, so the
    /// extension is written in exactly one place (`fileName`'s `.mp4`, or
    /// `LibraryPaths.resolve`'s `sourceExtension` for an extra).
    nonisolated var baseName: String {
        "\(Self.pathSafe(title)) (\(year))"
    }

    /// Encoded file name, e.g. "Blade Runner (1982).mp4", or
    /// "The Jackal (1997) {edition-Collector's Edition}.mp4" when this disc
    /// is a particular cut.
    ///
    /// Plex's own convention: the tag lives on the file, inside the one
    /// `{tmdb-…}` folder, so the editions group under a single movie.
    nonisolated var fileName: String {
        guard let edition else { return "\(baseName).mp4" }
        return "\(baseName) {edition-\(edition)}.mp4"
    }

    /// Makes an arbitrary title safe to sit inside a single filesystem path
    /// component. `title` itself is left untouched — only `folderName` and
    /// `fileName` apply this — so anything that wants the raw TMDB title
    /// (search UI, logging) still gets it verbatim. See #0010.
    ///
    /// Character decisions, in the priority order the issue calls for:
    /// - `/` is the actual break (e.g. "Face/Off" silently nests a folder).
    ///   Substituted with `-`, not stripped, so "Face-Off" stays readable —
    ///   "FaceOff" would not.
    /// - `:` is legal on APFS, but Finder displays it as `/` and it is a
    ///   known irritant for titles like "Star Wars: Episode IV". Decided
    ///   explicitly here rather than by omission: treated the same as `/`
    ///   and substituted with `-`, since Finder's rendering makes it just as
    ///   confusing as a real separator, and folder-tree tools/SMB shares are
    ///   often no more forgiving of a literal colon than of a slash.
    /// - NUL is stripped outright — never meaningful in a title, but
    ///   load-bearing once #0070 lets a remote client supply the title.
    /// - A leading `.` would produce a hidden folder/file; leading dots are
    ///   stripped. Applied before the "whole component" check below, so a
    ///   title that is only dots (e.g. "..") collapses to empty and falls
    ///   through to the empty-string fallback rather than surviving as a
    ///   traversal component.
    /// - Trailing dots and spaces are trimmed — harmless on APFS, but broken
    ///   on SMB/exFAT shares, a plausible Plex NAS setup.
    /// - An empty result (the title was nothing but dots/spaces/NULs) falls
    ///   back to a placeholder so folderName/fileName never degenerate to
    ///   just " (Year) {tmdb-ID}" or ".mp4".
    nonisolated private static func pathSafe(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")

        while result.hasPrefix(".") {
            result.removeFirst()
        }

        while let last = result.last, last == "." || last == " " {
            result.removeLast()
        }

        return result.isEmpty ? "Untitled" : result
    }

}
