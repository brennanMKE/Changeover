import Foundation

/// #0031 Step A — makes "an extra ends up in `Movies/`" impossible by
/// construction. `PlexOrganizer.move` used to take its destination as a bare
/// `String`, so a caller could pass the wrong path with nothing stopping it.
/// Now it takes a `LibraryDestination` and a `LibraryRoots`, and *it* is the
/// only place that computes a path — a caller cannot supply one, so a caller
/// cannot supply the wrong one.
///
/// `nonisolated` and `Sendable` for the same reason as `RipRequest`/
/// `DiscInfo`: built on MainActor (`DVDPipeline`'s captures) and consumed by
/// the `nonisolated` `PlexOrganizer`.

/// The three paths derived from `AppSettings.plexMediaRoot`. There is no
/// memberwise init taking three independent strings — the only constructor
/// derives all three from one root, so a caller cannot build roots where
/// `clipsPath` happens to equal `moviesPath`.
nonisolated struct LibraryRoots: Equatable, Sendable {
    /// e.g. `<root>/Movies`
    let moviesPath: String
    /// e.g. `<root>/TV Shows`. Used only by the `.extra` overlap guard today
    /// — nothing in this phase writes a TV destination.
    let tvPath: String
    /// e.g. `<root>/Clips`. Plex's libraries point at `Movies` and
    /// `TV Shows`, not at the media root, so this folder is invisible to
    /// Plex (issues/0031.md's "Decisions (user, 2026-09-15)").
    let clipsPath: String

    init(mediaRoot: String) {
        moviesPath = "\(mediaRoot)/Movies"
        tvPath = "\(mediaRoot)/TV Shows"
        clipsPath = "\(mediaRoot)/Clips"
    }
}

/// Which library a moved file belongs to.
nonisolated enum LibraryDestination: Equatable, Sendable {
    /// `<root>/Movies/<Title (Year) {tmdb-ID}>/<Title (Year)>.<ext>` — the
    /// strict Plex naming convention (`CLAUDE.md`).
    case feature
    /// `<root>/Clips/<Title (Year) {tmdb-ID}>/<Title (Year)> - t<NN>.<ext>` —
    /// deliberately *not* Plex-shaped, because looking like a Plex movie is
    /// the thing this type exists to avoid. `titleIndex` is HandBrake's
    /// title number, carried in the filename because HandBrake gives extras
    /// no names of their own.
    case extra(titleIndex: Int)
}

/// The pure path resolver. `PlexOrganizer.move` is the only caller in
/// production; tests exercise it directly with no filesystem at all.
nonisolated enum LibraryPaths {
    struct Resolved: Equatable, Sendable {
        /// The folder the file lands in — `Movies/<folderName>` or
        /// `Clips/<folderName>`, in both cases named after the same
        /// `MovieMetadata.folderName` so extras stay findable next to the
        /// movie and #0120's clip library has a folder to walk.
        let folder: String
        /// The full destination path, `folder` plus the file name.
        let file: String
    }

    /// - Parameter sourceExtension: the encoded file's own extension (e.g.
    ///   `"mp4"`, `"mkv"`), never hard-coded — issues/0031.md's "Notes"
    ///   section is explicit that `.extra`'s container is an open question
    ///   and must not inherit `MovieMetadata.fileName`'s `.mp4` assumption.
    ///   `.feature` ignores this parameter entirely and always uses
    ///   `metadata.fileName`, which keeps today's Plex naming byte-for-byte.
    static func resolve(
        _ destination: LibraryDestination,
        metadata: MovieMetadata,
        roots: LibraryRoots,
        sourceExtension: String
    ) -> Resolved {
        switch destination {
        case .feature:
            let folder = (roots.moviesPath as NSString).appendingPathComponent(metadata.folderName)
            let file = (folder as NSString).appendingPathComponent(metadata.fileName)
            return Resolved(folder: folder, file: file)

        case .extra(let titleIndex):
            let folder = (roots.clipsPath as NSString).appendingPathComponent(metadata.folderName)
            let paddedIndex = String(format: "%02d", titleIndex)
            let ext = sourceExtension.isEmpty ? "mp4" : sourceExtension
            let name = "\(metadata.baseName) - t\(paddedIndex).\(ext)"
            let file = (folder as NSString).appendingPathComponent(name)
            return Resolved(folder: folder, file: file)
        }
    }
}
