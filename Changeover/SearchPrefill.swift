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
    static func decide(
        disc: DiscInsertion,
        term: String?,
        query: String,
        alreadyAttemptedFor: DiscInsertion?
    ) -> Action {
        if let alreadyAttemptedFor, SelectionReset.sameDisc(alreadyAttemptedFor, disc) {
            return .skip
        }
        guard let term, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .markAttempted
        }
        return .fill(term)
    }
}
