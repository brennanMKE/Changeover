import Foundation

// The "should this disc arrival prefill the search field?" decision, pure
// and separate from `DiscNameSearchTerm.derive` — that function only asks
// whether a volume name *is* a usable term; this one asks whether *this
// moment* is the right one to use it, given what the user has already done.
//
// Mirrors `SelectionReset.reconcile`'s shape (an `Action` the caller applies)
// for the same reason: the decision is unit-testable with plain
// `DiscInsertion` values and no `RipFlowController`, no view.
nonisolated enum SearchPrefill {

    /// What `RipFlowController.reconcile` should do about the search field
    /// for the disc now in the drive.
    nonisolated enum Action: Equatable, Sendable {
        /// Already attempted for this disc (by identity, `SelectionReset
        /// .sameDisc`) — do nothing, not even re-check the field. This is
        /// what makes "the user cleared the field" stick: clearing it is a
        /// deliberate no, not "the derive step hasn't run yet".
        case skip
        /// A disc arrival not yet attempted, but there's nothing to fill —
        /// no usable term, or the user already has text in the field. Still
        /// recorded as attempted, so a term becoming derivable some other
        /// way (there isn't one today) can't retroactively fill a field the
        /// user has since typed into.
        case markAttempted
        /// A disc arrival not yet attempted, a usable term, and a blank
        /// field: fill it and run the search.
        case fill(String)
    }

    /// - Parameters:
    ///   - disc: the disc now in the drive.
    ///   - term: `DiscNameSearchTerm.derive(volumeName:)` for `disc`.
    ///   - query: the search field's current text.
    ///   - alreadyAttemptedFor: the disc (if any) a prefill was already
    ///     attempted for — `RipFlowController`'s own record, so a repeated
    ///     `reconcile` call for the same disc (e.g. a job starting/finishing
    ///     with nothing else changing) is a no-op.
    ///   - featureCount: how many feature films the scan found on this disc
    ///     (`DiscTitleHeuristic.multipleFeatures`). One — or none, before the
    ///     scan has answered — is the ordinary disc, and the default, so
    ///     every existing caller keeps its behaviour.
    static func decide(
        disc: DiscInsertion,
        term: String?,
        query: String,
        alreadyAttemptedFor: DiscInsertion?,
        featureCount: Int = 1
    ) -> Action {
        if let alreadyAttemptedFor, SelectionReset.sameDisc(alreadyAttemptedFor, disc) {
            return .skip
        }
        guard mayUseWholeLabel(featureCount: featureCount) else {
            return .markAttempted
        }
        guard let term, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .markAttempted
        }
        return .fill(term)
    }

    /// #0160 — whether the volume label may be offered as **one** search
    /// term for this disc.
    ///
    /// On a disc holding several films the label names them all at once.
    /// `UNCLE_BUCK_GREAT_OUTDOORS` derives the term "Uncle Buck Great
    /// Outdoors", which matches no film on TMDB: the box fills itself with
    /// something that finds nothing, and an app that puts a wrong answer in
    /// front of someone is worse than one that puts none. A blank box is
    /// honest here — the screen is asking them to name each film, and
    /// nothing the app holds is a term for any *one* of them.
    ///
    /// Splitting a label into per-film candidates is a separate piece of
    /// work (`DiscLabelSplit`), deliberately not attempted here: this
    /// function only refuses the concatenation.
    static func mayUseWholeLabel(featureCount: Int) -> Bool {
        featureCount < 2
    }
}
