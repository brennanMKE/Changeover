import Foundation

/// #0167 — whether the film named in one block actually fits that block.
///
/// Reported 2026-09-29 on the Uncle Buck / The Great Outdoors disc. The two
/// blocks read "Movie 1 of 2 · 1h 30m" and "Movie 2 of 2 · 1h 40m", and the
/// films were typed into them the other way round:
///
///     Movie 1 of 2 · 1h 30m  (title 1, 90m25s)  <- Uncle Buck (100 min)
///     Movie 2 of 2 · 1h 40m  (title 2, 99m38s)  <- The Great Outdoors (91 min)
///
/// Nothing said a word. The app accepted both, mirrored the active one into
/// the singular selection, and the user only found out at the Confirm step,
/// where the runtime cross-check refused the whole disc with
/// "Title 2 does not match the TMDB runtime (Δ +518s)" — 8.6 minutes, which
/// is The Great Outdoors against the wrong title.
///
/// The user had no way to get it right. A block shows a runtime; knowing that
/// Uncle Buck runs 100 minutes and The Great Outdoors 91 is not something a
/// person should have to bring. So the block says so itself, at the moment of
/// the mistake, and says which block the film belongs in — that is the whole
/// remedy, because with two films the answer is always "the other one".
///
/// Pure, and deliberately the same tolerance as `FeatureMatching`: a film that
/// would not be *assigned* to this title automatically is a film that does not
/// fit it by hand either.
nonisolated enum FeatureFit {

    nonisolated enum Verdict: Equatable, Sendable {
        /// No film named, or no runtime known for it yet — nothing to judge.
        case unknown
        case fits
        /// The named film's runtime does not match this title's.
        /// `betterFeature` is the title on this disc it does match, when
        /// exactly one does, which is the actionable half.
        case mismatch(offByMinutes: Double, betterFeature: Int?)
    }

    /// The same three minutes `FeatureMatching` assigns within.
    static let toleranceMinutes = FeatureMatching.maximumErrorMinutes

    /// Judges one block.
    ///
    /// - Parameters:
    ///   - runtimeMinutes: TMDB's runtime for the film named here.
    ///   - feature: the disc title this block is for.
    ///   - allFeatures: every feature title on the disc, so a mismatch can
    ///     name the block the film belongs in.
    static func judge(
        runtimeMinutes: Int?,
        feature: DiscTitle?,
        allFeatures: [DiscTitle]
    ) -> Verdict {
        guard let runtimeMinutes, let feature else { return .unknown }
        let error = offBy(runtimeMinutes, feature)
        guard error > toleranceMinutes else { return .fits }

        // The one it does fit — but only when exactly one does, because
        // "it belongs in the other box" is only useful advice when there is
        // one other box it could be.
        let fitting = allFeatures.filter { $0.index != feature.index
            && offBy(runtimeMinutes, $0) <= toleranceMinutes }
        return .mismatch(offByMinutes: error,
                         betterFeature: fitting.count == 1 ? fitting[0].index : nil)
    }

    private static func offBy(_ minutes: Int, _ title: DiscTitle) -> Double {
        abs(Double(minutes) - Double(title.durationSeconds) / 60)
    }

    /// What the block says. `nil` when there is nothing to say.
    ///
    /// Names the other block by its *position* ("Movie 1 of 2"), not by its
    /// title index, because the position is what the user is looking at.
    static func wording(
        _ verdict: Verdict,
        positionOfBetterFeature: Int?,
        count: Int
    ) -> Wording? {
        guard case .mismatch(let offBy, _) = verdict else { return nil }
        let rounded = Int(offBy.rounded())
        let detail = "This film runs \(rounded) min from this title's length"
        if let position = positionOfBetterFeature {
            return Wording(
                plain: "This looks like Movie \(position) of \(count), not this one.",
                detail: detail + " — it matches feature \(position) of \(count) instead."
            )
        }
        return Wording(
            plain: "This movie's length doesn't match this part of the disc.",
            detail: detail + " — check this is the right film for it."
        )
    }
}
