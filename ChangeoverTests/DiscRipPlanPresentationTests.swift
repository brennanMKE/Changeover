import Foundation
import Testing
@testable import Changeover

/// #0164/#0165 — what the app says about the *whole disc*.
///
/// On the Uncle Buck / The Great Outdoors disc, 2026-09-27, the user named
/// both films and, the moment the first one landed in Plex, every surface in
/// the app claimed the disc was finished: the Ripping step had shown one bar
/// with no "of 2", the Done step showed one outcome card and offered
/// "Next Disc", and the notification announced the film as ready. The app was
/// about to start the second film off that same disc by itself.
///
/// So every sentence here is a pure function, and the first thing asserted is
/// the thing that must *not* have changed: a one-film disc reads exactly as it
/// always did.
///
/// Pure seams only. No view is tested and no UI test is written or run
/// (`docs/ui-test-crash-prevention.md`).
@Suite struct DiscRipPlanPresentationTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
        deviceNode: "disk4", discID: "disc-ub")

    private static func film(_ title: String, _ year: String, _ id: String) -> MovieMetadata {
        MovieMetadata(title: title, year: year, tmdbID: id)
    }

    private static let outdoors = film("The Great Outdoors", "1988", "2617")
    private static let buck = film("Uncle Buck", "1989", "2616")
    private static let candy = film("Planes, Trains and Automobiles", "1987", "13342")

    private static func onePlan() -> DiscRipPlan {
        DiscRipPlan.make(disc: disc, films: [(feature: 1, metadata: buck)])!
    }

    private static func twoPlan() -> DiscRipPlan {
        DiscRipPlan.make(disc: disc, films: [
            (feature: 1, metadata: outdoors),
            (feature: 2, metadata: buck),
        ])!
    }

    private static func threePlan() -> DiscRipPlan {
        DiscRipPlan.make(disc: disc, films: [
            (feature: 1, metadata: outdoors),
            (feature: 2, metadata: buck),
            (feature: 3, metadata: candy),
        ])!
    }

    /// Runs `feature` to a finish and hands back the job id it used, so a test
    /// can ask the presenter about that job afterwards.
    @discardableResult
    private static func finish(_ plan: inout DiscRipPlan, _ feature: Int, succeeded: Bool = true) -> JobID {
        let id = JobID.make()
        plan.markRunning(feature, jobID: id)
        plan.settle(jobID: id, succeeded: succeeded)
        return id
    }

    // MARK: - The regression that matters most

    /// A one-film disc is the disc every existing screen was written for. Not
    /// one of its sentences moves.
    @Test func aSingleFilmDiscSaysNothingNew() {
        var plan = Self.onePlan()
        #expect(DiscRipPlanPresentation.upNext(plan) == nil)
        #expect(DiscRipPlanPresentation.discSummary(plan) == nil)
        #expect(DiscRipPlanPresentation.notificationSentence(plan) == nil)
        #expect(DiscRipPlanPresentation.hasMoreToCome(plan) == false)
        #expect(DiscRipPlanPresentation.wayForwardTitle(plan) == "Next Disc")

        let id = Self.finish(&plan, 1)
        #expect(DiscRipPlanPresentation.position(ofJob: id, in: plan) == nil)
        #expect(DiscRipPlanPresentation.discSummary(plan) == nil)
        #expect(DiscRipPlanPresentation.notificationSentence(plan) == nil)
        #expect(DiscRipPlanPresentation.wayForwardTitle(plan) == "Next Disc")
    }

    /// And so does no plan at all — every caller written before multi-feature
    /// discs existed.
    @Test func noPlanSaysNothingNew() {
        #expect(DiscRipPlanPresentation.position(ofJob: JobID.make(), in: nil) == nil)
        #expect(DiscRipPlanPresentation.upNext(nil) == nil)
        #expect(DiscRipPlanPresentation.discSummary(nil) == nil)
        #expect(DiscRipPlanPresentation.report(nil) == nil)
        #expect(DiscRipPlanPresentation.notificationSentence(nil) == nil)
        #expect(DiscRipPlanPresentation.hasMoreToCome(nil) == false)
        #expect(DiscRipPlanPresentation.wayForwardTitle(nil) == "Next Disc")
    }

    // MARK: - Ripping

    @Test func theRippingStepSaysWhichFilmOfHowMany() {
        var plan = Self.twoPlan()
        let first = JobID.make()
        plan.markRunning(1, jobID: first)
        let position = DiscRipPlanPresentation.position(ofJob: first, in: plan)
        #expect(position?.plain == "Movie 1 of 2")
        #expect(position?.detail == "Feature 1 of 2 — title 1")
    }

    /// The position survives the job settling — the Done step and the History
    /// window ask about a job that has already finished.
    @Test func thePositionOutlivesTheJob() {
        var plan = Self.threePlan()
        let second = JobID.make()
        plan.markRunning(2, jobID: second)
        plan.settle(jobID: second, succeeded: true)
        #expect(DiscRipPlanPresentation.position(ofJob: second, in: plan)?.plain == "Movie 2 of 3")
    }

    @Test func aJobThatIsNotInThisPlanHasNoPosition() {
        var plan = Self.twoPlan()
        plan.markRunning(1, jobID: JobID.make())
        #expect(DiscRipPlanPresentation.position(ofJob: JobID.make(), in: plan) == nil)
    }

    @Test func theRippingStepNamesTheOneFilmThatFollows() {
        var plan = Self.twoPlan()
        plan.markRunning(1, jobID: JobID.make())
        let next = DiscRipPlanPresentation.upNext(plan)
        #expect(next?.plain == "Then Uncle Buck (1989), from this same disc.")
        #expect(next?.detail == "Then: Uncle Buck (1989) (title 2) waiting")
    }

    @Test func theRippingStepCountsAndNamesSeveralThatFollow() {
        var plan = Self.threePlan()
        plan.markRunning(1, jobID: JobID.make())
        #expect(DiscRipPlanPresentation.upNext(plan)?.plain
            == "Then 2 more films from this disc: Uncle Buck (1989) and Planes, Trains and Automobiles (1987).")
    }

    /// The last film on the disc has nothing after it, and saying so would be
    /// the same false "there is more" the whole ticket is about, inverted.
    @Test func theLastFilmHasNothingAfterIt() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        plan.markRunning(2, jobID: JobID.make())
        #expect(DiscRipPlanPresentation.upNext(plan) == nil)
    }

    // MARK: - Done: more to come

    /// The sentence this ticket exists for. It must not tell the person to
    /// take the disc out, and it must say the app carries on by itself.
    @Test func moreFilmsToComeSaysLeaveTheDiscIn() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        let summary = DiscRipPlanPresentation.discSummary(plan)
        #expect(summary?.plain
            == "One more film to go on this disc. Changeover starts it by itself — leave the disc in.")
        #expect(summary?.plain.contains("back in") == false)
        #expect(DiscRipPlanPresentation.hasMoreToCome(plan))
        #expect(DiscRipPlanPresentation.wayForwardTitle(plan) == "Continue")
    }

    @Test func twoFilmsToComeAreCounted() {
        var plan = Self.threePlan()
        Self.finish(&plan, 1)
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "2 more films to go on this disc. Changeover starts the next one by itself — leave the disc in.")
    }

    /// A film already running is still "more to come": a card that outlived
    /// its job must not offer the disc back.
    @Test func aFilmAlreadyRunningIsStillMoreToCome() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        plan.markRunning(2, jobID: JobID.make())
        #expect(DiscRipPlanPresentation.hasMoreToCome(plan))
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "The next film from this disc is already ripping — leave the disc in.")
        #expect(DiscRipPlanPresentation.wayForwardTitle(plan) == "Continue")
    }

    // MARK: - Done: finished

    @Test func everyFilmDoneSaysTheWholeDiscIsIn() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        Self.finish(&plan, 2)
        #expect(plan.isFinished)
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "Both films from this disc are in Plex now.")
        #expect(DiscRipPlanPresentation.hasMoreToCome(plan) == false)
        #expect(DiscRipPlanPresentation.wayForwardTitle(plan) == "Next Disc")
    }

    @Test func threeFilmsDoneAreCountedNotCalledBoth() {
        var plan = Self.threePlan()
        Self.finish(&plan, 1)
        Self.finish(&plan, 2)
        Self.finish(&plan, 3)
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "All 3 films from this disc are in Plex now.")
    }

    /// Skipped is not failed: a film the library already has was left alone on
    /// purpose, and the sentence says why.
    @Test func someDoneAndSomeSkippedSaysWhichWasWhich() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        plan.skip(2, reason: "already in Plex as Uncle Buck (1989)")
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "Done with this disc — 1 imported and 1 already in Plex.")
    }

    @Test func aFailureAlongsideASuccessIsSaidPlainly() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        Self.finish(&plan, 2, succeeded: false)
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "Done with this disc — 1 imported and 1 didn't finish.")
        // A failure does not hold the disc hostage: `DiscRipPlan.isFinished`
        // is deliberately true, so the way forward is the next disc.
        #expect(DiscRipPlanPresentation.wayForwardTitle(plan) == "Next Disc")
    }

    @Test func allThreeOutcomesAtOnceReadAsOneSentence() {
        var plan = Self.threePlan()
        Self.finish(&plan, 1)
        plan.skip(2, reason: "already in Plex")
        Self.finish(&plan, 3, succeeded: false)
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "Done with this disc — 1 imported, 1 already in Plex and 1 didn't finish.")
    }

    @Test func everyFilmSkippedIsNotACauseForAlarm() {
        var plan = Self.twoPlan()
        plan.skip(1, reason: "already in Plex")
        plan.skip(2, reason: "already in Plex")
        #expect(DiscRipPlanPresentation.discSummary(plan)?.plain
            == "Done with this disc — 2 already in Plex.")
    }

    // MARK: - The report (#0165 phase 4)

    /// Asked for by name on the John Candy disc: "I want to see the report on
    /// the 2 movies either imported or skipped on the final report."
    @Test func theReportListsEveryFilmWithItsOwnOutcome() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        plan.skip(2, reason: "already in Plex as Uncle Buck (1989)")

        let report = DiscRipPlanPresentation.report(plan)
        #expect(report?.summary?.plain == "Done with this disc — 1 imported and 1 already in Plex.")
        #expect(report?.rows.count == 2)
        #expect(report?.rows[0].name == "The Great Outdoors (1988)")
        #expect(report?.rows[0].status.plain == "Imported into Plex.")
        #expect(report?.rows[0].tone == .success)
        #expect(report?.rows[1].name == "Uncle Buck (1989)")
        #expect(report?.rows[1].status.plain == "Skipped — already in Plex.")
        #expect(report?.rows[1].tone == .neutral)
        // The skip reason is the answer to "why didn't you rip that one?", so
        // it is kept verbatim rather than summarised away.
        #expect(report?.rows[1].status.detail == "Skipped (title 2): already in Plex as Uncle Buck (1989)")
    }

    /// Rows are in disc order, whatever order they ran or were named in.
    @Test func theReportIsInDiscOrder() {
        var plan = Self.threePlan()
        Self.finish(&plan, 3)
        Self.finish(&plan, 1)
        let names = DiscRipPlanPresentation.report(plan)?.rows.map(\.name)
        #expect(names == ["The Great Outdoors (1988)", "Uncle Buck (1989)",
                          "Planes, Trains and Automobiles (1987)"])
    }

    /// Every state has a row, including the ones the disc never reached — a
    /// film with no line at all is the bug this replaces.
    @Test func theReportHasALineForEveryStateIncludingUnreached() throws {
        var plan = Self.threePlan()
        Self.finish(&plan, 1, succeeded: false)
        plan.markRunning(2, jobID: JobID.make())
        let rows = try #require(DiscRipPlanPresentation.report(plan)?.rows)
        #expect(rows.map(\.status.plain) == ["Didn't finish.", "Ripping now.", "Still to do."])
        let tones: [JobPresentation.Tone] = [.failure, .active, .neutral]
        #expect(rows.map(\.tone) == tones)
    }

    /// A one-film disc gets a report that reads like a sentence, not a table:
    /// one row, and no total to put over it.
    @Test func aOneFilmReportIsOneRowAndNoTotals() {
        var plan = Self.onePlan()
        Self.finish(&plan, 1)
        let report = DiscRipPlanPresentation.report(plan)
        #expect(report?.summary == nil, "nothing to total up over a single row")
        #expect(report?.rows.count == 1)
        #expect(report?.rows[0].name == "Uncle Buck (1989)")
        #expect(report?.rows[0].status.plain == "Imported into Plex.")
    }

    // MARK: - The notification

    @Test func theNotificationNamesTheOneFilmStillToCome() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        #expect(DiscRipPlanPresentation.notificationSentence(plan)
            == "Uncle Buck (1989) is next on this disc — leave it in.")
    }

    @Test func theNotificationCountsSeveralStillToCome() {
        var plan = Self.threePlan()
        Self.finish(&plan, 1)
        #expect(DiscRipPlanPresentation.notificationSentence(plan)
            == "2 more films to go on this disc — leave it in.")
    }

    @Test func theNotificationSaysSomethingTrueWhenTheDiscIsDone() {
        var plan = Self.twoPlan()
        Self.finish(&plan, 1)
        Self.finish(&plan, 2)
        #expect(DiscRipPlanPresentation.notificationSentence(plan)
            == "Both films from this disc are in Plex now.")
    }

    // MARK: - The plain register

    /// `docs/plain-language-ui.md` §1.2 — no tool names, no disc vocabulary,
    /// no identifiers in anything the default view draws. Swept over every
    /// state of a 1-, 2- and 3-film plan, which is every sentence this file
    /// can produce.
    @Test func everySentenceThisFileProducesIsPlain() {
        for plan in Self.everyState() {
            var sentences: [String] = []
            if let summary = DiscRipPlanPresentation.discSummary(plan) { sentences.append(summary.plain) }
            if let next = DiscRipPlanPresentation.upNext(plan) { sentences.append(next.plain) }
            if let banner = DiscRipPlanPresentation.notificationSentence(plan) { sentences.append(banner) }
            for entry in plan.entries {
                let id: JobID? = switch entry.state {
                case .running(let jobID), .done(let jobID), .failed(let jobID): jobID
                case .waiting, .skipped: nil
                }
                if let id, let position = DiscRipPlanPresentation.position(ofJob: id, in: plan) {
                    sentences.append(position.plain)
                }
            }
            if let report = DiscRipPlanPresentation.report(plan) {
                sentences.append(contentsOf: report.rows.map(\.status.plain))
            }
            sentences.append(DiscRipPlanPresentation.wayForwardTitle(plan))
            for sentence in sentences {
                #expect(PlainLanguage.violations(in: sentence).isEmpty, "\(sentence)")
            }
        }
    }

    /// Rule 6's spirit: these sit in a narrow window beside other text. The
    /// #0140 reviewer's worst acceptable case was 103 characters; the longest
    /// sentence here names one film, so a generous ceiling still catches a
    /// sentence that grew a list.
    @Test func noDiscSentenceOutgrowsTheWindow() {
        for plan in Self.everyState() {
            guard let summary = DiscRipPlanPresentation.discSummary(plan) else { continue }
            #expect(summary.plain.count <= 120, "\(summary.plain.count): \(summary.plain)")
        }
    }

    /// Every combination of states a 1-, 2- and 3-film plan can be in that the
    /// screens can actually reach.
    private static func everyState() -> [DiscRipPlan] {
        var plans: [DiscRipPlan] = [onePlan(), twoPlan(), threePlan()]

        var one = onePlan(); finish(&one, 1); plans.append(one)

        var running = twoPlan(); running.markRunning(1, jobID: JobID.make()); plans.append(running)

        var half = twoPlan(); finish(&half, 1); plans.append(half)
        var halfFailed = twoPlan(); finish(&halfFailed, 1, succeeded: false); plans.append(halfFailed)

        var both = twoPlan(); finish(&both, 1); finish(&both, 2); plans.append(both)
        var mixed = twoPlan(); finish(&mixed, 1); mixed.skip(2, reason: "already in Plex"); plans.append(mixed)
        var broken = twoPlan(); finish(&broken, 1); finish(&broken, 2, succeeded: false); plans.append(broken)
        var allSkipped = twoPlan(); allSkipped.skip(1, reason: "already in Plex")
        allSkipped.skip(2, reason: "already in Plex"); plans.append(allSkipped)

        var three = threePlan(); finish(&three, 1); three.skip(2, reason: "already in Plex")
        finish(&three, 3, succeeded: false); plans.append(three)
        var threeDone = threePlan(); finish(&threeDone, 1); finish(&threeDone, 2)
        finish(&threeDone, 3); plans.append(threeDone)
        var threeMidway = threePlan(); finish(&threeMidway, 1)
        threeMidway.markRunning(2, jobID: JobID.make()); plans.append(threeMidway)

        return plans
    }
}
