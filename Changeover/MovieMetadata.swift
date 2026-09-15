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
    /// The disc identity this selection was made for, when the caller has
    /// one to attach — #0034. `JobController.start` compares this against
    /// the disc actually in the drive as a defence-in-depth check, backing
    /// up `MetadataEntryView`'s own reset-on-disc-swap. `start` refuses `nil`
    /// (fails closed); it stays optional only for metadata that never reaches
    /// `start`, such as the folder-name preview and pipeline tests.
    let selectionDisc: DiscInsertion?

    init(from movie: TMDBMovie, selectionDisc: DiscInsertion? = nil) {
        self.title  = movie.title
        self.year   = movie.yearText
        self.tmdbID = String(movie.id)
        self.selectionDisc = selectionDisc
    }

    /// Plain memberwise init — for tests, `RipRequest` decoding, and any
    /// future caller with no `TMDBMovie` on hand.
    init(title: String, year: String, tmdbID: String, selectionDisc: DiscInsertion? = nil) {
        self.title = title
        self.year = year
        self.tmdbID = tmdbID
        self.selectionDisc = selectionDisc
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

    /// Encoded file name, e.g. "Blade Runner (1982).mp4"
    nonisolated var fileName: String {
        "\(baseName).mp4"
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
