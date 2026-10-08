import Foundation
import Testing
@testable import Changeover
@testable import ChangeoverBridge

/// #0232 — a finished job stops being reported once its disc has gone.
///
/// `JobController.currentJobState` is `current ?? history.last`, which is the
/// right rule for the window — it is how the pane keeps showing what just
/// happened — and the wrong one for `status`, which is read by an agent
/// deciding what to do with the disc in the drive.
///
/// Observed on joe: PITCH_BLACK was in the drive and `status` showed Pacific
/// Rim: Uprising's job id, film and seventeen extras beside it. The two halves
/// of one response described different discs and nothing said so.
///
/// The user's rule: once a disc is ejected the state is cleared except for
/// history. So this clears rather than tags — a tagged stale block still asks
/// every reader to notice a field, while clearing says the only true thing,
/// which is that nothing is happening with the disc in the drive. `report`
/// reads `jobs.history` directly and is where a finished job belongs.
@Suite @MainActor struct StaleJobStatusTests {

    private static let metadata = MovieMetadata(
        title: "Pacific Rim Uprising", year: "2018", tmdbID: "268896")

    private static func job(insertion: String?) -> Job {
        Job(id: JobID.make(),
            metadata: metadata,
            disc: URL(fileURLWithPath: "/Volumes/PACIFIC_RIM"),
            log: JobLog(),
            discInsertionID: insertion)
    }

    /// A job carries the insertion it was started for, so a finished one can
    /// still say which disc it was about.
    @Test func ajobRecordsItsInsertion() {
        let id = UUID().uuidString
        #expect(Self.job(insertion: id).discInsertionID == id)
    }

    /// Nothing recorded on a hand-built job, the way `request` is optional.
    @Test func ajobNeedNotRecordOne() {
        #expect(Self.job(insertion: nil).discInsertionID == nil)
    }

    // The projection itself needs a `JobController`, which needs a disc and a
    // runner. `BridgeStatusReaderTests` covers the assembled snapshot; what is
    // pinned here is the rule the projection applies, kept as a plain value so
    // it can be read without one.

    /// The rule, stated as the pure question the reader asks.
    ///
    /// A finished job belongs in `status` only while the disc it ran on is
    /// still the disc in the drive.
    @Test func afinishedJobBelongsOnlyToItsOwnInsertion() {
        let a = UUID().uuidString
        let b = UUID().uuidString
        #expect(StaleJobRule.stillCurrent(jobInsertion: a, mountedInsertion: a))
        #expect(!StaleJobRule.stillCurrent(jobInsertion: a, mountedInsertion: b))
    }

    /// No disc in the drive clears it, which is the ejected case the user named.
    @Test func anejectedDiscClearsIt() {
        #expect(!StaleJobRule.stillCurrent(jobInsertion: UUID().uuidString,
                                           mountedInsertion: nil))
    }

    /// The same disc put back in is a NEW insertion, so its old job is just as
    /// stale as another disc's. This is why the rule is keyed on the insertion
    /// and not on the volume path, which is equal across two visits.
    @Test func thesameDiscReinsertedIsStillANewVisit() {
        #expect(!StaleJobRule.stillCurrent(jobInsertion: UUID().uuidString,
                                           mountedInsertion: UUID().uuidString))
    }

    /// A job from before the field existed belongs to nothing, so it clears
    /// with the disc rather than lingering. The safe direction: the harm here
    /// is a stale block being believed.
    @Test func ajobWithNoRecordedInsertionClears() {
        #expect(!StaleJobRule.stillCurrent(jobInsertion: nil,
                                           mountedInsertion: UUID().uuidString))
        #expect(!StaleJobRule.stillCurrent(jobInsertion: nil, mountedInsertion: nil))
    }
}
