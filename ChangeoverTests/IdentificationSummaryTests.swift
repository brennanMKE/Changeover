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
