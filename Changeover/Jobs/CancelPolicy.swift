import Foundation

/// #0046 — the pure decision behind `JobController.cancel(id:)`, mirroring
/// `EjectPolicy`'s shape: a plain `decide(...) -> Decision` that never
/// touches `JobController` state directly, so every refusal path is testable
/// with hand-built values and no `Runner`/`Task`/disc.
///
/// Two questions, both answered together because they share one refusal
/// message shape:
/// 1. Does `id` name the job actually running right now? A cancel for any
///    other id — a stale button from a finished job's view, a wrong id off
///    the wire (#0060) — must never touch the real running job.
/// 2. Is its phase one a real cancel can safely interrupt? `organizing`'s
///    `PlexOrganizer.move` is a few-millisecond `FileManager` operation with
///    no outgoing `cancelled` edge (`JobPhase.allowedTransitions`, #0041) —
///    interrupting it halfway could leave a half-placed file in the Plex
///    library — and a terminal phase means the job has already finished.
///    `starting`, `encoding`, `fallback` and `extras` are all fair game.
nonisolated enum CancelPolicy {
    nonisolated enum Decision: Equatable, Sendable {
        case cancel
        case refuse(reason: String)

        /// The refusal's reason, or `nil` for `.cancel` — what the status
        /// menu shows as the disabled row's tooltip, mirroring
        /// `EjectPolicy.Decision.refusalReason`.
        var refusalReason: String? {
            if case .refuse(let reason) = self { return reason }
            return nil
        }

        /// `docs/plain-language-ui.md` §3.9 — the same refusal as a caption
        /// beside the disabled button. `refusalReason` above stays the
        /// tooltip, verbatim.
        ///
        /// Only the one refusal a person can actually meet has a plain form:
        /// "no job with that id is currently running" and "the job has
        /// already finished" describe a button that should not have been
        /// pressable, which is a bug report, not a sentence for the user.
        var plainRefusalReason: String? {
            guard case .refuse(let reason) = self else { return nil }
            return reason == Self.organizingRefusal
                ? "Almost done — this can't be stopped now."
                : nil
        }

        /// The one refusal with a plain sibling, named so the two cannot
        /// drift apart.
        static let organizingRefusal = "the job is being moved into Plex and can't be interrupted"
    }

    /// `currentID`/`phase` are `JobController.current?.id`/`current?.state
    /// .phase` — both `nil` together exactly when no job is running.
    nonisolated static func decide(requestedID: JobID, currentID: JobID?, phase: JobPhase?) -> Decision {
        guard let currentID, let phase, requestedID == currentID else {
            return .refuse(reason: "no job with that id is currently running")
        }
        if phase == .organizing {
            return .refuse(reason: Decision.organizingRefusal)
        }
        if phase.isTerminal {
            return .refuse(reason: "the job has already finished")
        }
        return .cancel
    }
}
