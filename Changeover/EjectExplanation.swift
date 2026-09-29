import Foundation

/// #0153 — why the app took a disc out, when the answer is not "your rip
/// finished".
///
/// The app ejects on its own in two situations. One is the end of a successful
/// import, and the Done step already explains that at length. The other is a
/// disc it decided not to rip at all — and that one said nothing whatsoever.
///
/// Observed on joe, 2026-09-26: two discs in ten minutes were identified,
/// found in the Plex library, and ejected. Both times the only record was a
/// line in `flow.log`, which is `FlowDiagnostics` — a debug file. Nothing
/// reached the window, the log the user can read, or a notification. The tray
/// simply opened. The user asked twice what had happened, and the second disc
/// (Knowing) sent them looking for a bug in Changeover when the real fault was
/// a bad match in Plex's own database: the file *was* on the volume, correctly
/// named and tagged, so the eject was right and unexplained at the same time.
///
/// That is the cost of a silent automatic action. It is not that the decision
/// was wrong — it is that a correct decision with no stated reason is
/// indistinguishable from a malfunction, so it burns the user's trust and
/// their afternoon.
///
/// Pure, `Codable` and `Equatable` because it rides on `FlowStep`, which a
/// Phase 4 client derives from the same inputs.
nonisolated struct EjectExplanation: Equatable, Sendable, Codable {

    /// Why the disc came out. `String`-raw so an older decoder meets a known
    /// shape, and so a case added later is a decoding error rather than a
    /// silently wrong sentence.
    nonisolated enum Cause: String, Equatable, Sendable, Codable, CaseIterable {
        /// The film is already in the Plex library and the user had not ticked
        /// "Replace the Existing File". Unattended, this is the one outcome
        /// that would otherwise park a disc forever waiting for a decision
        /// nobody is there to make.
        case alreadyInPlex
        /// #0168 — a disc holding several films, every one of which the
        /// library already has. Distinct from `alreadyInPlex`, which is about
        /// one film: here the disc is finished with as a whole, and the
        /// explanation has to name each film or it does not account for the
        /// disc.
        case everyFilmAlreadyInPlex
    }

    var cause: Cause
    /// How the film was named on screen, e.g. `Knowing (2009)`. Optional
    /// because the sentence must still read if identification is somehow gone
    /// by the time this is shown.
    var movie: String?
    /// The library file the decision was made against, e.g.
    /// `Knowing (2009).mp4` — named so the user can go and look at the actual
    /// evidence rather than take the app's word for it.
    var existingFile: String?
    /// That file's size, already formatted.
    var existingSize: String?
    /// #0168 — every film on the disc, in disc order, when the whole disc was
    /// already held. The report has to account for all of them.
    var films: [String] = []

    init(cause: Cause, movie: String? = nil, existingFile: String? = nil,
         existingSize: String? = nil, films: [String] = []) {
        self.cause = cause
        self.movie = movie
        self.existingFile = existingFile
        self.existingSize = existingSize
        self.films = films
    }

    // MARK: - What the screen says

    /// The headline. Names the film when it is known, because "a disc" is not
    /// what the user is trying to identify.
    var headline: String {
        switch cause {
        case .alreadyInPlex:
            guard let movie else { return "Ejected — that film is already in Plex" }
            return "Ejected — \(movie) is already in Plex"
        case .everyFilmAlreadyInPlex:
            let n = films.count
            return n == 2
                ? "Ejected — both films on this disc are already in Plex"
                : "Ejected — all \(n) films on this disc are already in Plex"
        }
    }

    /// The body: what the app found, and *where*, so the claim is checkable.
    var detail: String {
        switch cause {
        case .alreadyInPlex:
            let file = [existingFile, existingSize]
                .compactMap { $0 }
                .joined(separator: " · ")
            let where_ = file.isEmpty ? "in your Plex movies folder" : "in your Plex movies folder as \(file)"
            return "A copy is already \(where_), so the disc was not ripped "
                + "and the drive was freed for the next one."
        case .everyFilmAlreadyInPlex:
            // Names every film, because "both are already there" without
            // saying which is exactly the report that cannot be checked.
            return films.map { "\($0) — already in Plex" }.joined(separator: "\n")
                + "\nNothing was ripped, and the disc was ejected for the next one."
        }
    }

    /// What to do if the app got it wrong. This exists because on the first
    /// two occurrences the user's reasonable conclusion was "the app is
    /// broken" — and the honest advice is that a file on the volume and a film
    /// visible in Plex are two different things, which is exactly how Knowing
    /// went missing while its file sat in the right folder.
    var advice: String {
        switch cause {
        case .alreadyInPlex:
            return "To rip it anyway, put the disc back in and tick "
                + "“Replace the Existing File”. If Plex does not list the film, "
                + "the file is there but Plex has matched it to something else."
        case .everyFilmAlreadyInPlex:
            return "To rip one of them anyway, put the disc back in and tick "
                + "“Replace the Existing File” for that film."
        }
    }

    /// One line for the visible log, where the whole failure was that nothing
    /// was written anywhere the user could see.
    var logLine: String {
        "⏏ " + headline.replacingOccurrences(of: "Ejected — ", with: "Ejected: ")
    }

    /// Bytes as a short human string. Static and pure so the view never
    /// formats anything itself.
    static func formatSize(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
