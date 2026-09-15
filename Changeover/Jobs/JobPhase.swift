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
/// reads the disc directly for the whole encode) and no distinct phase for
/// the extras loop (#0031): extras run inline after the feature has already
/// moved, while the job is still conceptually `organizing`, and they never
/// change the job's own terminal outcome.
///
/// - `starting` — sweep + preflight (`DVDPipeline.run()`'s opening steps),
///   before HandBrakeCLI is ever launched or the disc otherwise touched.
/// - `encoding` — the primary `HandBrakeCLI` pass, reading the disc directly.
/// - `fallback` — #0015/#0035: after a disc-shaped primary failure,
///   `MakeMKVRipper.rip` followed by a second `HandBrakeCLI` pass over the
///   ripped `.mkv`. One phase for both steps — nothing outside
///   `DVDPipeline.runFallback` needs to distinguish rip-vs-encode within it.
/// - `organizing` — `PlexOrganizer.move` (and, per #0031, the extras loop
///   and eject that follow it) — not cancellable: the move itself is a
///   `FileManager` operation over in milliseconds, and cancelling it halfway
///   could leave a half-placed file in the Plex library.
/// - `succeeded`, `failed`, `cancelled` — terminal. Reached only through
///   `JobState.finishing(with:)`, never `advancing(to:)` — see `JobState`.
nonisolated enum JobPhase: String, Codable, Sendable, CaseIterable, Hashable {
    case starting
    case encoding
    case fallback
    case organizing
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .starting, .encoding, .fallback, .organizing:
            return false
        }
    }

    /// The transition table every edge is validated against. A `switch` on
    /// `(from, to)` with `default: return false` would silently accept an
    /// edge to any case added later with no entry — `JobPhaseTransitionTests
    /// .everyCaseHasATransitionTableEntry` walks `allCases` and fails if any
    /// case is missing a key here, so an omission is a test failure, not a
    /// silent gap.
    ///
    /// Note `organizing` has no outgoing edge to `cancelled` — see the type
    /// doc comment above.
    static let allowedTransitions: [JobPhase: Set<JobPhase>] = [
        .starting:   [.encoding, .failed, .cancelled],
        .encoding:   [.fallback, .organizing, .failed, .cancelled],
        .fallback:   [.organizing, .failed, .cancelled],
        .organizing: [.succeeded, .failed],
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
