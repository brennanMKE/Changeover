import Foundation
import Testing
@testable import Changeover

/// #0164 — the banner, end to end.
///
/// `NotificationTruthTests` pins what `JobNotifier.message` says with no plan,
/// and that file exists because the success banner once asserted a disc had
/// been ejected when it had not. This suite is the other half of the same
/// rule: on a disc holding two films, the banner for the first one must not
/// imply the disc is finished either — the app is about to read that disc
/// again, and "the disc has been ejected" there is either false or an
/// instruction to break the run.
///
/// Every assertion here passes a plan; every assertion in
/// `NotificationTruthTests` passes none, and `plan` defaults to `nil`, so the
/// two suites cannot collide.
///
/// Pure seams only. No view is tested and no UI test is written or run
/// (`docs/ui-test-crash-prevention.md`).
@Suite struct MultiFilmNotificationTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
        deviceNode: "disk4", discID: "disc-ub")

    private static let outdoors = MovieMetadata(title: "The Great Outdoors", year: "1988", tmdbID: "2617")
    private static let buck = MovieMetadata(title: "Uncle Buck", year: "1989", tmdbID: "2616")

    private static func plan() -> DiscRipPlan {
        DiscRipPlan.make(disc: disc, films: [
            (feature: 1, metadata: outdoors), (feature: 2, metadata: buck),
        ])!
    }

    private static var succeeded: JobOutcome {
        .succeeded(destination: URL(fileURLWithPath: "/Volumes/Media/x.mp4"))
    }

    private static func body(_ plan: DiscRipPlan?, ejected: Bool?) -> String {
        JobNotifier.message(for: outdoors, outcome: succeeded,
                            discWasEjected: ejected, plan: plan).body
    }

    private static func finishedFirst() -> DiscRipPlan {
        var plan = plan()
        let first = JobID.make()
        plan.markRunning(1, jobID: first)
        plan.settle(jobID: first, succeeded: true)
        return plan
    }

    /// The bug, stated directly: the first film's banner must not send the
    /// person to the drive for a disc the app is about to read again.
    @Test func theFirstFilmsBannerSaysTheDiscStaysIn() {
        #expect(Self.body(Self.finishedFirst(), ejected: nil)
            == "Encoded and moved into Plex. Uncle Buck (1989) is next on this disc — leave it in.")
    }

    /// Even if something claims the disc came out, the banner does not put
    /// that under a sentence which has just said to leave it in — one of the
    /// two would have to be wrong.
    @Test func theEjectClaimIsSuppressedWhileFilmsRemain() {
        let plan = Self.finishedFirst()
        for ejected in [true, false, nil] {
            let body = Self.body(plan, ejected: ejected)
            #expect(!body.contains("has been ejected"), "\(String(describing: ejected))")
            #expect(!body.contains("still in the drive"), "\(String(describing: ejected))")
        }
    }

    /// And when the disc really is finished, the banner says so *and* keeps
    /// the eject answer it has always given, including the silence.
    @Test func theLastFilmsBannerReportsTheWholeDiscAndTheEject() {
        var plan = Self.plan()
        for feature in [1, 2] {
            let id = JobID.make()
            plan.markRunning(feature, jobID: id)
            plan.settle(jobID: id, succeeded: true)
        }
        #expect(Self.body(plan, ejected: true)
            == "Encoded and moved into Plex. Both films from this disc are in Plex now. The disc has been ejected.")
        #expect(Self.body(plan, ejected: false)
            == "Encoded and moved into Plex. Both films from this disc are in Plex now. The disc is still in the drive.")
        #expect(Self.body(plan, ejected: nil)
            == "Encoded and moved into Plex. Both films from this disc are in Plex now.")
    }

    /// A one-film plan is not a plan worth a sentence: the banner is
    /// byte-for-byte the one `NotificationTruthTests` pins.
    @Test func aSingleFilmPlanLeavesTheBannerExactlyAsItWas() {
        let plan = DiscRipPlan.make(disc: Self.disc, films: [(feature: 1, metadata: Self.outdoors)])!
        for ejected in [true, false, nil] {
            #expect(Self.body(plan, ejected: ejected) == Self.body(nil, ejected: ejected))
        }
        #expect(Self.body(plan, ejected: nil) == "Encoded and moved into Plex.")
    }

    /// The headline never mentioned the disc and still does not — it names the
    /// film that is ready, which is true whatever else the disc holds.
    @Test func theHeadlineIsUnchangedByThePlan() {
        let title = JobNotifier.message(
            for: Self.outdoors, outcome: Self.succeeded, plan: Self.plan()).title
        #expect(title == "The Great Outdoors (1988) is ready")
    }

    /// The failure bodies are left exactly alone: none of them ever claimed
    /// the disc was ejected, and whether the app carries on to the next film
    /// *after a failure* is #0163's decision, not a promise for a banner to
    /// make on its behalf.
    @Test func aFailureBannerIsUnchangedByThePlan() {
        let failed = JobOutcome.failed(JobFailure(stage: .encode, reason: .diskFull))
        let cancelled = JobOutcome.failed(JobFailure(stage: .encode, reason: .cancelled))
        for outcome in [failed, cancelled] {
            let with = JobNotifier.message(for: Self.outdoors, outcome: outcome, plan: Self.plan())
            let without = JobNotifier.message(for: Self.outdoors, outcome: outcome)
            #expect(with.title == without.title)
            #expect(with.body == without.body)
        }
    }

    /// `docs/plain-language-ui.md` §3.18 — a banner is the plainest surface
    /// the app has: no disclosure to open, no log beside it.
    @Test func everyPlanAwareBannerIsPlain() {
        var plan = Self.plan()
        #expect(PlainLanguage.violations(in: Self.body(plan, ejected: nil)).isEmpty)
        let first = JobID.make()
        plan.markRunning(1, jobID: first)
        #expect(PlainLanguage.violations(in: Self.body(plan, ejected: nil)).isEmpty)
        plan.settle(jobID: first, succeeded: true)
        #expect(PlainLanguage.violations(in: Self.body(plan, ejected: nil)).isEmpty)
        plan.skip(2, reason: "already in Plex")
        #expect(PlainLanguage.violations(in: Self.body(plan, ejected: true)).isEmpty)
    }
}
