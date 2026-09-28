import Foundation

/// #0160 — which film the user has named for each feature on a disc that
/// holds more than one.
///
/// #0157 taught the app to *recognise* such a disc
/// (`DiscTitleHeuristic.multipleFeatures`, measured on Get Hard / The
/// Campaign and on Uncle Buck / The Great Outdoors). Everything downstream of
/// the recognition was still singular — one search term, one
/// `selectedMovieID`, one `RipRequest` — so the Uncle Buck disc prefilled the
/// search box with the whole volume label, "Uncle Buck Great Outdoors", which
/// returns nothing on TMDB and reads as a broken app rather than as a
/// question.
///
/// This is the state that makes the question askable once per film: a title
/// index per feature, and the movie id the user chose for it. Nothing here
/// guesses — on a disc with several films the app knows *how many* and not
/// *which is which*, and choosing would be a guess dressed as an answer.
///
/// Pure, `nonisolated` and made of plain integers, like `SelectionReset` and
/// `StartGate`, so the whole decision is unit-testable with no view model, no
/// disc and no view — the only coverage available here, since UI tests are
/// forbidden in this project (`docs/ui-test-crash-prevention.md`).
nonisolated struct FeatureSelection: Equatable, Sendable {

    /// The feature titles this disc holds, in disc order — the order the
    /// table the user reads is in.
    ///
    /// **Empty on an ordinary single-feature disc**, which is by far the
    /// common case. Every question below answers "no" for it, which is what
    /// keeps the single-selection path exactly as it was.
    private(set) var features: [Int] = []

    /// The film named for each feature: disc title index → TMDB movie id.
    /// Only ever holds keys that are in `features`.
    private(set) var choices: [Int: Int] = [:]

    /// The feature Start will rip.
    ///
    /// One job at a time is still the rule — `DVDPipeline` encodes one title
    /// (#0014) and a `RipRequest` carries one `MovieMetadata` — so a
    /// multi-feature disc is ripped one film per pass. **This is the seam for
    /// a second job:** every feature the user has identified stays in
    /// `choices`, so a later ticket can start the next one without asking
    /// again (`waitingFeatures` is that list). Queueing is deliberately not
    /// built here.
    private(set) var active: Int?

    /// Whether this disc needs a film named per feature at all.
    var isMultiFeature: Bool { features.count >= 2 }

    /// How many features have a film against them.
    var chosenCount: Int { choices.count }

    /// The film named for one feature, if any.
    func movieID(for feature: Int) -> Int? { choices[feature] }

    /// The film Start will rip, if one has been named.
    var activeMovieID: Int? { active.flatMap { choices[$0] } }

    /// Features the user has already identified that this pass will *not*
    /// rip — what a queue would read next. Nothing consumes it yet; it exists
    /// so the state a second job needs is already being kept correctly rather
    /// than discovered to be missing later.
    var waitingFeatures: [Int] {
        features.filter { $0 != active && choices[$0] != nil }
    }

    /// What `StartGate.decide` needs to refuse with a reason that names what
    /// is missing.
    var gateInput: FeatureChoices {
        FeatureChoices(featureCount: features.count, chosenCount: choices.count)
    }

    /// The feature titles an outcome names, in disc order. `[]` for every
    /// other outcome — a single-feature disc has no per-feature state at all,
    /// and that is what this type's "empty" means.
    static func features(in outcome: DiscTitleHeuristic.Outcome?) -> [Int] {
        guard case .multipleFeatures(let indices) = outcome else { return [] }
        return indices
    }

    /// Adopt the features a scan just reported.
    ///
    /// A choice for a title the disc no longer has is not a choice: re-scan a
    /// disc, or swap one in whose features land on different indices, and the
    /// stale picks go. Same reasoning as #0034's `SelectionReset` — a film
    /// chosen against one thing must never be filed against another.
    mutating func setFeatures(_ indices: [Int]) {
        guard indices != features else { return }
        features = indices
        choices = choices.filter { indices.contains($0.key) }
        if let active, !indices.contains(active) { self.active = nil }
        if active == nil { active = lowestChosen }
    }

    /// Name a film for one feature, or clear it with `nil`.
    ///
    /// Choosing makes that feature the one Start rips: the click is the user
    /// saying "this one", and on a disc where nothing is preselected there is
    /// no other event that could mean it.
    mutating func choose(movieID: Int?, for feature: Int) {
        guard features.contains(feature) else { return }
        if let movieID {
            choices[feature] = movieID
            active = feature
        } else {
            choices.removeValue(forKey: feature)
            // Clearing the film Start was going to rip falls back to another
            // one the user has already named, rather than to nothing: they
            // have said what that disc holds, and Start should not go dead
            // because they changed their mind about which to do first.
            if active == feature { active = lowestChosen }
        }
    }

    /// "Rip this one first" — an explicit switch between two films that have
    /// both been named. Ignored for a feature with no film against it, so the
    /// active feature always has one.
    mutating func makeActive(_ feature: Int) {
        guard choices[feature] != nil else { return }
        active = feature
    }

    private var lowestChosen: Int? {
        features.first { choices[$0] != nil }
    }
}
