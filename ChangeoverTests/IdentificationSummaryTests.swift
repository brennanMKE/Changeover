import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0154 — the evidence panel has to say *who* chose the film.
///
/// Reported on the Adventureland disc, 2026-09-26: "The rip screen shows an
/// explanation which does not appear accurate." The disc's label was unusable,
/// the automatic attempt gave up, the user typed the title themselves — and the
/// panel, headed "How this was identified", showed only the machine's failed
/// reasoning, ending on `• Not choosing for you — …. Pick one below.` while a
/// rip of the film the user had picked was running.
///
/// Every line in `Job.identification` came from the automatic path; nothing was
/// ever recorded when a person searched and picked. When the automatic attempt
/// had named a *different* film — "The Caretaker" for the Walter Mitty disc —
/// the panel read as though the app had chosen that one.
@Suite struct IdentificationSummaryTests {

    /// The machine's own story, as the automatic path writes it.
    private static let automatic = [
        "▶ Identifying the disc — its label reads “ADV-0N-NW1.1_DES”",
        "  · the model had no answer — the label spells nothing",
        "• Not choosing for you — no candidate fits the disc. Pick one below.",
    ]

    // MARK: - The heading

    /// Untouched when the app did identify the film: this is the ordinary case
    /// and its heading was never wrong.
    @Test func theHeadingIsUnchangedWhenTheAppChose() {
        #expect(IdentificationSummary.heading(for: Self.automatic)
                == "How this was identified")
    }

    /// The bug, stated directly: once a user line is present the panel is a
    /// record of two different things and must stop claiming otherwise.
    @Test func theHeadingChangesOnceTheUserChose() {
        let lines = Self.automatic + [
            IdentificationSummary.userChoiceLine(movie: "Adventureland (2009)",
                                                 query: "Adventureland")
        ]
        #expect(IdentificationSummary.heading(for: lines)
                == "What the app guessed, and what you chose")
    }

    /// An empty story is still the plain heading, never a claim about a choice
    /// nobody made.
    @Test func anEmptyStoryUsesThePlainHeading() {
        #expect(IdentificationSummary.heading(for: []) == "How this was identified")
        #expect(!IdentificationSummary.wasChosenByUser([]))
    }

    /// The marker is the contract between the writer and the heading, so a line
    /// that merely mentions the user must not trip it.
    @Test func onlyTheMarkerCounts() {
        #expect(!IdentificationSummary.wasChosenByUser([
            "  · asking this Mac's on-device model to read 21 lines",
            "✓ Chose Adventureland — you might think it was your idea",
        ]))
    }

    // MARK: - The line itself

    /// The interesting case: what the user typed was not the film's title, so
    /// it is the substance of what happened and is kept.
    @Test func theLineKeepsASearchTermThatDiffersFromTheTitle() {
        let line = IdentificationSummary.userChoiceLine(
            movie: "Adventureland (2009)", query: "amusement park movie")
        #expect(line.hasPrefix(IdentificationSummary.userMarker))
        #expect(line.contains("amusement park movie"))
        #expect(line.contains("Adventureland (2009)"))
    }

    /// Spacing is not a real difference either — "adventure land" and
    /// "Adventureland" are the same thing typed two ways, and repeating it
    /// would be noise. (This is what the comparison squashing punctuation
    /// *and* whitespace buys; it is deliberate, not incidental.)
    @Test func spacingAloneDoesNotCountAsADifferentTerm() {
        #expect(IdentificationSummary.userChoiceLine(
            movie: "Adventureland (2009)", query: "adventure land")
                == "✎ You chose Adventureland (2009)")
    }

    /// But a term that is just the title adds nothing, and saying it twice is
    /// noise in a panel that is already dense.
    @Test func theLineDropsASearchTermThatIsJustTheTitle() {
        let line = IdentificationSummary.userChoiceLine(
            movie: "Adventureland (2009)", query: "Adventureland")
        #expect(line == "✎ You chose Adventureland (2009)")
    }

    /// Case and punctuation are not a real difference.
    @Test func theTermIsComparedLooselyOnCaseAndPunctuation() {
        for query in ["adventureland", "ADVENTURELAND", "Adventureland!", "Adventureland (2009)"] {
            #expect(IdentificationSummary.userChoiceLine(
                movie: "Adventureland (2009)", query: query)
                    == "✎ You chose Adventureland (2009)", "\(query)")
        }
    }

    /// No term at all still reads.
    @Test func theLineWorksWithNoSearchTerm() {
        #expect(IdentificationSummary.userChoiceLine(movie: "Knowing (2009)")
                == "✎ You chose Knowing (2009)")
        #expect(IdentificationSummary.userChoiceLine(movie: "Knowing (2009)", query: "   ")
                == "✎ You chose Knowing (2009)")
    }

    /// A film whose title genuinely contains a bracket must not be mangled by
    /// the "strip the year" comparison.
    @Test func aTitleWithItsOwnBracketsSurvives() {
        let line = IdentificationSummary.userChoiceLine(
            movie: "Kill Bill: Vol. 1 (2003)", query: "kill bill")
        #expect(line.contains("kill bill"))
        #expect(line.contains("Kill Bill: Vol. 1 (2003)"))
    }

    // MARK: - The panel reads truthfully end to end

    /// The whole point: the story now *ends* with what actually happened, so a
    /// reader of the panel cannot mistake the guess for the reason.
    @Test func theStoryEndsWithTheUsersChoice() {
        let lines = Self.automatic + [
            IdentificationSummary.userChoiceLine(movie: "Adventureland (2009)")
        ]
        #expect(lines.last?.hasPrefix("✎") == true)
        #expect(lines.first?.hasPrefix("▶") == true,
                "the app's attempt is kept, not hidden — #0148's lesson")
    }
}

/// #0154 — the controller side: the user's choice is held in one slot and
/// cleared by everything that should clear it.
///
/// Held rather than pushed through `note` per click, because a user trying
/// three rows before settling would otherwise leave three contradictory lines
/// in the panel.
@Suite struct ManualSelectionNoteTests {

    private static func controller() -> JobController {
        JobController(
            runner: { _, _ in .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: { _ in .ejected })
    }

    private static func settings() -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.plexMediaRoot = NSTemporaryDirectory()
        return s
    }

    private static func disc(_ volume: String) -> DiscInsertion {
        DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/\(volume)"),
                      deviceNode: "disk4", discID: volume)
    }

    @Test func nothingIsHeldUntilTheUserChooses() {
        #expect(Self.controller().manualSelectionNote == nil)
    }

    /// One slot, overwritten — three clicks leave one line, the last.
    @Test func aSecondChoiceReplacesTheFirst() {
        let jobs = Self.controller()
        jobs.noteManualSelection("✎ You chose The Caretaker (2026)")
        jobs.noteManualSelection("✎ You chose Adventureland (2009)")
        #expect(jobs.manualSelectionNote == "✎ You chose Adventureland (2009)")
    }

    /// An automatic selection clears it: if the app decided after all, the user
    /// did not choose, and the panel must not claim they did.
    @Test func anAutomaticSelectionClearsIt() {
        let jobs = Self.controller()
        jobs.noteManualSelection("✎ You chose Adventureland (2009)")
        jobs.noteManualSelection(nil)
        #expect(jobs.manualSelectionNote == nil)
    }

    /// And a new disc clears it, so one disc's choice can never appear under
    /// another disc's rip — the same rule `identificationNarration` follows.
    @Test func aNewDiscClearsIt() {
        let jobs = Self.controller()
        let settings = Self.settings()
        jobs.insertDisc(Self.disc("ADVENTURELAND"), settings: settings)
        jobs.noteManualSelection("✎ You chose Adventureland (2009)")
        jobs.insertDisc(Self.disc("KNOWING"), settings: settings)
        #expect(jobs.manualSelectionNote == nil)
    }

    /// What the panel ends up reading: the app's attempt kept, the user's choice
    /// last, and a heading that no longer misrepresents either.
    @Test func theJobPanelReadsTruthfully() {
        let job = Job(id: JobID.make(),
                      metadata: MovieMetadata(title: "Adventureland", year: "2009", tmdbID: "13811"),
                      disc: URL(fileURLWithPath: "/Volumes/ADV"), log: JobLog())
        job.recordIdentification([
            "▶ Identifying the disc — its label reads “ADV-0N-NW1.1_DES”",
            "• Not choosing for you — no candidate fits the disc. Pick one below.",
            IdentificationSummary.userChoiceLine(movie: "Adventureland (2009)"),
        ])
        #expect(IdentificationSummary.heading(for: job.identification)
                == "What the app guessed, and what you chose")
        #expect(job.identification.last?.hasPrefix("✎") == true)
    }
}

/// #0200 — three deciders, told apart.
///
/// Reported from a peer session driving `changeoverctl`: `status` said
/// `chosenByUser: false` for a film the agent had itself just selected, which
/// is the same thing the app says when it inferred the film unaided. So an
/// agent could not read its own effect back, and a second watcher could not see
/// which of them had decided.
///
/// Tracing it found the mirror-image bug on the app's side, which was worse.
/// `AgentActions.select` called `flow.select` without an `origin`, and the
/// default is `.user` — so the evidence panel the user consults when a wrong
/// film gets filed was headed "What the app guessed, and what you chose" and
/// credited a person who had never seen the disc.
struct AgentChoiceAttributionTests {

    static let guess = "Guessed “SIGNS” from the disc label"

    @Test func anUnaidedAppIsTheDefault() {
        #expect(IdentificationSummary.chooser([]) == .automation)
        #expect(IdentificationSummary.chooser([Self.guess]) == .automation)
    }

    @Test func aUserChoiceIsAttributedToTheUser() {
        let story = [Self.guess, IdentificationSummary.userChoiceLine(movie: "Signs (2002)")]
        #expect(IdentificationSummary.chooser(story) == .user)
        #expect(IdentificationSummary.wasChosenByUser(story))
        #expect(!IdentificationSummary.wasChosenByAgent(story))
    }

    /// The bug itself: this used to be indistinguishable from `.automation` on
    /// the wire and from `.user` in the panel.
    @Test func anAgentChoiceIsAttributedToTheAgent() {
        let story = [Self.guess, IdentificationSummary.agentChoiceLine(movie: "Signs (2002)")]
        #expect(IdentificationSummary.chooser(story) == .agent)
        #expect(IdentificationSummary.wasChosenByAgent(story))
        #expect(
            !IdentificationSummary.wasChosenByUser(story),
            "an agent's pick must never be reported as the user's")
    }

    /// The markers have to be distinct, since the whole mechanism is a prefix
    /// test on one line.
    @Test func theTwoMarkersAreNotTheSame() {
        #expect(IdentificationSummary.userMarker != IdentificationSummary.agentMarker)
    }

    /// A user overriding an agent is the user's choice, and the other way
    /// round. The story is in the order things happened, so the last marker
    /// wins — anything else would credit a decision that was superseded.
    @Test func theLastDeciderWins() {
        let user = IdentificationSummary.userChoiceLine(movie: "Signs (2002)")
        let agent = IdentificationSummary.agentChoiceLine(movie: "Unbreakable (2000)")
        #expect(IdentificationSummary.chooser([Self.guess, agent, user]) == .user)
        #expect(IdentificationSummary.chooser([Self.guess, user, agent]) == .agent)
    }

    /// The heading names the right decider, which is the half of this bug the
    /// person at the machine would actually have seen.
    @Test func theHeadingNamesTheDecider() {
        #expect(IdentificationSummary.heading(for: [Self.guess]) == "How this was identified")
        #expect(
            IdentificationSummary.heading(
                for: [IdentificationSummary.userChoiceLine(movie: "Signs (2002)")]
            ).contains("you chose"))
        #expect(
            IdentificationSummary.heading(
                for: [IdentificationSummary.agentChoiceLine(movie: "Signs (2002)")]
            ).contains("the agent chose"))
    }

    /// An agent that searched to find the film says so, the same way the user
    /// line does — on a disc with a useless label what was typed is the
    /// interesting part.
    @Test func theAgentLineKeepsTheQueryWhenItAddsSomething() {
        let plain = IdentificationSummary.agentChoiceLine(movie: "Signs (2002)", query: "Signs")
        #expect(!plain.contains("searched"), "a query equal to the title is noise")
        let typed = IdentificationSummary.agentChoiceLine(
            movie: "Signs (2002)", query: "mel gibson aliens")
        #expect(typed.contains("mel gibson aliens"))
        #expect(typed.hasPrefix(IdentificationSummary.agentMarker))
    }

    /// The wire field agrees with the story, and `chosenByUser` is derived from
    /// it rather than stored beside it — two fields that can disagree is the
    /// shape of the original bug.
    @Test func theWireFieldAgreesWithTheStory() {
        for chooser in IdentificationSummary.Chooser.allCases {
            let film = BridgeFixtures.film(chosenBy: chooser.rawValue)
            #expect(film.chosenBy == chooser.rawValue)
            #expect(film.chosenByUser == (chooser == .user))
            #expect(film.chosenByHand == (chooser != .automation))
        }
    }

    /// Every `Chooser` case has a wire name, so a case added later cannot
    /// serialise as something `FilmStatus.Chooser` has no constant for.
    @Test func everyChooserHasAWireName() {
        let named = Set([
            FilmStatus.Chooser.user, FilmStatus.Chooser.agent, FilmStatus.Chooser.automation,
        ])
        for chooser in IdentificationSummary.Chooser.allCases {
            #expect(named.contains(chooser.rawValue), "\(chooser) has no FilmStatus.Chooser constant")
        }
        #expect(named.count == IdentificationSummary.Chooser.allCases.count)
    }
}
