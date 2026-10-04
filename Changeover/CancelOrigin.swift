import Foundation

/// #0205 — who stopped the job.
///
/// The user, after being told a cancel reaches a watching agent as a plain
/// `job.finished`: "add cancelledBy so the watcher knows who cancelled."
///
/// A cancel was already reported — `cancelled` is a terminal phase, so the
/// snapshot diff emits `job.finished` with no cancel-path code having to
/// remember to send it. What it did not report was the decider. An agent could
/// *infer* "the user did it" from the absence of an `agent.action` event
/// alongside, which works and is exactly the kind of indirect reasoning #0200
/// found going wrong: there, an agent's own film choice was indistinguishable
/// from the app's guess, and the app's evidence panel had meanwhile credited a
/// person who had never seen the disc. Say who did it rather than leaving it to
/// be worked out from what is missing.
///
/// It matters more here than for a film choice. A cancelled encode is forty
/// minutes thrown away, and an agent that cannot tell "the person at the Mac
/// stopped this" from "my own `--force` stopped this" will retry something a
/// human just deliberately stopped.
nonisolated enum CancelOrigin: String, Equatable, Hashable, Sendable, CaseIterable {
    /// The window's Cancel Job button, or the history window's.
    case user
    /// `changeoverctl cancel`, or an `eject --force` that cancelled first.
    case agent
    /// The app itself, with nobody asking — quitting, or a disc going away
    /// under a running job. No such path exists today; the case is here so the
    /// first one that appears has somewhere honest to go rather than being
    /// filed as the user's doing.
    case app
}

/// Which job was cancelled, and by whom.
///
/// Paired with the job id on purpose. `lastOutcome` outlives the job it belongs
/// to — that is #0199's bug in a different place — so a bare origin would
/// attribute the *next* job's cancel to whoever cancelled the last one.
nonisolated struct CancelRecord: Equatable, Sendable {
    var job: JobID
    var by: CancelOrigin

    init(job: JobID, by: CancelOrigin) {
        self.job = job
        self.by = by
    }
}
