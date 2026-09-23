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
            // A title that is exactly what the disc says it is settles it,
            // whatever the runtime says: an extended cut is listed at its
            // theatrical length and would otherwise be refused every time.
            if fold(only.title) == fold(searchTerm) {
                return .select(id: only.id, reason: "its title is exactly what the disc says it is")
            }
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

        func matchesRuntime(_ candidate: Candidate) -> Bool {
            guard let minutes = candidate.runtimeMinutes else { return false }
            return withinTolerance(discSeconds: disc, runtimeMinutes: minutes)
        }

        // The title leads; the runtime only separates films the title cannot.
        //
        // It was the other way round, and Wedding Crashers showed why that is
        // wrong: the disc's feature ran 107.7 minutes, the real film runs 119
        // and failed the tolerance, and *Undercover Wedding Crashers* at 101
        // squeaked through — so a different film with a similar name was
        // chosen and the copy already in the library was never looked for.
        //
        // A runtime that disagrees with an exactly-matching title is not
        // evidence of a different film. It is usually an extended or unrated
        // cut, which TMDB lists at its theatrical length; the disc in the
        // drive at the time was literally THE_HANGOVER_EXTENDED_CUT. That
        // happens often enough that treating it as a mismatch would refuse
        // the ordinary case.
        let wantedTitle = fold(searchTerm)
        let exactTitled = candidates.filter { fold($0.title) == wantedTitle }

        if exactTitled.count == 1 {
            return .select(id: exactTitled[0].id, reason: "its title is exactly what the disc says it is")
        }

        if exactTitled.count > 1 {
            // Two films of the same name — a remake, or a short and a
            // feature. Now the runtime is the only thing that can separate
            // them, which is what it is for.
            let matching = exactTitled.filter(matchesRuntime)
            if matching.count == 1 {
                return .select(id: matching[0].id, reason: "its title matches and its runtime fits the disc")
            }
            return .abstain(reason: "\(exactTitled.count) films share that title — pick one")
        }

        // Nothing is titled what the disc says. The runtime alone may still
        // answer, but only when it answers once.
        let matching = candidates.filter(matchesRuntime)
        if matching.count == 1 {
            return .select(id: matching[0].id, reason: "its runtime is the only one that matches the disc")
        }
        if matching.isEmpty {
            return .abstain(reason: "no result's runtime matches the disc")
        }
        return .abstain(reason: "\(matching.count) results are the right length — pick one")
    }

    /// The candidates in the order they should be shown: an exactly-titled
    /// film first, then closest runtime, then the order TMDB gave.
    ///
    /// TMDB ranks by its own popularity, which put a 2021 film above the 2001
    /// one actually in the drive; and runtime alone put *Undercover Wedding
    /// Crashers* above *Wedding Crashers*. A user who disagrees with the
    /// pre-selection should still find the plausible rows at the top.
    ///
    /// Stable: candidates the ordering cannot speak for keep their original
    /// relative order rather than being shuffled by a number that does not
    /// apply to them.
    static func ranked(
        candidates: [Candidate],
        discDurationSeconds: Int?,
        searchTerm: String = ""
    ) -> [Candidate] {
        let wanted = fold(searchTerm)
        if !wanted.isEmpty {
            let exact = candidates.filter { fold($0.title) == wanted }
            let rest = candidates.filter { fold($0.title) != wanted }
            if !exact.isEmpty, !rest.isEmpty {
                return ranked(candidates: exact, discDurationSeconds: discDurationSeconds)
                     + ranked(candidates: rest, discDurationSeconds: discDurationSeconds)
            }
        }
        guard let disc = discDurationSeconds else { return candidates }

        struct Scored {
            var order: Int
            var candidate: Candidate
            var delta: Int
        }
        var scored: [Scored] = []
        for (index, candidate) in candidates.enumerated() {
            guard let minutes = candidate.runtimeMinutes,
                  withinTolerance(discSeconds: disc, runtimeMinutes: minutes) else { continue }
            scored.append(Scored(order: index, candidate: candidate, delta: abs(disc - minutes * 60)))
        }
        scored.sort { left, right in
            left.delta == right.delta ? left.order < right.order : left.delta < right.delta
        }
        let matching: [Candidate] = scored.map { $0.candidate }
        let matchingIDs = Set(matching.map { $0.id })
        return matching + candidates.filter { !matchingIDs.contains($0.id) }
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
