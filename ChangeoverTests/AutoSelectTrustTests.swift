import Testing
@testable import Changeover

/// #0070 — the half of the Walter Mitty failure that matching could never
/// have caught.
@Suite struct AutoSelectTrustTests {

    private static let caretaker = MovieAutoSelect.Candidate(
        id: 1495638, title: "The Caretaker", runtimeMinutes: 114)

    /// The disc ran 6868s (114m). TMDB really does list a 2026 film called
    /// The Caretaker at 114 minutes. Title agreed, runtime agreed, one
    /// candidate — the matching worked perfectly on a question nobody had
    /// checked, and with automatic ripping on it would have filed Walter
    /// Mitty under the wrong film.
    @Test func aPerfectMatchOnAnUncorroboratedTermIsNotSelected() {
        let decision = MovieAutoSelect.decide(
            candidates: [Self.caretaker], discDurationSeconds: 6868,
            searchTerm: "The Caretaker", trust: .unverified)
        #expect(decision.selectedID == nil, "nothing outside the guess agreed with it")
    }

    /// The identical evidence, with the label behind it, still selects —
    /// the gate must not cost the discs that already work.
    @Test func theSameMatchIsSelectedWhenTheLabelBacksIt() {
        let decision = MovieAutoSelect.decide(
            candidates: [Self.caretaker], discDurationSeconds: 6868,
            searchTerm: "The Caretaker", trust: .labelBacked)
        #expect(decision.selectedID == 1495638)
    }

    /// Ranking is untouched: the best row is still known, so it can be shown
    /// as a recommendation. Withholding the *choice* is the whole change.
    @Test func theBestRowIsStillIdentifiedForRecommending() {
        let ranked = MovieAutoSelect.rank(
            candidates: [Self.caretaker], discDurationSeconds: 6868,
            searchTerm: "The Caretaker")
        #expect(ranked.selectedID == 1495638)
    }

    /// Existing callers and tests predate the gate and must behave exactly as
    /// before.
    @Test func trustDefaultsToLabelBacked() {
        let decision = MovieAutoSelect.decide(
            candidates: [Self.caretaker], discDurationSeconds: 6868,
            searchTerm: "The Caretaker")
        #expect(decision.selectedID == 1495638)
    }

    /// An abstention stays an abstention — the gate only ever removes a
    /// selection, never adds one.
    @Test func theGateNeverTurnsAnAbstentionIntoAChoice() {
        let decision = MovieAutoSelect.decide(
            candidates: [], discDurationSeconds: 6868,
            searchTerm: "Anything", trust: .unverified)
        #expect(decision.selectedID == nil)
    }

    /// A refused selection has to say what was missing, since the user is now
    /// the one deciding.
    @Test func theReasonNamesTheMissingCorroboration() throws {
        let decision = MovieAutoSelect.decide(
            candidates: [Self.caretaker], discDurationSeconds: 6868,
            searchTerm: "The Caretaker", trust: .unverified)
        guard case .abstain(let reason) = decision else {
            Issue.record("expected an abstention"); return
        }
        #expect(reason.contains("menus"))
    }
}
