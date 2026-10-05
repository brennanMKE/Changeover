import ChangeoverBridge
import Foundation

/// #0197 — turns `LibraryProbe`'s answer into the report
/// `changeoverctl library <tmdb-id>` prints.
///
/// Pure, `nonisolated`, no filesystem of its own: the probe does the listing and
/// this maps its value onto the wire. That split is what lets the judgement here
/// be tested with no Plex volume, no NAS mount and no disc — which, with UI tests
/// forbidden in this project, is the only coverage there is.
///
/// Two things in here are decisions rather than transcription, and both have cost
/// someone an evening before.
///
/// **`unreachable` is never flattened into `absent`.** "This film is not in the
/// library" may only be said after a listing that succeeded. A NAS that has not
/// mounted yet lists as nothing, and an agent that reads nothing as absence
/// imports a second copy of a film that is already filed. `LibraryLookup` keeps
/// the three cases apart for exactly this reason and so does this report.
///
/// **The extras are judged by duration, not by filename.** The library copy was
/// named by whatever tool filed it, possibly by hand and possibly years ago,
/// while the disc's own label for the same featurette comes out of a menu read
/// through OCR. Two runtimes agreeing is evidence; two names agreeing is a
/// coincidence waiting to happen, and two names disagreeing proves nothing at
/// all. `LibraryExtras.verdicts` is the one place that comparison lives and this
/// calls it rather than writing a second one.
nonisolated enum BridgeLibraryReader {

    /// ISO-8601 for a file's modification date.
    ///
    /// A string on the wire, for the reason `BridgeEvent.at` is one: a `Date`
    /// crossing a process boundary depends on both sides agreeing a decoding
    /// strategy, and a mismatch there is a silent decode failure rather than an
    /// error anyone sees.
    private static let dates = ISO8601DateFormatter()

    static func report(
        tmdbID: String,
        moviesPath: String,
        lookup: LibraryLookup,
        discTitles: [DiscTitle],
        /// #0221 — which title the scan called the main feature.
        ///
        /// The feature is identified by **index**, not by runtime. #0216
        /// matched it against the film file's duration, and `LibraryProbe`
        /// deliberately never reads one: "measuring a 1–2 GB library copy over
        /// SMB is a seek to its tail for a number the file size already
        /// implies." So that match could not fire in production, and the tests
        /// passed only because their fixtures supplied a duration the real
        /// probe does not. Caught on SPLIT, where title 3 still reported "not
        /// among this film's extras".
        mainFeatureIndex: Int? = nil
    ) -> LibraryReport {
        let tag = LibraryMatch.tag(for: tmdbID)

        switch lookup {
        case .unreachable(let reason):
            return LibraryReport(
                tmdbID: tmdbID,
                moviesPath: moviesPath,
                tag: tag,
                state: LibraryReport.State.unreachable,
                reason: reason
            )

        case .absent:
            // No folders, and no verdicts either: with no folder there are no
            // extras to judge against, and a list of "not held" verdicts would
            // read as a judgement that had been made rather than one that could
            // not be.
            return LibraryReport(
                tmdbID: tmdbID,
                moviesPath: moviesPath,
                tag: tag,
                state: LibraryReport.State.absent
            )

        case .present(let entries):
            let extras = entries.flatMap(\.extras)
            return LibraryReport(
                tmdbID: tmdbID,
                moviesPath: moviesPath,
                tag: tag,
                state: LibraryReport.State.filed,
                folders: entries.map(folder(_:)),
                discTitles: discTitles.isEmpty
                    ? nil
                    // #0216 — the film's own files too, so the feature title
                    // gets a true answer instead of "not filed".
                    : verdicts(
                        forTitles: discTitles,
                        against: extras,
                        films: entries.flatMap(\.files),
                        mainFeatureIndex: mainFeatureIndex)
            )
        }
    }

    static func folder(_ entry: LibraryEntry) -> LibraryFolderReport {
        LibraryFolderReport(
            folderName: entry.folderName,
            folderPath: entry.folderPath,
            files: entry.files.map(file(_:)),
            extras: entry.extras.map(extra(_:))
        )
    }

    static func file(_ file: LibraryFile) -> LibraryFileReport {
        LibraryFileReport(
            name: file.name,
            sizeBytes: file.sizeBytes,
            modified: file.modified.map { dates.string(from: $0) },
            // The `{edition-…}` tag, pulled out as a field rather than left in
            // the name: Plex keeps every cut of a film in one folder and tells
            // them apart by this tag alone, so an agent deciding whether the
            // disc in the drive is already filed has to read it, and should not
            // have to parse a filename to do so.
            edition: LibraryMatch.edition(ofFileName: file.name),
            durationSeconds: file.durationSeconds
        )
    }

    static func extra(_ extra: LibraryExtraFile) -> LibraryExtraReport {
        LibraryExtraReport(
            folderName: extra.folderName,
            name: extra.file.name,
            sizeBytes: extra.file.sizeBytes,
            modified: extra.file.modified.map { dates.string(from: $0) },
            durationSeconds: extra.file.durationSeconds
        )
    }

    /// The disc's titles against the folder's extras, through `LibraryExtras`.
    ///
    /// Every title is reported, not only the short ones. The feature will match
    /// nothing in an extras folder and that is itself worth saying out loud: a
    /// report that silently omitted it would leave an agent wondering whether the
    /// title had been considered.
    /// - Parameter films: the film's own files, at the root of its folder.
    ///   Without them a feature title could only ever be reported as "not
    ///   filed", which is what made this report contradict itself (#0216).
    static func verdicts(
        forTitles titles: [DiscTitle],
        against extras: [LibraryExtraFile],
        films: [LibraryFile] = [],
        mainFeatureIndex: Int? = nil
    ) -> [LibraryExtraVerdict] {
        let byIndex = Dictionary(
            titles.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return LibraryExtras.verdicts(forTitles: titles, against: extras).map { verdict in
            let seconds = byIndex[verdict.titleIndex]?.durationSeconds ?? 0
            // #0216 — an extras match wins when there is one; otherwise ask
            // whether this title is the film itself. Matched on duration, the
            // same way extras are and for the same reason: the library copy was
            // named by whatever filed it, possibly years ago and possibly by
            // hand, and two names agreeing is a coincidence waiting to happen.
            // #0221 — the feature is the title the scan named, and the film is
            // whatever sits at the root of the folder. No runtime involved on
            // either side, because neither side has one: the probe does not
            // measure library films, and asking it to would cost a seek to the
            // tail of a 1–2 GB file over SMB for a fact already in hand.
            if !verdict.isHeld,
               let mainFeatureIndex, verdict.titleIndex == mainFeatureIndex,
               let film = films.first {
                return LibraryExtraVerdict(
                    titleIndex: verdict.titleIndex,
                    durationSeconds: seconds,
                    held: true,
                    existingName: film.name,
                    existingDurationSeconds: film.durationSeconds,
                    existingIsFeature: true
                )
            }
            if !verdict.isHeld, let film = matchingFilm(seconds: seconds, among: films) {
                return LibraryExtraVerdict(
                    titleIndex: verdict.titleIndex,
                    durationSeconds: seconds,
                    held: true,
                    existingName: film.name,
                    existingDurationSeconds: film.durationSeconds,
                    existingIsFeature: true
                )
            }
            return LibraryExtraVerdict(
                titleIndex: verdict.titleIndex,
                durationSeconds: seconds,
                held: verdict.isHeld,
                existingFolder: verdict.existing?.folderName,
                existingName: verdict.existing?.file.name,
                existingDurationSeconds: verdict.existing?.file.durationSeconds
            )
        }
    }

    /// The film file whose runtime matches this title, if any.
    ///
    /// #0221 — kept as a second chance, not the main one. `LibraryProbe` does
    /// not measure library films, so in production this finds nothing; it still
    /// earns its place for a caller that *has* durations (the corpus tests do)
    /// and for a disc whose scan named no main feature.
    ///
    /// Reuses `LibraryExtras`' own tolerance rather than inventing a second
    /// one — a feature and an extra are the same kind of comparison, and two
    /// answers to "do these runtimes match" is how reports start disagreeing.
    static func matchingFilm(seconds: Int, among films: [LibraryFile]) -> LibraryFile? {
        guard seconds > 0 else { return nil }
        return films.first { file in
            guard let filed = file.durationSeconds, filed > 0 else { return false }
            return LibraryExtras.isSameRuntime(filed, seconds)
        }
    }
}
