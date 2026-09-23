import Foundation

/// #0062 — where the "already in Plex" check stands for the movie currently
/// selected. File-scope and `nonisolated` for the reason `ScanState` and
/// `StartDecision` are: `StartGate.decide` is a pure function that must take
/// this as a plain value with no actor-isolation crossing.
nonisolated enum LibraryCheck: Equatable, Sendable {
    case idle
    case checking(tmdbID: String)
    case done(tmdbID: String, LibraryLookup)
}

/// #0062 — the user's explicit "yes, replace the copy that is already there",
/// recorded against the one movie *and* the one folder it was shown for.
///
/// Exactly #0032's `MismatchAcknowledgement` shape, and for exactly its
/// reason: a bare `Bool` survives picking a different movie in the results, so
/// a confirmation given for film A would silently enable Start for film B.
/// Keyed this way, `StartGate` only honours it when both still match what is
/// selected now, and `RipFlowController` clears it on every event that changes
/// what it was given for.
nonisolated struct ReplaceAcknowledgement: Equatable, Sendable {
    let movieID: Int
    /// The matched folder as it is on disk — not `MovieMetadata.folderName`,
    /// which is where the *new* file will go. A copy filed under an older
    /// title is a different folder, and confirming one must not confirm
    /// another.
    let folderPath: String
}

/// #0062 — what re-runs the probe. A `Hashable` pair, so `ConfirmStepView`'s
/// `.task(id:)` re-fires exactly when the movie or the library root changes,
/// and never on an unrelated redraw.
nonisolated struct LibraryCheckKey: Hashable, Sendable {
    let movieID: Int
    let moviesPath: String
    /// Bumped whenever something has happened that could change the answer —
    /// in practice, a rip finishing.
    ///
    /// Without it the key is (film, folder), neither of which changes when a
    /// rip completes, so `ConfirmStepView.task(id:)` never re-ran and the
    /// notice kept saying what it had found *before* the encode. A disc that
    /// then lingered in the drive looked like a fresh one: on 2026-09-23 Die
    /// Hard finished, failed to eject, and was ripped again ten seconds
    /// later, with the duplicate guard holding a stale "not in the library".
    var epoch: Int = 0
}

/// #0062 — the notice on the Confirm step, as plain values.
nonisolated struct DuplicateNotice: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case checking
        case present
        case acknowledged
        case unreachable
    }

    let kind: Kind
    let headline: String
    /// Per matched file: "name · size · added date"; then the folder path;
    /// then the sentence saying what ripping again will do.
    let lines: [String]
    /// `docs/plain-language-ui.md` §3.7 — the same notice in one short
    /// sentence, with no path, no byte count and no folder name. `headline`
    /// and `lines` above are kept verbatim as the detail.
    let plainHeadline: String
    let plainLines: [String]
    let tone: JobPresentation.Tone
    /// `present && !acknowledged` — the one click that unblocks Start.
    let offersReplace: Bool
    /// `unreachable` — re-runs the probe.
    let offersRecheck: Bool
    /// The first matched folder, for "Reveal in Finder".
    let revealPath: String?
}

/// #0062 — the pure function behind `DuplicateNoticeView`. No filesystem, no
/// SwiftUI: this is the only coverage the Confirm step's new panel can have.
nonisolated enum DuplicatePresentation {

    /// `nil` when there is nothing to say — `.idle`, a check for a *different*
    /// movie than the one on screen, and a completed check that found nothing.
    /// The common case (a film that is not in the library) costs the user no
    /// pixels and no clicks at all.
    static func notice(
        check: LibraryCheck,
        acknowledgement: ReplaceAcknowledgement?,
        metadata: MovieMetadata,
        now: Date
    ) -> DuplicateNotice? {
        switch check {
        case .idle:
            return nil

        case .checking(let tmdbID):
            guard tmdbID == metadata.tmdbID else { return nil }
            return DuplicateNotice(
                kind: .checking,
                headline: "Checking the Plex library…",
                lines: [],
                plainHeadline: "Checking whether this movie is already in Plex…",
                plainLines: [],
                tone: .neutral,
                offersReplace: false,
                offersRecheck: false,
                revealPath: nil
            )

        case .done(let tmdbID, let lookup):
            guard tmdbID == metadata.tmdbID else { return nil }
            switch lookup {
            case .absent:
                return nil
            case .unreachable(let reason):
                return DuplicateNotice(
                    kind: .unreachable,
                    headline: "Couldn't check the Plex library: \(reason)",
                    lines: ["If this movie is already there, it will be replaced."],
                    plainHeadline: "Couldn't check whether this movie is already in Plex.",
                    plainLines: ["If it is, it will be replaced."],
                    tone: .neutral,
                    offersReplace: false,
                    offersRecheck: true,
                    revealPath: nil
                )
            case .present(let entries):
                return presentNotice(entries: entries, acknowledgement: acknowledgement, metadata: metadata, now: now)
            }
        }
    }

    // MARK: - The duplicate itself

    private static func presentNotice(
        entries: [LibraryEntry],
        acknowledgement: ReplaceAcknowledgement?,
        metadata: MovieMetadata,
        now: Date
    ) -> DuplicateNotice {
        let fileLines = entries.flatMap { entry in entry.files.map { fileLine($0, now: now) } }
        let first = entries[0]
        let isAcknowledged = acknowledgement == ReplaceAcknowledgement(
            movieID: Int(metadata.tmdbID) ?? -1,
            folderPath: first.folderPath
        )

        if isAcknowledged {
            let single = entries.count == 1 && first.files.count == 1
            return DuplicateNotice(
                kind: .acknowledged,
                headline: single ? "Will replace \(fileLines[0])" : "Will replace the existing copy in Plex",
                lines: single ? [first.folderPath] : fileLines + [first.folderPath],
                plainHeadline: "OK — the existing copy will be replaced.",
                plainLines: [],
                tone: .success,
                offersReplace: false,
                offersRecheck: false,
                revealPath: first.folderPath
            )
        }

        var lines = fileLines
        lines.append(first.folderPath)

        let headline: String
        let plainHeadline: String
        var plainLines: [String] = []
        if entries.count > 1 {
            headline = "Already in Plex — \(entries.count) folders carry \(LibraryMatch.tag(for: metadata.tmdbID))"
            lines.append("Ripping again replaces the file in \(first.folderName) once the new encode succeeds.")
            plainHeadline = "This movie is in Plex more than once."
            plainLines.append("Ripping it again will replace one of the copies.")
        } else if first.folderName != metadata.folderName {
            headline = "Already in Plex, as “\(first.folderName)”"
            lines.append("The new file will be filed as \(metadata.folderName); the old folder is left in place.")
            plainHeadline = "This movie is already in Plex under a different name."
            plainLines.append("The new copy will be added alongside it.")
        } else {
            headline = "Already in Plex"
            lines.append("Ripping again replaces this file once the new encode succeeds.")
            plainHeadline = "This movie is already in Plex."
            // The date is the one fact on the file line that tells the person
            // whether the copy they have is the one they remember.
            let added = first.files.compactMap(\.modified).first
            let when = added.map { " (added \(formatDate($0, now: now)))" } ?? ""
            plainLines.append("Ripping it again will replace the copy that's there\(when).")
        }

        return DuplicateNotice(
            kind: .present,
            headline: headline,
            lines: lines,
            plainHeadline: plainHeadline,
            plainLines: plainLines,
            tone: .warning,
            offersReplace: true,
            offersRecheck: false,
            revealPath: first.folderPath
        )
    }

    // MARK: - Formatting (deliberately locale-independent, so tests can pin it)

    /// "Air (2023).mp4 · 1.42 GB · added Sep 3, 2026"
    static func fileLine(_ file: LibraryFile, now: Date) -> String {
        var parts = [file.name]
        if let bytes = file.sizeBytes { parts.append(formatBytes(bytes)) }
        if let modified = file.modified { parts.append("added \(formatDate(modified, now: now))") }
        return parts.joined(separator: " · ")
    }

    /// `%f` formats against the C locale, so the separator is always a period
    /// — the same reason `JobPresentation.formatElapsed` builds its own
    /// string rather than reaching for `DateComponentsFormatter`.
    static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2f KB", value / 1_000) }
        return "\(bytes) bytes"
    }

    /// The year is dropped when the file landed this year — the wireframe's
    /// "added Sep 3" — and kept otherwise, so an old copy always says so.
    static func formatDate(_ date: Date, now: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
