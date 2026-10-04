import Foundation
import Testing
@testable import Changeover

/// #0195 — what the window says while an agent is driving.
///
/// Reported while an agent was importing bonus features from another session:
/// "the Mac app does not reflect what is happening." Nothing was broken —
/// `changeoverctl watch` had suspended the app's automation exactly as #0189
/// designed — but an app that has gone quiet because something else is in
/// charge is indistinguishable from one that has gone wrong. That is the same
/// fault as #0153's silent eject and #0171's unreachable rung, in a fourth
/// place.
@Suite struct AgentModeTests {

    // MARK: - When the banner exists at all

    /// The ordinary case: no agent, no banner, the window exactly as it was.
    @Test func nosessionsMeansNoBanner() {
        #expect(!AgentMode.isActive(attachedSessions: 0))
    }

    /// Scoped to the session count, like the automation suspension it
    /// describes — so a crashed agent cannot leave the banner on screen any
    /// more than it can leave the app passive.
    @Test func thebannerLivesAndDiesWithTheSessions() {
        #expect(AgentMode.isActive(attachedSessions: 1))
        #expect(AgentMode.isActive(attachedSessions: 3))
        #expect(!AgentMode.isActive(attachedSessions: 0))
    }

    @Test func theheadlineCountsTheAgents() {
        #expect(AgentMode.headline(attachedSessions: 1) == "An agent is in control")
        #expect(AgentMode.headline(attachedSessions: 2) == "2 agents are in control")
    }

    /// The explanation has to name the thing the user would go and stop, and
    /// has to say the app hands back — the next disc sitting still is the
    /// symptom they would otherwise try to diagnose.
    @Test func theexplanationNamesTheToolAndTheEnd() {
        #expect(AgentMode.explanation.contains("changeoverctl"))
        #expect(AgentMode.explanation.contains("hands back"))
        #expect(!AgentMode.explanation.lowercased().contains("error"))
    }

    // MARK: - What the agent last asked for

    /// A session count is a light that is on. An agent that asked for
    /// something twenty minutes ago and one working right now look identical
    /// through it, and only one of those is a problem.
    @Test func nothingAskedYetSaysNothing() {
        #expect(AgentMode.activityLine(nil) == nil)
    }

    @Test func theactivityLineReadsAsASentence() throws {
        let now = Date()
        let line = try #require(AgentMode.activityLine(
            AgentMode.Activity(action: "import", at: now.addingTimeInterval(-120)), now: now))
        #expect(line == "Started an import · 2m ago")
    }

    @Test func theSubjectIsAppendedWhenThereIsOne() throws {
        let now = Date()
        let line = try #require(AgentMode.activityLine(
            AgentMode.Activity(action: "select", at: now, subject: "Signs (2002)"), now: now))
        #expect(line == "Chose what to import · just now — Signs (2002)")
    }

    // MARK: - #0204: the banner is not the CLI's output

    /// The reported bug, as the string it produced.
    ///
    /// The banner carried `ActionResult.detail` verbatim, and `detail` is
    /// written for the program on the other end. On joe it read: "Started an
    /// import · 1m ago — started job-20261004-014421-57CD Wait for it with
    /// `changeoverctl wait --for job-done --job job-20261004-014421-57CD`."
    /// A person at the Mac was being told to type a shell command.
    ///
    /// The structural fix is that `Activity` has nowhere to put such a string
    /// any more — there is no free-text field. This pins the sentence the user
    /// gets instead.
    @Test func theBannerNamesTheFilmRatherThanTheCommand() throws {
        let now = Date()
        let line = try #require(AgentMode.activityLine(
            AgentMode.Activity(
                action: "import",
                at: now.addingTimeInterval(-60),
                subject: "The Lord of the Rings: The Return of the King (2003)"
            ),
            now: now))
        #expect(line == "Started an import · 1m ago — The Lord of the Rings: The Return of the King (2003)")
        for leak in ["changeoverctl", "`", "--", "job-"] {
            #expect(!line.contains(leak), "the banner leaked CLI text: \(leak)")
        }
    }

    /// A refusal says so in words, not as the CLI's identifier.
    @Test func aRefusalIsSaidInWords() throws {
        let now = Date()
        let line = try #require(AgentMode.activityLine(
            AgentMode.Activity(action: "import", at: now, refusedOutcome: "refusedNoDisc"), now: now))
        #expect(line == "Started an import · just now — refused — no disc in the drive")
        #expect(!line.contains("refusedNoDisc"))
    }

    /// An unknown outcome still says the action was turned down. A newer
    /// `changeoverctl` talking to an older app is when that matters most.
    @Test func anUnknownRefusalStillSaysRefused() {
        #expect(AgentMode.refusalPhrase("refusedSomethingNewer") == "refused")
        #expect(AgentMode.refusalPhrase("") == "refused")
    }

    /// No refusal phrase may leak an identifier — the whole point is that these
    /// are English. Swept over every outcome the bridge defines.
    @Test func noRefusalPhraseLeaksAnIdentifier() {
        for outcome in [
            "refusedNoSession", "refusedUnknownSession", "refusedJobRunning", "refusedNoDisc",
            "refusedAlreadyEjecting", "refusedScanRunning", "refusedDiscSwapped", "refusedNoScan",
            "refusedUnknownTitle", "refusedUnknownExtrasFolder", "refusedMovieNotFound",
            "refusedNothingRunning", "refusedNotPermitted", "refusedNotConfigured",
            "refusedEmptyRequest",
        ] {
            let phrase = AgentMode.refusalPhrase(outcome)
            #expect(phrase.hasPrefix("refused"))
            #expect(!phrase.contains(outcome), "\(outcome) was shown verbatim")
        }
    }

    /// A refusal wins over the subject: "it did not happen" is the thing to
    /// say, and naming the film alongside would read as though it had.
    @Test func aRefusalIsSaidInsteadOfTheSubject() throws {
        let now = Date()
        let line = try #require(AgentMode.activityLine(
            AgentMode.Activity(
                action: "import", at: now,
                subject: "Signs (2002)", refusedOutcome: "refusedJobRunning"
            ),
            now: now))
        #expect(line.contains("refused"))
        #expect(!line.contains("Signs"))
    }

    // MARK: - The subject

    @Test func theFilmIsPreferredAndCarriesItsYear() {
        #expect(AgentMode.subject(filmTitle: "Signs", filmYear: "2002", discLabel: "SIGNS") == "Signs (2002)")
    }

    /// The disc only when there is no film — `eject` and `cancel` have none.
    @Test func theDiscStandsInWhenThereIsNoFilm() {
        #expect(AgentMode.subject(filmTitle: nil, filmYear: nil, discLabel: "TWO_TOWERS_BONUS")
                == "TWO_TOWERS_BONUS")
    }

    /// And nothing at all is a perfectly good answer: "Read the status · just
    /// now" is already the whole sentence.
    @Test func nothingToNameIsNil() {
        #expect(AgentMode.subject(filmTitle: nil, filmYear: nil, discLabel: nil) == nil)
        #expect(AgentMode.subject(filmTitle: "", filmYear: "", discLabel: "") == nil)
    }

    /// A film with no year is still named, rather than dropped for want of a
    /// parenthesis.
    @Test func aFilmWithoutAYearIsStillNamed() {
        #expect(AgentMode.subject(filmTitle: "Signs", filmYear: nil, discLabel: "SIGNS") == "Signs")
        #expect(AgentMode.subject(filmTitle: "Signs", filmYear: "", discLabel: nil) == "Signs")
    }

    /// An action this build does not know is shown verbatim rather than
    /// hidden. A newer `changeoverctl` talking to an older app is exactly when
    /// the user most needs to see what was asked for.
    @Test func anUnknownActionIsShownNotSwallowed() {
        #expect(AgentMode.phrase(forAction: "teleport") == "Asked for “teleport”")
    }

    /// Every verb the CLI is planned to carry reads as a sentence, so adding
    /// one to the protocol without adding it here shows up as a quoted raw
    /// string rather than passing silently.
    @Test func everyPlannedVerbHasItsOwnPhrase() {
        for action in ["status", "watch", "assets", "library", "search",
                       "select", "import", "cancel", "eject", "report"] {
            let phrase = AgentMode.phrase(forAction: action)
            #expect(!phrase.contains("Asked for"), "“\(action)” has no phrase of its own")
            #expect(!phrase.isEmpty)
        }
    }

    // MARK: - Elapsed time

    /// Whole units, largest that fits. "just now" under five seconds, because
    /// "0 seconds ago" is noise about something that is live.
    @Test func elapsedTimeReadsInWholeUnits() {
        #expect(AgentMode.ago(0) == "just now")
        #expect(AgentMode.ago(4.9) == "just now")
        #expect(AgentMode.ago(5) == "5s ago")
        #expect(AgentMode.ago(59) == "59s ago")
        #expect(AgentMode.ago(60) == "1m ago")
        #expect(AgentMode.ago(3_599) == "59m ago")
        #expect(AgentMode.ago(3_600) == "1h ago")
    }

    /// A clock that went backwards must not produce a negative age.
    @Test func aclockSkewDoesNotProduceNonsense() throws {
        let now = Date()
        let line = try #require(AgentMode.activityLine(
            AgentMode.Activity(action: "status", at: now.addingTimeInterval(60)), now: now))
        #expect(line.contains("just now"))
    }
}
