import Foundation

/// #0026 — the single decision behind the Start button's enabled state,
/// pulled out as a pure function (per `Plan.md`'s "put every decision behind
/// a pure, plain-value seam") so it's testable with no SwiftUI, no
/// `JobController`, and no disc, and so the same predicate can gate a
/// Phase 4 `startRip` command (`RemoteControl.md` lines 456-458) the way
/// the button's own disable-state gates it locally today.
///
/// Deliberately duplicates none of `JobController.start`'s own refusal
/// logic. This exists to disable the button *before* the user presses it;
/// `start` keeps its own guards as the failsafe if this is ever wrong or
/// bypassed — the pattern #0034 established for the disc-identity guard.
nonisolated enum StartGate {
    /// - Parameters:
    ///   - hasMovieSelected: `vm.selectedMovie != nil`.
    ///   - isRunning: a job must not be started on top of another.
    ///   - hasDisc: a disc must be mounted.
    ///   - scanState: the scan for that disc must have completed.
    ///   - selectedTitleIndex: the settled feature title — `nil` until the
    ///     confirmation row's implicit preselection or an explicit table
    ///     pick lands on `JobController`.
    ///   - runtimeLookup: #0032's TMDB lookup for the selected movie. Gated
    ///     on `.loaded`/`.unavailable` **only**, never on "not `.loading`" —
    ///     a lookup stuck in `.loading` (a `select` for an id missing from
    ///     `results`, or a transport that throws `CancellationError`) must
    ///     not silently let Start through just because it isn't loading.
    ///   - mismatchAcknowledged: required when the runtime cross-check comes
    ///     back `.mismatch` for `selectedTitleIndex` — a mismatch is a
    ///     stop-and-ask, not a warning (#0032's "Decisions" section).
    static func canStart(
        hasMovieSelected: Bool,
        isRunning: Bool,
        hasDisc: Bool,
        scanState: ScanState,
        selectedTitleIndex: Int?,
        runtimeLookup: RuntimeLookup,
        mismatchAcknowledged: Bool
    ) -> Bool {
        guard hasMovieSelected, !isRunning, hasDisc else { return false }

        guard case .scanned(let result) = scanState else { return false }
        guard let index = selectedTitleIndex,
              let title = result.disc.titles.first(where: { $0.index == index }) else {
            return false
        }

        switch runtimeLookup {
        case .loaded, .unavailable:
            break
        case .idle, .loading:
            return false
        }

        let verdict = RuntimeCrossCheck.evaluate(discSeconds: title.durationSeconds, lookup: runtimeLookup)
        if case .mismatch = verdict, !mismatchAcknowledged {
            return false
        }

        return true
    }
}
