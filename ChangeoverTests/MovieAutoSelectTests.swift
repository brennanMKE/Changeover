import Foundation
import Testing
@testable import Changeover

/// Searching "Enemy at the Gates" returns three films whose titles cannot
/// separate them. The disc's own runtime can.
struct MovieAutoSelectTests {

    /// The real result set, as TMDB returned it on 2026-09-22, with the
    /// runtimes a details lookup gives. The disc's feature runs 131 minutes.
    static let enemyAtTheGates = [
        MovieAutoSelect.Candidate(id: 874214, title: "Enemy at the Gates", runtimeMinutes: 8),
        MovieAutoSelect.Candidate(id: 853, title: "Enemy at the Gates", runtimeMinutes: 131),
        MovieAutoSelect.Candidate(id: 1556038, title: "Enemy at the Gates Iran's Threat to America", runtimeMinutes: 45),
    ]
    static let discSeconds = 131 * 60

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

    /// A single result that is the wrong length is the case where a
    /// confident pre-selection does the most harm: it is the only row, so it
    /// looks like the answer.
    @Test func aLoneResultOfTheWrongLengthIsNotChosen() {
        let decision = MovieAutoSelect.decide(
            candidates: [MovieAutoSelect.Candidate(id: 9, title: "Fargo", runtimeMinutes: 60)],
            discDurationSeconds: 98 * 60,
            searchTerm: "Fargo"
        )
        #expect(decision.selectedID == nil)
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
        #expect(!MovieAutoSelect.withinTolerance(discSeconds: 131 * 60, runtimeMinutes: 8))
    }
}
