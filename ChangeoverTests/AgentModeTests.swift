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

    @Test func adetailIsAppendedWhenThereIsOne() throws {
        let now = Date()
        let line = try #require(AgentMode.activityLine(
            AgentMode.Activity(action: "select", at: now, detail: "Signs (2002)"), now: now))
        #expect(line == "Chose what to import · just now — Signs (2002)")
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
