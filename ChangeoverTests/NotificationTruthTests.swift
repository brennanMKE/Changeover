import Foundation
import Testing
@testable import Changeover

/// The success notification used to assert that the disc had been ejected for
/// every successful job, whether or not it had — and it had no way to know,
/// because the call site passed no eject information at all.
///
/// Through most of 2026-09 that eject was being refused by `loginwindow` on a
/// locked screen. So on exactly the nights the user was watching for a disc
/// that would not come out, the banner told them it had. A notification is the
/// one surface seen without opening a window, which is precisely why it must
/// not guess.
@Suite struct NotificationTruthTests {

    private static let metadata = MovieMetadata(
        title: "Pump Up the Volume", year: "1990", tmdbID: "8428")

    private static var succeeded: JobOutcome {
        .succeeded(destination: URL(fileURLWithPath: "/Volumes/Media/x.mp4"))
    }

    private static func body(ejected: Bool?) -> String {
        JobNotifier.message(for: metadata, outcome: succeeded, discWasEjected: ejected).body
    }

    /// The bug, stated directly.
    @Test func aDiscStillInTheDriveIsNotReportedAsEjected() {
        let body = Self.body(ejected: false)
        #expect(!body.contains("has been ejected"), "this is the sentence that was wrong")
        #expect(body.contains("still in the drive"))
    }

    /// And the ordinary case still says so.
    @Test func anEjectedDiscIsReportedAsEjected() {
        #expect(Self.body(ejected: true).contains("The disc has been ejected."))
    }

    /// Silence is the right answer when the eject was never attempted or its
    /// result is unknown. Being told nothing sends someone to look; being told
    /// wrongly does not.
    @Test func anUnknownEjectSaysNothingAboutTheDisc() {
        let body = Self.body(ejected: nil)
        #expect(!body.lowercased().contains("disc"))
        #expect(body.contains("Encoded and moved into Plex."))
    }

    /// Whatever happened to the disc, the part that matters is unchanged.
    @Test func theFilmIsAlwaysReportedAsFiled() {
        for ejected in [true, false, nil] {
            #expect(Self.body(ejected: ejected).hasPrefix("Encoded and moved into Plex."))
        }
    }

    /// The title never mentions the disc, so it is unaffected.
    @Test func theHeadlineIsUnchanged() {
        let title = JobNotifier.message(
            for: Self.metadata, outcome: Self.succeeded, discWasEjected: false).title
        #expect(title == "Pump Up the Volume (1990) is ready")
    }

    /// Callers written before this existed default to saying nothing about the
    /// disc rather than to the old assertion — the safe direction.
    @Test func theDefaultIsSilenceNotAnAssumption() {
        let body = JobNotifier.message(for: Self.metadata, outcome: Self.succeeded).body
        #expect(!body.contains("ejected"))
    }

    /// The failure cases were already accurate and must stay that way — the
    /// cancelled one even says where the disc is, which is what made the
    /// success case look like an oversight rather than a decision.
    @Test func aCancelledJobStillSaysTheDiscIsInTheDrive() {
        let cancelled = JobOutcome.failed(
            JobFailure(stage: .encode, reason: .cancelled))
        let body = JobNotifier.message(for: Self.metadata, outcome: cancelled).body
        #expect(body.contains("still in the drive"))
    }

    // MARK: - The Job side

    /// A job that has not reached an eject reports nothing, rather than false.
    @Test func aJobThatNeverEjectedHasNoAnswer() {
        let job = Job(id: JobID.make(), metadata: Self.metadata,
                      disc: URL(fileURLWithPath: "/Volumes/D"), log: JobLog())
        #expect(job.discWasEjected == nil)
    }

    /// And once it has, the answer is what actually happened.
    @Test func aJobRecordsWhatTheEjectDid() {
        let job = Job(id: JobID.make(), metadata: Self.metadata,
                      disc: URL(fileURLWithPath: "/Volumes/D"), log: JobLog())
        job.recordEject(succeeded: false)
        #expect(job.discWasEjected == false)
        job.recordEject(succeeded: true)
        #expect(job.discWasEjected == true)
    }
}
