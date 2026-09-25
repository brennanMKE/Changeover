import Testing
@testable import Changeover

/// #0072 — "silence is not agreement".
///
/// `answerFitsLabel` answers a veto question: is there grounds to reject?
/// Both "the label agrees" and "the label cannot judge" answer no, and
/// collapsing them meant a label with nothing to say was read as a label
/// vouching for the answer.
@Suite struct LabelVerdictTests {

    /// The failure that named this. USUALLB is seven characters and can
    /// spell nothing; the model's "THE USUAL SUSPECTS" was right, and the
    /// label backed none of it.
    @Test func aShortLabelCannotJudge() {
        #expect(DiscTitleInference.labelVerdict(
            on: "The Usual Suspects", volumeName: "USUALLB") == .cannotJudge)
    }

    /// Real corroboration: the label spells the title.
    @Test func aLabelThatSpellsTheTitleAgrees() {
        #expect(DiscTitleInference.labelVerdict(
            on: "Enemy at the Gates", volumeName: "ENEMYATTHEGATES") == .agrees)
        #expect(DiscTitleInference.labelVerdict(
            on: "The Secret Life of Walter Mitty",
            volumeName: "THESECRETLIFEOFWALTERMITTY") == .agrees)
    }

    /// The Caretaker. The label spells a different film, so the answer is
    /// rejected outright — unchanged by this split.
    @Test func aLabelThatSpellsADifferentFilmDisagrees() {
        #expect(DiscTitleInference.labelVerdict(
            on: "The Caretaker", volumeName: "THESECRETLIFEOFWALTERMITTY") == .disagrees)
    }

    /// Box-set and format labels have no standing, and must not be read as
    /// objections — the Willis regression.
    @Test func actorAndFormatLabelsCannotJudge() {
        #expect(DiscTitleInference.labelVerdict(
            on: "The Whole Nine Yards", volumeName: "WILLIS") == .cannotJudge)
        #expect(DiscTitleInference.labelVerdict(
            on: "Underworld", volumeName: "DVD_VIDEO") == .cannotJudge)
    }

    /// The veto is unchanged: only a disagreement rejects. This is what keeps
    /// the Willis and Blusbro discs working.
    @Test func onlyADisagreementVetoes() {
        #expect(DiscTitleInference.answerFitsLabel("The Whole Nine Yards", volumeName: "WILLIS"))
        #expect(DiscTitleInference.answerFitsLabel("The Usual Suspects", volumeName: "USUALLB"))
        #expect(DiscTitleInference.answerFitsLabel("Enemy at the Gates", volumeName: "ENEMYATTHEGATES"))
        #expect(!DiscTitleInference.answerFitsLabel(
            "The Caretaker", volumeName: "THESECRETLIFEOFWALTERMITTY"))
    }

    /// Containment runs both ways: a label may drop a leading "The" or carry
    /// an authoring suffix, and both are agreement.
    @Test func agreementIsContainmentInEitherDirection() {
        #expect(DiscTitleInference.labelVerdict(
            on: "The Secret of My Success", volumeName: "SECRET_OF_MY_SUCCESS") == .agrees)
        #expect(DiscTitleInference.labelVerdict(
            on: "Live Free or Die Hard", volumeName: "LIVEFREE_OR_DIEHARD_BRANCH") == .agrees)
    }

    /// An empty answer is not something a judging label can agree with.
    @Test func anEmptyAnswerDisagrees() {
        #expect(DiscTitleInference.labelVerdict(
            on: "", volumeName: "THESECRETLIFEOFWALTERMITTY") == .disagrees)
    }
}
