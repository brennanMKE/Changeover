import Foundation

/// #0174 — where a bonus feature goes, and what it is called, so Plex shows it
/// as part of the film rather than as a film.
///
/// Plex reads extras from named subfolders inside the movie's own folder, and
/// those names are a fixed, recognised set — a folder outside it is scanned as
/// a movie, which is the whole hazard #0031 avoided by sending extras to a
/// separate `Clips` tree entirely. This keeps that reasoning and narrows it:
/// inside a movie folder, a *recognised* extras subfolder is not scanned as a
/// movie, so it is the one place an extra may safely live beside its film.
///
///     Movies/Signs (2002) {tmdb-452}/Signs (2002).mp4
///     Movies/Signs (2002) {tmdb-452}/Behind The Scenes/looking for Signs.mp4
///
/// The subfolder form is used rather than Plex's `-behindthescenes` filename
/// suffix because it lets each extra keep the name the disc's own menu printed
/// for it, and because several extras of one kind cannot collide.
nonisolated enum PlexExtra {

    /// Plex's recognised extras subfolders, exactly as Plex spells them.
    ///
    /// Spelling matters: Plex matches these names, and a near miss
    /// ("Behind the Scenes") is an unrecognised folder, which is scanned as a
    /// movie — the failure this type exists to prevent.
    nonisolated enum Kind: String, CaseIterable, Equatable, Sendable, Codable {
        case behindTheScenes = "Behind The Scenes"
        case deletedScenes = "Deleted Scenes"
        case featurettes = "Featurettes"
        case interviews = "Interviews"
        case scenes = "Scenes"
        case shorts = "Shorts"
        case trailers = "Trailers"
        case other = "Other"

        var folderName: String { rawValue }
    }

    /// Every folder name Plex treats as extras rather than as a film.
    static let recognisedFolderNames: Set<String> = Set(Kind.allCases.map(\.folderName))

    /// Whether one path component is a recognised extras folder. Case
    /// insensitive, because Plex is and because a disc's own capitalisation
    /// should not decide whether a file is scanned as a movie.
    static func isRecognisedFolder(_ component: String) -> Bool {
        recognisedFolderNames.contains { $0.compare(component, options: .caseInsensitive) == .orderedSame }
    }

    /// What kind of extra a menu label describes.
    ///
    /// Keyword rules over the words DVD menus actually print, taken from the
    /// captured corpus — Signs' bonus menu alone prints "looking for Signs",
    /// "building Signs", "making Signs: a commentary", "the effects of Signs",
    /// "last voices: the music of Signs" and "full circle". Most of those are
    /// making-of material, which is what `behindTheScenes` means, and the rest
    /// fall to `featurettes`, the honest default for "a short film about the
    /// film". `other` is reserved for a label that says nothing.
    static func kind(forLabel label: String) -> Kind {
        let text = label.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        if has(["deleted", "outtake", "alternate ending", "alternate scene"]) { return .deletedScenes }
        if has(["trailer", "teaser", "tv spot"]) { return .trailers }
        if has(["interview", "conversation with", "in conversation"]) { return .interviews }
        if has(["making", "behind the scenes", "behind-the-scenes", "building",
                "looking for", "on the set", "production diary", "documentary"]) {
            return .behindTheScenes
        }
        if has(["short film", "animated short"]) { return .shorts }
        if has(["featurette", "effects", "music", "score", "gag reel", "bloopers"]) { return .featurettes }
        return label.isEmpty ? .other : .featurettes
    }

    /// A filename for an extra, from the label the disc printed.
    ///
    /// Path-sanitised the same way `MovieMetadata` sanitises a film title
    /// (#0010): a label is disc text and may hold anything, and it is about to
    /// become a path component.
    ///
    /// `titleIndex` is appended only when the label gives nothing to go on, so
    /// the ordinary case reads as the disc reads and the degenerate case is
    /// still unique and still traceable to the title it came from.
    static func fileName(label: String, titleIndex: Int, extension ext: String) -> String {
        let cleaned = sanitize(label)
        let stem = cleaned.isEmpty ? "Bonus Feature - t\(String(format: "%02d", titleIndex))" : cleaned
        return "\(stem).\(ext)"
    }

    /// `/` and `:` are directory separators to one layer or another of macOS,
    /// and a label is not trusted to avoid them.
    static func sanitize(_ label: String) -> String {
        var text = label
        for bad in ["/", ":", "\\", "\n", "\r", "\t"] {
            text = text.replacingOccurrences(of: bad, with: "-")
        }
        // A run of dots is never part of a title and is how a path climbs out
        // of its folder. The separators above are already gone, so this cannot
        // reach anything on its own — it is removed so the NAME is clean and
        // so nothing downstream has to reason about whether it is.
        while let range = text.range(of: "..") {
            text.replaceSubrange(range, with: "")
        }
        // A leading dot hides the file; a trailing dot or space is dropped by
        // some filesystems and kept by others.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") || text.hasSuffix(" ") { text.removeLast() }
        // And a name made only of the separators we substituted is no name.
        let meaningful = text.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return meaningful.isEmpty ? "" : text.trimmingCharacters(in: .whitespaces)
    }
}
