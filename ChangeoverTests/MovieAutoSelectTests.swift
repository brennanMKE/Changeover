import Foundation
import Testing
@testable import Changeover

/// Searching "Enemy at the Gates" returns three films whose titles cannot
/// separate them. The disc's own runtime can.
struct MovieAutoSelectTests {

    /// The real result set, as TMDB returned it on 2026-09-22, with the
    /// runtimes a details lookup gives. The disc's feature runs 131 minutes.
    nonisolated static let enemyAtTheGates = [
        MovieAutoSelect.Candidate(id: 874214, title: "Enemy at the Gates", runtimeMinutes: 106),
        MovieAutoSelect.Candidate(id: 853, title: "Enemy at the Gates", runtimeMinutes: 131),
        MovieAutoSelect.Candidate(id: 1556038, title: "Enemy at the Gates Iran's Threat to America", runtimeMinutes: 43),
    ]
    nonisolated static let discSeconds = 131 * 60

    @Test func theDiscsRuntimePicksTheRightFilmFromIdenticalTitles() {
        let decision = MovieAutoSelect.decide(
            candidates: Self.enemyAtTheGates,
            discDurationSeconds: Self.discSeconds,
            searchTerm: "Enemy at the Gates"
        )
        #expect(decision.selectedID == 853, "the 2001 film, not the 2021 short or the 2025 documentary")
    }

    /// Ordering must not matter: TMDB put the wrong film first.
    @Test func theOrderTMDBReturnedThemInIsIrrelevant() {
        let decision = MovieAutoSelect.decide(
            candidates: Self.enemyAtTheGates.reversed(),
            discDurationSeconds: Self.discSeconds,
            searchTerm: "Enemy at the Gates"
        )
        #expect(decision.selectedID == 853)
    }

    // MARK: - Abstaining

    @Test func withNoDiscRuntimeNothingIsChosen() {
        let decision = MovieAutoSelect.decide(
            candidates: Self.enemyAtTheGates,
            discDurationSeconds: nil,
            searchTerm: "Enemy at the Gates"
        )
        #expect(decision.selectedID == nil)
    }

    /// Two cuts of the same film are not separable by runtime, and the title
    /// is identical, so the user chooses.
    @Test func twoCutsOfTheSameLengthLeaveTheChoiceAlone() {
        let candidates = [
            MovieAutoSelect.Candidate(id: 1, title: "Blade Runner", runtimeMinutes: 117),
            MovieAutoSelect.Candidate(id: 2, title: "Blade Runner", runtimeMinutes: 116),
        ]
        let decision = MovieAutoSelect.decide(
            candidates: candidates, discDurationSeconds: 117 * 60, searchTerm: "Blade Runner"
        )
        #expect(decision.selectedID == nil)
        if case .abstain(let reason) = decision {
            #expect(reason.contains("2"), "says how many were plausible")
        }
    }

    /// A lone result whose title is *not* what the disc says, and whose
    /// length does not fit either, is not chosen — being the only row makes
    /// a wrong pre-selection look like the answer.
    @Test func aLoneResultThatMatchesNeitherTitleNorLengthIsNotChosen() {
        let decision = MovieAutoSelect.decide(
            candidates: [MovieAutoSelect.Candidate(id: 9, title: "Fargo", runtimeMinutes: 60)],
            discDurationSeconds: 98 * 60,
            searchTerm: "Raising Arizona"
        )
        #expect(decision.selectedID == nil)
    }

    /// But a lone result titled exactly what the disc says *is* chosen, even
    /// when the length is well off. That is the deliberate trade after
    /// Wedding Crashers: the title is the stronger signal, a runtime gap is
    /// usually an extended cut, and this is a pre-selection the user can
    /// change with one click.
    @Test func aLoneResultTitledExactlyRightIsChosenDespiteTheLength() {
        let decision = MovieAutoSelect.decide(
            candidates: [MovieAutoSelect.Candidate(id: 275, title: "Fargo", runtimeMinutes: 60)],
            discDurationSeconds: 98 * 60,
            searchTerm: "Fargo"
        )
        #expect(decision.selectedID == 275)
    }

    @Test func aLoneResultOfTheRightLengthIsChosen() {
        let decision = MovieAutoSelect.decide(
            candidates: [MovieAutoSelect.Candidate(id: 275, title: "Fargo", runtimeMinutes: 98)],
            discDurationSeconds: 98 * 60,
            searchTerm: "Fargo"
        )
        #expect(decision.selectedID == 275)
    }

    /// TMDB having no runtime is a real answer, not a zero — a film with no
    /// runtime can never win on runtime.
    @Test func aCandidateWithNoRuntimeIsNeverChosenOnRuntime() {
        let candidates = [
            MovieAutoSelect.Candidate(id: 1, title: "Enemy at the Gates", runtimeMinutes: nil),
            MovieAutoSelect.Candidate(id: 2, title: "Enemy at the Gates", runtimeMinutes: 131),
        ]
        let decision = MovieAutoSelect.decide(
            candidates: candidates, discDurationSeconds: Self.discSeconds, searchTerm: "Enemy at the Gates"
        )
        #expect(decision.selectedID == 2)
    }

    @Test func noResultsIsNoDecision() {
        #expect(MovieAutoSelect.decide(candidates: [], discDurationSeconds: 1000, searchTerm: "x").selectedID == nil)
    }

    // MARK: - Tolerance

    /// A PAL transfer runs about 4% fast, so the tolerance has to absorb it
    /// or correct matches are rejected on ordinary discs.
    @Test func aPALSpeedUpStillMatches() {
        // 131 minutes of film played at 25fps arrives about 4% shorter.
        let pal = Int(Double(131 * 60) / 1.04)
        #expect(MovieAutoSelect.withinTolerance(discSeconds: pal, runtimeMinutes: 131))
    }

    @Test func anHourOutDoesNotMatch() {
        #expect(!MovieAutoSelect.withinTolerance(discSeconds: 131 * 60, runtimeMinutes: 45))
        #expect(!MovieAutoSelect.withinTolerance(discSeconds: 131 * 60, runtimeMinutes: 106))
    }
}

/// Ordering the list by the disc's runtime, so the plausible rows are
/// together at the top whether or not the pre-selection is accepted.
struct MovieAutoSelectRankingTests {

    @Test func theClosestRuntimeLeadsAndTMDBsOrderIsOverridden() {
        // TMDB returned the 2021 film first; the disc runs 131 minutes.
        let ranked = MovieAutoSelect.ranked(
            candidates: MovieAutoSelectTests.enemyAtTheGates,
            discDurationSeconds: MovieAutoSelectTests.discSeconds
        )
        #expect(ranked.first?.id == 853)
    }

    /// Candidates the runtime cannot speak for keep the order TMDB gave
    /// them, rather than being shuffled by a number that does not apply.
    @Test func unmatchedCandidatesKeepTheirOriginalOrder() {
        let candidates = [
            MovieAutoSelect.Candidate(id: 1, title: "A", runtimeMinutes: nil),
            MovieAutoSelect.Candidate(id: 2, title: "B", runtimeMinutes: 200),
            MovieAutoSelect.Candidate(id: 3, title: "C", runtimeMinutes: 131),
            MovieAutoSelect.Candidate(id: 4, title: "D", runtimeMinutes: nil),
        ]
        let ranked = MovieAutoSelect.ranked(candidates: candidates, discDurationSeconds: 131 * 60)
        #expect(ranked.map(\.id) == [3, 1, 2, 4])
    }

    /// With no disc runtime there is nothing to rank by, and TMDB's order
    /// stands untouched.
    @Test func withoutADiscRuntimeNothingIsReordered() {
        let ranked = MovieAutoSelect.ranked(
            candidates: MovieAutoSelectTests.enemyAtTheGates, discDurationSeconds: nil
        )
        #expect(ranked.map(\.id) == MovieAutoSelectTests.enemyAtTheGates.map(\.id))
    }

    /// Two equally close candidates keep their relative order, so the
    /// ranking is stable and a redraw never reshuffles the list.
    @Test func equallyCloseCandidatesKeepTheirRelativeOrder() {
        let candidates = [
            MovieAutoSelect.Candidate(id: 10, title: "First", runtimeMinutes: 131),
            MovieAutoSelect.Candidate(id: 11, title: "Second", runtimeMinutes: 131),
        ]
        let ranked = MovieAutoSelect.ranked(candidates: candidates, discDurationSeconds: 131 * 60)
        #expect(ranked.map(\.id) == [10, 11])
    }
}

/// Wedding Crashers, 2026-09-22 — the auto-select picking the wrong film.
///
/// The disc's settled feature ran 107.7 minutes. The real film runs 119 and
/// failed the tolerance; *Undercover Wedding Crashers* at 101 squeaked
/// through. So the runtime chose a different film with a similar name, the
/// copy already in the library was never looked for, and the disc sat there.
struct MovieAutoSelectContradictionTests {

    static let candidates = [
        MovieAutoSelect.Candidate(id: 9522, title: "Wedding Crashers", runtimeMinutes: 119),
        MovieAutoSelect.Candidate(id: 613098, title: "Undercover Wedding Crashers", runtimeMinutes: 101),
    ]
    /// 107.7 minutes, as the scan settled it.
    static let discSeconds = 6464

    /// The title is the answer. The runtime disagreeing with it means an
    /// extended cut far more often than it means a different film — the disc
    /// in the drive an hour later was literally THE_HANGOVER_EXTENDED_CUT,
    /// which TMDB lists at its theatrical length.
    @Test func theExactlyTitledFilmWinsEvenWhenTheRuntimeDisagrees() {
        let decision = MovieAutoSelect.decide(
            candidates: Self.candidates,
            discDurationSeconds: Self.discSeconds,
            searchTerm: "Wedding Crashers"
        )
        #expect(decision.selectedID == 9522, "the film whose name the disc carries, not the one whose length it happens to share")
    }

    /// An extended cut on its own is still chosen, rather than refused for
    /// running longer than the cinema release.
    @Test func aLoneExtendedCutIsStillChosen() {
        let decision = MovieAutoSelect.decide(
            candidates: [MovieAutoSelect.Candidate(id: 18785, title: "The Hangover", runtimeMinutes: 100)],
            discDurationSeconds: 108 * 60,
            searchTerm: "The Hangover"
        )
        #expect(decision.selectedID == 18785)
    }

    /// The numbers behind it, so a tolerance change shows up here rather than
    /// as a silently different verdict.
    @Test func theRightFilmFailsTheToleranceAndTheWrongOnePasses() {
        #expect(!MovieAutoSelect.withinTolerance(discSeconds: Self.discSeconds, runtimeMinutes: 119))
        #expect(MovieAutoSelect.withinTolerance(discSeconds: Self.discSeconds, runtimeMinutes: 101))
    }

    /// Even with nothing chosen, the list must not lead with the wrong film.
    @Test func theExactlyTitledFilmIsShownFirst() {
        let ranked = MovieAutoSelect.ranked(
            candidates: Self.candidates,
            discDurationSeconds: Self.discSeconds,
            searchTerm: "Wedding Crashers"
        )
        #expect(ranked.first?.id == 9522)
    }

    /// The contradiction rule must not break the case it was built beside:
    /// Enemy at the Gates has two candidates titled exactly alike, and the
    /// runtime is the only thing that separates them.
    @Test func identicalTitlesStillLetTheRuntimeDecide() {
        let decision = MovieAutoSelect.decide(
            candidates: MovieAutoSelectTests.enemyAtTheGates,
            discDurationSeconds: MovieAutoSelectTests.discSeconds,
            searchTerm: "Enemy at the Gates"
        )
        #expect(decision.selectedID == 853)
    }

    /// And a disc with one result whose title matches and whose runtime
    /// agrees is still chosen — the rule only fires on disagreement.
    @Test func agreementIsStillAChoice() {
        let decision = MovieAutoSelect.decide(
            candidates: [MovieAutoSelect.Candidate(id: 275, title: "Fargo", runtimeMinutes: 98)],
            discDurationSeconds: 98 * 60,
            searchTerm: "Fargo"
        )
        #expect(decision.selectedID == 275)
    }
}
