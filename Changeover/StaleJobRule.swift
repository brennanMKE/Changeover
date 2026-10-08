import Foundation

/// #0232 — whether a finished job still describes the disc in the drive.
///
/// `JobController.currentJobState` is `current ?? history.last`. That is the
/// right rule for the window, where it is how the pane keeps showing what just
/// happened, and the wrong one for `status`, which an agent reads to decide what
/// to do with the disc in front of it.
///
/// Observed on joe: PITCH_BLACK was in the drive and `status` reported Pacific
/// Rim: Uprising's job id, film and seventeen extras beside it. The two halves
/// of one response described different discs and nothing said so. An agent
/// reading that sees a disc with a completed job attached, and can reasonably
/// conclude this disc has already been imported.
///
/// The rule the user set: once a disc is ejected the state is cleared except for
/// history. So the stale block is **cleared, not tagged**. Tagging leaves it on
/// screen and asks every reader to notice a field; clearing says the only true
/// thing, which is that nothing is happening with the disc in the drive. Nothing
/// is lost — `report` reads `jobs.history` directly, and a finished job belongs
/// there.
nonisolated enum StaleJobRule {

    /// Whether a job started for `jobInsertion` still describes the disc whose
    /// insertion is `mountedInsertion`.
    ///
    /// Keyed on the **insertion**, never on the volume path. A path is equal
    /// across two visits of the same disc, so it cannot tell "still here" from
    /// "taken out and put back" — and a disc put back in is a new visit whose
    /// old job is just as stale as another disc's. `DiscInsertion.insertionID`
    /// is minted once per insertion, which is why #0196's `import` already
    /// refuses on it.
    ///
    /// A job with no recorded insertion predates the field and belongs to
    /// nothing, so it clears with the disc rather than lingering. That is the
    /// safe direction: the harm here is a stale block being believed.
    static func stillCurrent(jobInsertion: String?, mountedInsertion: String?) -> Bool {
        guard let jobInsertion, let mountedInsertion else { return false }
        return jobInsertion == mountedInsertion
    }
}
