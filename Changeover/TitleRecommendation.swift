import Foundation

/// Which title to suggest when the disc offers several plausible features,
/// and how strongly to suggest it.
///
/// `DiscTitleHeuristic` answers a narrower question — is there exactly one
/// title this can only be? — and correctly gives up when a disc has three
/// ~90-minute titles. Giving up leaves a person staring at rows that differ
/// by a minute with nothing to choose on. Identity, 2026-09-24: titles 1
/// (1:29:57), 2 (1:31:04) and 3 (1:29:57, pan-and-scan).
///
/// The distinction this type draws is the one that was asked for: a
/// **recommendation** is not a selection. When the evidence is decisive the
/// app may pick; when it merely leans, it should say which row it would
/// choose and why, and let the person agree. Those are different promises and
/// conflating them is how a 2:26 trailer got ripped.
nonisolated enum TitleRecommendation {

    nonisolated enum Strength: Equatable, Sendable {
        /// Safe to select without asking.
        case certain
        /// Say which, say why, let the person confirm.
        case leaning
    }

    nonisolated struct Suggestion: Equatable, Sendable {
        let index: Int
        let strength: Strength
        /// One clause, in the words of the evidence — shown in the UI, so it
        /// has to mean something to somebody who has never read this file.
        let reason: String
    }

    /// Titles below this are never the feature: menu loops, logos, warnings,
    /// and the 2:26 trailer HandBrake once called the main feature.
    static let implausiblyShortSeconds = 3 * 60

    /// Within this of TMDB's runtime counts as "matches the listing".
    ///
    /// Wider than it looks necessary, because a DVD's feature routinely
    /// differs from the published runtime by a distributor logo or a slightly
    /// different frame count; narrower than `RuntimeCrossCheck`'s tolerance,
    /// because here it is only being used to *rank* titles against each
    /// other, not to accept one outright.
    static let runtimeMatchSeconds = 90

    /// Titles worth showing at all — everything the disc holds, minus the
    /// parts that cannot be a film.
    static func plausible(_ titles: [DiscTitle]) -> [DiscTitle] {
        titles.filter { $0.durationSeconds >= implausiblyShortSeconds }
    }

    /// The suggestion, or `nil` when there is nothing to say.
    ///
    /// - Parameter runtimeSeconds: TMDB's runtime for the chosen film, when
    ///   one has been chosen. This is the discriminator that actually settles
    ///   discs like Identity, and it was being computed and thrown away.
    static func suggest(titles: [DiscTitle], runtimeSeconds: Int?) -> Suggestion? {
        let candidates = DiscTitleHeuristic.widescreenPreferred(plausible(titles))
        guard let first = candidates.first else { return nil }

        // One candidate and nothing to weigh it against: the disc has already
        // answered.
        guard candidates.count > 1 else {
            return Suggestion(index: first.index, strength: .certain,
                              reason: "It's the only part long enough to be the movie")
        }

        // The listing is the only outside fact available, and on a disc whose
        // titles differ by a minute it is decisive where nothing internal is.
        if let runtimeSeconds {
            let byCloseness = candidates
                .map { (title: $0, delta: abs($0.durationSeconds - runtimeSeconds)) }
                .sorted { $0.delta < $1.delta }
            if let best = byCloseness.first, best.delta <= runtimeMatchSeconds {
                let runnerUp = byCloseness.dropFirst().first
                // Decisive only when the next-best is *not* also a match —
                // two titles equally close to the listing is exactly the case
                // where picking one silently would be a guess wearing a
                // certainty badge.
                let isClear = runnerUp.map { $0.delta > runtimeMatchSeconds } ?? true
                return Suggestion(
                    index: best.title.index,
                    strength: isClear ? .certain : .leaning,
                    reason: "Its length matches what this movie should be"
                )
            }
        }

        // No listing, or nothing near it. The longest is the usual answer but
        // never a confident one — a Play All title is longer than the feature
        // and looks exactly like this.
        let longest = candidates.max { $0.durationSeconds < $1.durationSeconds } ?? first
        return Suggestion(index: longest.index, strength: .leaning,
                          reason: "It's the longest part on the disc")
    }
}

extension String {
    /// "Its length matches…" → "its length matches…", so a reason can be
    /// dropped into the middle of a sentence without reading like a title.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
