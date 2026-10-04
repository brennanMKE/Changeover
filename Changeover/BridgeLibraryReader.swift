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
        discTitles: [DiscTitle]
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
                    : verdicts(forTitles: discTitles, against: extras)
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
    static func verdicts(
        forTitles titles: [DiscTitle],
        against extras: [LibraryExtraFile]
    ) -> [LibraryExtraVerdict] {
        let byIndex = Dictionary(
            titles.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return LibraryExtras.verdicts(forTitles: titles, against: extras).map { verdict in
            LibraryExtraVerdict(
                titleIndex: verdict.titleIndex,
                durationSeconds: byIndex[verdict.titleIndex]?.durationSeconds ?? 0,
                held: verdict.isHeld,
                existingFolder: verdict.existing?.folderName,
                existingName: verdict.existing?.file.name,
                existingDurationSeconds: verdict.existing?.file.durationSeconds
            )
        }
    }
}
