import Foundation

/// #0161 — whether each film on a multi-feature disc is already in Plex.
///
/// The "already in Plex" probe has only ever run from the Confirm step's
/// `.task(id:)`, against the one selected movie. On a disc holding several
/// films that is too late and too narrow: the user is being asked to name two
/// films by hand, and the single most useful thing the app could tell them is
/// "you already have both of these". Instead they named a film, pressed
/// Continue, and only then learned about the one they had made active — the
/// second film's status never appeared anywhere at all.
///
/// Reported on the Uncle Buck / The Great Outdoors disc, 2026-09-27, with both
/// films already in the library as `{tmdb-2616}` and `{tmdb-2617}`: "I am
/// pretty sure both movies are imported yet the app does not show that."
///
/// Pure: the probe itself is `LibraryProbe`, unchanged, and the matching is
/// `LibraryMatch`, unchanged. What was missing is a per-feature trigger and
/// something to say, which is all this file is.
nonisolated enum FeatureLibraryStatus {

    /// Where one feature's library check stands.
    nonisolated enum State: Equatable, Sendable {
        /// No film named for this feature yet, so there is nothing to ask.
        case noFilmNamed
        case checking
        /// Checked, and the library does not have it.
        case absent
        /// Checked, and a copy is already there.
        case present(file: String?, size: String?)
        /// The library could not be read. Never collapsed into `absent`: "not
        /// there" may only be said after a successful listing (#0143).
        case unreadable(reason: String)
    }

    /// The marker beside one feature's block. `nil` when there is nothing
    /// worth saying — no film named yet, or a check still in flight that has
    /// not been waiting long enough to be worth a spinner's worth of noise.
    static func badge(for state: State) -> String? {
        switch state {
        case .noFilmNamed:            return nil
        case .checking:               return "Checking Plex…"
        case .absent:                 return nil
        case .present(let file, let size):
            let detail = [file, size].compactMap { $0 }.joined(separator: " · ")
            return detail.isEmpty ? "Already in Plex" : "Already in Plex · \(detail)"
        case .unreadable:             return "Could not read the Plex library"
        }
    }

    /// The one line at the top of the disc, said only when it is true of
    /// **every** feature — that is the point at which the honest
    /// recommendation is to take the disc out.
    ///
    /// Deliberately not an eject: the duplicate auto-eject stays suppressed on
    /// a multi-feature disc, because throwing out a disc whose *other* film
    /// the user does not have is the worse mistake. This says what is true and
    /// leaves the decision alone.
    static func everyFeatureNotice(_ states: [State]) -> String? {
        guard states.count >= 2 else { return nil }
        guard states.allSatisfy({ if case .present = $0 { return true } else { return false } })
        else { return nil }
        return "Both films on this disc are already in Plex."
            .replacingOccurrences(of: "Both", with: states.count == 2 ? "Both" : "All \(states.count)")
    }

    /// Plain-language sibling of `everyFeatureNotice`, for the register the
    /// window uses when details are switched off.
    static func plainEveryFeatureNotice(_ states: [State]) -> String? {
        guard everyFeatureNotice(states) != nil else { return nil }
        return states.count == 2
            ? "You already have both of these movies."
            : "You already have all \(states.count) of these movies."
    }

    /// Turns a completed `LibraryCheck` into this feature's state. The
    /// translation lives here so the view never reads `LibraryLookup` cases.
    static func state(from check: LibraryCheck, hasFilm: Bool) -> State {
        guard hasFilm else { return .noFilmNamed }
        switch check {
        case .idle:                       return .checking
        case .checking:                   return .checking
        case .done(_, .absent):           return .absent
        case .done(_, .unreachable(let reason)): return .unreadable(reason: reason)
        case .done(_, .present(let entries)):
            let file = entries.first(where: { !$0.files.isEmpty })?.files.first
            return .present(file: file?.name,
                            size: EjectExplanation.formatSize(file?.sizeBytes))
        }
    }
}
