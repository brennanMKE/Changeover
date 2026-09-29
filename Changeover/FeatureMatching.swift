import Foundation

/// #0166 — deciding which candidate film goes with which title on the disc.
///
/// Two sources now propose names for a multi-feature disc and neither can
/// choose: `DiscLabelSplit` (#0158) offers every way of cutting the volume
/// label — three for `UNCLE_BUCK_GREAT_OUTDOORS` — and `MultiTitleInference`
/// (#0159) offers what the on-device model read off the menus. Nothing scored
/// them, so both search boxes stayed empty and the user typed both titles by
/// hand.
///
/// The disc scores them itself. It knows how long each feature runs, TMDB
/// knows how long each candidate film runs, and a **one-to-one** assignment
/// between the two is very hard to hit by accident. Measured on the two real
/// double features:
///
///   Uncle Buck / The Great Outdoors
///     "Uncle Buck"      100 min  <-  title 2  99m38s   0.4 min out
///     "Great Outdoors"   91 min  <-  title 1  90m25s   0.6 min out
///     ...and of the label's three possible cuts, only this one produced a
///     TMDB hit for BOTH halves at all.
///
///   Get Hard / The Campaign
///     "Get Hard"        100 min  <-  title 5  100m12s  0.2 min out
///     "The Campaign"     85 min  <-  title 4   85m22s  0.4 min out
///
/// Every correct pairing lands under a minute. That is the whole signal, and
/// it is why this refuses rather than guesses: a proposal that cannot be
/// assigned one-to-one within tolerance is thrown away, because naming the
/// wrong film confidently is the failure this disc already produced once
/// (a wrong film matched Get Hard's runtime to within a minute, #0157).
///
/// Pure: the TMDB lookup happens in the caller and arrives here as
/// `Candidate` values. That keeps the decision testable with the real numbers
/// above and no network.
nonisolated enum FeatureMatching {

    /// A film some source proposed, with the runtime TMDB gives for it.
    nonisolated struct Candidate: Equatable, Sendable {
        /// The term that produced it — what would go in the search box.
        let term: String
        let movieID: Int
        let title: String
        let year: String
        /// TMDB's runtime in whole minutes. A candidate without one cannot be
        /// scored and must not reach here.
        let runtimeMinutes: Int

        init(term: String, movieID: Int, title: String, year: String, runtimeMinutes: Int) {
            self.term = term
            self.movieID = movieID
            self.title = title
            self.year = year
            self.runtimeMinutes = runtimeMinutes
        }
    }

    /// One film placed on one title of the disc.
    nonisolated struct Assignment: Equatable, Sendable {
        let feature: Int
        let candidate: Candidate
        /// How far the film's listed runtime is from the title's, in minutes.
        let errorMinutes: Double
    }

    /// How far one film's listed runtime may sit from the title it is placed
    /// on.
    ///
    /// Three minutes, against measured errors of 0.2 to 0.6. The slack is for
    /// TMDB rounding to whole minutes and for discs that include or omit
    /// studio logos, not for making a doubtful match fit — every correct
    /// pairing measured so far is an order of magnitude inside it.
    static let maximumErrorMinutes: Double = 3

    /// Places every candidate on a different feature, or gives up.
    ///
    /// `nil` unless there is exactly one film for each feature and every
    /// pairing is inside `maximumErrorMinutes`. Partial answers are
    /// deliberately not offered: on a disc where one film is confidently
    /// placed and the other is not, the honest screen is two search boxes with
    /// one filled in — which is the caller's business, from the assignment it
    /// did or did not get.
    static func assign(
        features: [DiscTitle],
        candidates: [Candidate],
        tolerance: Double = maximumErrorMinutes
    ) -> [Assignment]? {
        guard !features.isEmpty, features.count == candidates.count else { return nil }

        // Exhaustive over permutations, which is correct and cheap at the
        // sizes involved: `DiscTitleHeuristic.maximumFeaturesPerDisc` is 4, so
        // the worst case is 24 orderings.
        var best: (total: Double, assignments: [Assignment])?
        for order in permutations(of: Array(candidates.indices)) {
            var total = 0.0
            var assignments: [Assignment] = []
            var fits = true
            for (position, feature) in features.enumerated() {
                let candidate = candidates[order[position]]
                let error = abs(Double(candidate.runtimeMinutes) - Double(feature.durationSeconds) / 60)
                guard error <= tolerance else { fits = false; break }
                total += error
                assignments.append(Assignment(feature: feature.index,
                                              candidate: candidate,
                                              errorMinutes: error))
            }
            guard fits else { continue }
            if best == nil || total < best!.total {
                best = (total, assignments)
            }
        }
        return best?.assignments.sorted { $0.feature < $1.feature }
    }

    /// The best split of a label, judged by whether its parts can be assigned
    /// to the disc's features at all.
    ///
    /// `DiscLabelSplit` offers three cuts of `UNCLE_BUCK_GREAT_OUTDOORS` and
    /// only one of them has a film behind both halves; this is where that is
    /// settled. `lookUp` is the caller's TMDB search — injected so the
    /// decision stays testable with the measured numbers and no network.
    static func bestSplit(
        features: [DiscTitle],
        splits: [[String]],
        lookUp: (String) -> Candidate?
    ) -> [Assignment]? {
        var best: (total: Double, assignments: [Assignment])?
        for split in splits {
            let candidates = split.compactMap(lookUp)
            // A split only counts when every part named a film.
            guard candidates.count == split.count else { continue }
            guard let assignments = assign(features: features, candidates: candidates) else { continue }
            let total = assignments.reduce(0) { $0 + $1.errorMinutes }
            if best == nil || total < best!.total {
                best = (total, assignments)
            }
        }
        return best?.assignments
    }

    /// #0171 — candidate splits from a flat list of titles.
    ///
    /// `bestSplit` takes splits because a volume label can be *cut* several
    /// ways. A model reading the menus does not produce cuts, it produces a
    /// list — and `assign` needs exactly one film per feature, so a list of a
    /// different length is unusable as it stands.
    ///
    /// Equal lengths are the ordinary case and become one split. A longer list
    /// becomes every subset of the right size, which is the honest thing to do
    /// with a surplus: the model has named a film that is not on this disc —
    /// an actor read as a title, a trailer, a bonus feature — and the disc's
    /// own runtimes are what can tell which naming is the spurious one. A
    /// shorter list becomes nothing, because a film is unaccounted for and no
    /// arrangement of too few titles covers the disc.
    ///
    /// Bounded by construction: `MultiTitleInference.maximumTitles` is 8 and
    /// `DiscTitleHeuristic.maximumFeaturesPerDisc` is 4, so the worst case is
    /// the 70 subsets of 8 choose 4 — and every one of them draws on the same
    /// 8 lookups, which the caller caches by term.
    static func splits(from titles: [String], choose count: Int) -> [[String]] {
        guard count > 0, titles.count >= count else { return [] }
        guard titles.count > count else { return [titles] }
        var result: [[String]] = []
        var current: [String] = []
        func walk(_ index: Int) {
            if current.count == count { result.append(current); return }
            guard index < titles.count else { return }
            // Enough left to finish, or there is no point descending.
            guard titles.count - index >= count - current.count else { return }
            current.append(titles[index])
            walk(index + 1)
            current.removeLast()
            walk(index + 1)
        }
        walk(0)
        return result
    }

    /// All orderings of a small array. Written out rather than pulled in
    /// because the only sizes that reach it are 1 to 4.
    private static func permutations(of items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        var result: [[Int]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            for tail in permutations(of: rest) {
                result.append([item] + tail)
            }
        }
        return result
    }
}
