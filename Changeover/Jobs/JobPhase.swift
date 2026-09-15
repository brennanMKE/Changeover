import Foundation

/// #0041 — the job lifecycle, distinct from the pre-existing `JobStage`
/// (`JobOutcome.swift`), which names the stage a *failure* happened at and is
/// wire format from #0007. `JobPhase` is new and names the whole job's
/// progress through `DVDPipeline.run()`, including states `JobStage` has no
/// use for (`starting`, `fallback`) and the three terminal states a running
/// job settles into.
///
/// Cases match today's code, post-#0014/#0015/#0031/#0035/#0037 — there is
/// no `ripping`/`awaitingEncode` (#0014 removed the rip stage; HandBrakeCLI
/// reads the disc directly for the whole encode).
///
/// - `starting` — sweep + preflight (`DVDPipeline.run()`'s opening steps),
///   before HandBrakeCLI is ever launched or the disc otherwise touched.
/// - `encoding` — the primary `HandBrakeCLI` pass, reading the disc directly,
///   including #0037's output-duration check on its result (seconds, and part
///   of deciding whether the encode succeeded).
/// - `fallback` — #0015/#0035: after a disc-shaped primary failure,
///   `MakeMKVRipper.rip` followed by a second `HandBrakeCLI` pass over the
///   ripped `.mkv` (and #0037's check on that). One phase for both steps —
///   nothing outside `DVDPipeline.runFallback` needs to distinguish
///   rip-vs-encode within it.
/// - `organizing` — `PlexOrganizer.move` of the feature, plus the end-of-job
///   eject when there are no extras (the plan refresh folds the eject in
///   here). Not cancellable: the move is a `FileManager` operation over in
///   milliseconds, and cancelling it halfway could leave a half-placed file
///   in the Plex library.
/// - `extras` — #0031's loop: one `HandBrakeCLI` encode per extra against the
///   disc, each checked (#0037) and moved into `Clips/`, then the eject. The
///   feature is already in Plex, so this phase can only end `succeeded`
///   (extras never change the outcome) or `failed`. A 40-minute extras encode
///   is not "moving into Plex", so it gets its own phase rather than
///   borrowing `organizing`'s label and its "too short to cancel" rule.
///   Whether a user cancel may interrupt it — and whether that job then ends
///   `succeeded` or `cancelled` — is #0046's decision; no `cancelled` edge
///   until then. Reported only when extras actually run (not when the
///   feature came from the MakeMKV fallback, #0035).
/// - `succeeded`, `failed`, `cancelled` — terminal. Reached only through
///   `JobState.finishing(with:)`, never `advancing(to:)` — see `JobState`.
///
/// There is deliberately no `ejecting` phase: the eject is a few seconds at
/// the tail of `organizing`/`extras`, cannot be cancelled, and nothing acts
/// on it separately (#0045's manual eject refuses on `isRunning`).
nonisolated enum JobPhase: String, Codable, Sendable, CaseIterable, Hashable {
    case starting
    case encoding
    case fallback
    case organizing
    case extras
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .starting, .encoding, .fallback, .organizing, .extras:
            return false
        }
    }

    /// The transition table every edge is validated against. A `switch` on
    /// `(from, to)` with `default: return false` would silently accept an
    /// edge to any case added later with no entry — `JobPhaseTests
    /// .everyCaseHasATransitionTableEntry` walks `allCases` and fails if any
    /// case is missing a key here, so an omission is a test failure, not a
    /// silent gap.
    ///
    /// Every non-terminal phase may fail. Only `organizing` and `extras` may
    /// succeed — the feature has to be in Plex first. Neither has an edge to
    /// `cancelled` — see the type doc comment above.
    static let allowedTransitions: [JobPhase: Set<JobPhase>] = [
        .starting:   [.encoding, .failed, .cancelled],
        .encoding:   [.fallback, .organizing, .failed, .cancelled],
        .fallback:   [.organizing, .failed, .cancelled],
        .organizing: [.extras, .succeeded, .failed],
        .extras:     [.succeeded, .failed],
        .succeeded:  [],
        .failed:     [],
        .cancelled:  [],
    ]

    /// `true` if `self → target` is a legal edge in `allowedTransitions`.
    /// A phase absent from the table (which the completeness test above
    /// guarantees can't happen) is treated as having no outgoing edges,
    /// never as a crash.
    func canTransition(to target: JobPhase) -> Bool {
        JobPhase.allowedTransitions[self]?.contains(target) ?? false
    }
}
