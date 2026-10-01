import Foundation

/// #0174 — the substantial bonus feature on a single-film disc.
///
/// #0173 taught `DiscTitleHeuristic` to stop calling Signs' 58:54 bonus reel a
/// second film: a second *feature* is comparable in length to the first, and
/// 0.553 is not. But it then threw that title away, which is a waste of the
/// one thing the disc was certain about. The title is still there, still over
/// the 45-minute floor, and still worth importing — it is just not a film.
///
/// This is the other half of that judgement. The same comparison that refuses
/// a title as a second feature nominates it as a bonus feature, so one rule
/// produces both answers and they cannot disagree.
///
/// Deliberately narrow. The disc has dozens of short titles — Signs has
/// fifteen under ten minutes — and this is not a general extras picker
/// (`ExtrasPlan` is, and the user ticks those by hand). It names the ones big
/// enough that nobody would want them silently dropped: the making-of, the
/// commentary reel, the bonus disc's play-all.
nonisolated enum BonusFeature {

    /// How long a title must run to count as a bonus *feature* rather than an
    /// ordinary extra.
    ///
    /// The same 45 minutes `DiscTitleHeuristic.featureMinimumSeconds` uses,
    /// and for the same reason: this exists precisely for titles that clear
    /// the feature floor and are not films. A shorter one is an extra and
    /// belongs to the user's own selection, not to an automatic rule.
    static let minimumSeconds = DiscTitleHeuristic.featureMinimumSeconds

    /// Titles that clear the feature floor but are too short, against the
    /// film, to be a second feature.
    ///
    /// - Parameters:
    ///   - disc: the scan.
    ///   - featureIndex: the title the app settled on as the film. Never a
    ///     bonus feature itself.
    ///
    /// Measured on Signs (`vol-signs-8224851968`, 2026-10-01): title 1 is the
    /// film at 1:46:25 and title 8 is the bonus reel at 58:54 — 0.553 of the
    /// film, under `minimumSecondFeatureRatio`, so #0173 refuses it as a
    /// second film and this nominates it instead.
    static func candidates(in disc: DiscInfo, featureIndex: Int) -> [DiscTitle] {
        guard let feature = disc.titles.first(where: { $0.index == featureIndex }),
              feature.durationSeconds > 0
        else { return [] }

        return disc.titles
            .filter { $0.index != featureIndex }
            .filter { $0.durationSeconds >= minimumSeconds }
            // Shorter than a second feature would be — which is exactly what
            // makes it a bonus feature rather than a film the app missed.
            // A title that IS long enough is `DiscTitleHeuristic`'s business,
            // and this must never quietly re-file a film as an extra.
            .filter { Double($0.durationSeconds) / Double(feature.durationSeconds)
                        < DiscTitleHeuristic.minimumSecondFeatureRatio }
            .sorted { $0.index < $1.index }
    }
}
