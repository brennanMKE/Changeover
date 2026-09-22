import Foundation

/// Which of the search results is this disc, when the disc can say.
///
/// Searching "Enemy at the Gates" returns three films: the 2001 one that is
/// actually in the drive, a 2021 film of the same name, and a 2025
/// documentary. The titles are identical or nearly so, so the title cannot
/// separate them — but the disc's feature runs 131 minutes and the others do
/// not, and the disc's runtime comes from the disc rather than from anything
/// TMDB said. That is the whole idea: **the disc picks, not the model.**
///
/// A selected result decides the Plex folder, the file name and the
/// `{tmdb-ID}` the library is keyed on, so this is the most consequential
/// thing in the search step and it is deliberately the least clever. It
/// abstains whenever the evidence is thin, and abstaining costs one click.
nonisolated enum MovieAutoSelect {

    /// How many results are worth a details lookup.
    ///
    /// TMDB's search endpoint never returns runtime, so each candidate costs
    /// a request. Past a handful of results the title was too vague for a
    /// pre-selection to be trustworthy anyway, so the cap costs nothing real.
    static let maximumLookups = 6

    /// One candidate: what TMDB said, plus its runtime once looked up.
    nonisolated struct Candidate: Equatable, Sendable {
        var id: Int
        var title: String
        /// `nil` when TMDB has no runtime for it, which is a real answer and
        /// not a zero — a film with no runtime can never be chosen on
        /// runtime, and must not be treated as infinitely far away either.
        var runtimeMinutes: Int?

        init(id: Int, title: String, runtimeMinutes: Int?) {
            self.id = id
            self.title = title
            self.runtimeMinutes = runtimeMinutes
        }
    }

    enum Decision: Equatable, Sendable {
        /// Pre-select this row. Still a pre-selection: the list stays open
        /// and every other result is one click away.
        case select(id: Int, reason: String)
        /// Leave it to the user, and say why nothing was chosen.
        case abstain(reason: String)

        var selectedID: Int? {
            if case .select(let id, _) = self { return id }
            return nil
        }
    }

    /// Fold a title for comparison: case, punctuation and spacing are noise;
    /// the words are not.
    static func fold(_ text: String) -> String {
        MenuArchive.fold(text)
    }

    /// The decision.
    ///
    /// - Parameters:
    ///   - candidates: the search results, in the order shown.
    ///   - discDurationSeconds: the **feature title's** duration from the
    ///     scan, not the disc's longest title — an extras-heavy disc would
    ///     otherwise be measured against a documentary.
    ///   - searchTerm: what was searched, for the exact-title rule.
    static func decide(
        candidates: [Candidate],
        discDurationSeconds: Int?,
        searchTerm: String
    ) -> Decision {
        guard !candidates.isEmpty else { return .abstain(reason: "no results") }

        // One result is not a choice. Still requires the runtime to agree
        // when both numbers exist — a single wrong result is exactly the
        // case where a confident pre-selection does the most harm.
        if candidates.count == 1 {
            let only = candidates[0]
            guard let disc = discDurationSeconds, let minutes = only.runtimeMinutes else {
                return .select(id: only.id, reason: "the only result")
            }
            return withinTolerance(discSeconds: disc, runtimeMinutes: minutes)
                ? .select(id: only.id, reason: "the only result, and its runtime matches the disc")
                : .abstain(reason: "the only result runs \(minutes) minutes and the disc runs \(disc / 60)")
        }

        guard let disc = discDurationSeconds else {
            return .abstain(reason: "the disc's runtime is not known yet")
        }

        let matching = candidates.filter { candidate in
            guard let minutes = candidate.runtimeMinutes else { return false }
            return withinTolerance(discSeconds: disc, runtimeMinutes: minutes)
        }

        if matching.count == 1 {
            return .select(id: matching[0].id, reason: "its runtime is the only one that matches the disc")
        }
        if matching.isEmpty {
            return .abstain(reason: "no result's runtime matches the disc")
        }

        // Several within tolerance: two cuts of the same film, or a remake
        // of similar length. The title breaks the tie only when it is exact,
        // and only when exactly one is.
        let wanted = fold(searchTerm)
        let exact = matching.filter { fold($0.title) == wanted }
        if exact.count == 1 {
            return .select(id: exact[0].id, reason: "its title and runtime both match")
        }

        return .abstain(reason: "\(matching.count) results are the right length — pick one")
    }

    /// The same tolerance the cross-check uses, for the same reason: a PAL
    /// transfer runs about 4% fast, so anything tighter rejects correct
    /// matches on perfectly ordinary discs.
    static func withinTolerance(discSeconds: Int, runtimeMinutes: Int) -> Bool {
        let expected = runtimeMinutes * 60
        let allowed = expected * RuntimeCrossCheck.tolerancePercent / 100 + RuntimeCrossCheck.slackSeconds
        return abs(discSeconds - expected) <= allowed
    }
}
