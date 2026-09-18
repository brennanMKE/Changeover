import Foundation
import Testing
@testable import Changeover

/// Tier 3 — the model, and every constraint that makes its answer checkable
/// (`docs/menu-intelligence.md` §4.3).
///
/// **The model is never called here.** Everything that decides whether to ask,
/// what to ask, and what an answer is allowed to mean is a pure function over
/// plain values; the one call that reaches Foundation Models is the four lines
/// this suite does not touch. That is deliberate: a test that depended on
/// Apple Intelligence being enabled would be skipped on the test host and
/// prove nothing on the dev Mac either.
struct MenuJudgeTests {

    private static func button(_ menu: String, _ number: Int, title: Int) -> ResolvedButton {
        ResolvedButton(
            ref: MenuButtonRef(menu: menu, number: number),
            rect: PixelRect(minX: 0, minY: 0, maxX: 100, maxY: 20),
            autoAction: false,
            command: VMCommand(bytes: [0, 0, 0, 0, 0, 0, 0, 0]),
            target: .title(title),
            onEntryMenu: true,
            entryType: "root"
        )
    }

    private static let two = [button("m", 1, title: 1), button("m", 2, title: 4)]
    private static let twoLabels: [MenuButtonRef: String] = [
        MenuButtonRef(menu: "m", number: 1): "Sehen Sie den Film",
        MenuButtonRef(menu: "m", number: 2): "Zusatzmaterial",
    ]

    // MARK: - When it is asked at all

    /// One candidate is the structure's own answer. The model adds nothing
    /// and is not asked.
    @Test func oneCandidateIsNeverAsked() {
        let one = [Self.button("m", 1, title: 1)]
        let labels = [MenuButtonRef(menu: "m", number: 1): "Lecture"]
        #expect(MenuJudge.question(candidates: one, labels: labels) == nil)
    }

    /// A disc whose words the lexicon already knows needs no model: exactly
    /// one play label among the candidates is a deterministic answer.
    @Test func aLexiconHitIsNeverAsked() {
        let labels: [MenuButtonRef: String] = [
            MenuButtonRef(menu: "m", number: 1): "Lecture",
            MenuButtonRef(menu: "m", number: 2): "Bande-annonce",
        ]
        #expect(MenuJudge.question(candidates: Self.two, labels: labels) == nil)
    }

    /// Two title-jumping buttons whose labels the table has never met — the
    /// one case the model exists for.
    @Test func twoUnknownLabelsAreAsked() throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        #expect(question.labels == ["Sehen Sie den Film", "Zusatzmaterial"])
        #expect(question.titles == [1, 4])
    }

    /// An unlabelled button gives the model nothing to read, so a picture-only
    /// menu is never asked about.
    @Test func unlabelledButtonsAreNotAsked() {
        #expect(MenuJudge.question(candidates: Self.two, labels: [:]) == nil)
    }

    /// "Play" and "Play with commentary" target the same title and differ by
    /// a stream command; the caption would be identical either way, so they
    /// collapse and nothing is asked.
    @Test func buttonsOnTheSameTitleCollapse() {
        let same = [Self.button("m", 1, title: 1), Self.button("m", 2, title: 1)]
        let labels: [MenuButtonRef: String] = [
            MenuButtonRef(menu: "m", number: 1): "Wiedergabe",
            MenuButtonRef(menu: "m", number: 2): "Wiedergabe mit Kommentar",
        ]
        #expect(MenuJudge.question(candidates: same, labels: labels) == nil)
    }

    /// A button pointing at a title the scan never found is dropped before
    /// the model sees it — tier 1 fences tier 3's input, not just its output.
    @Test func aTitleTheScanDoesNotHaveIsNotOffered() {
        #expect(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels, scanTitles: [1]) == nil)
    }

    // MARK: - The closed set

    /// **The falsification.** The schema is the disc's own labels plus "none
    /// of these", and nothing else may come back. A paraphrase, a
    /// translation, a title index, a sentence, an empty string — every one of
    /// them is "no answer", never a nearest match.
    @Test(arguments: [
        "Play Movie",
        "sehen sie den film",
        "Sehen Sie den Film!",
        "1",
        "title 1",
        "The first one, \"Sehen Sie den Film\"",
        "",
    ])
    func anythingOutsideTheClosedSetIsNoAnswer(pick: String) throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        guard case .unavailable = MenuJudge.interpret(pick: pick, question: question) else {
            Issue.record("\(pick) was accepted as an answer")
            return
        }
    }

    @Test func anExactLabelIsAnIndexIntoTheLabelsNotATitle() throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        #expect(MenuJudge.interpret(pick: "Zusatzmaterial", question: question) == .chose(labelIndex: 1))
    }

    @Test func noneOfTheseIsAFirstClassAnswer() throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        #expect(MenuJudge.interpret(pick: MenuJudge.noneLabel, question: question) == .none)
        #expect(question.choices.last == "none of these")
        #expect(question.choices.count == question.labels.count + 1)
    }

    // MARK: - The caption

    /// The answer only ever becomes a sentence, and the sentence says the
    /// scan is still in charge.
    @Test func theCaptionNamesTheButtonAndDefersToTheScan() throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        let caption = try #require(MenuJudge.caption(.chose(labelIndex: 0), question: question, scanTitles: [1, 4]))
        #expect(caption.contains("Sehen Sie den Film"))
        #expect(caption.contains("title 1"))
        #expect(caption.contains("The scan still chooses what is encoded."))
    }

    /// Tier 1 has the final word: a chosen label whose button does not
    /// resolve to a title the scan found produces no caption at all.
    @Test func aChoiceThatResolvesToNoRealTitleIsDropped() throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        #expect(MenuJudge.caption(.chose(labelIndex: 1), question: question, scanTitles: [1]) == nil)
    }

    @Test func noneAndUnavailableBothSayNothing() throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        #expect(MenuJudge.caption(.none, question: question, scanTitles: [1, 4]) == nil)
        #expect(MenuJudge.caption(.unavailable("model off"), question: question, scanTitles: [1, 4]) == nil)
    }

    /// An index outside the question is impossible through `interpret`, and
    /// still refused here — the map is belt and braces, as the design says.
    @Test func anOutOfRangeIndexIsRefused() throws {
        let question = try #require(MenuJudge.question(candidates: Self.two, labels: Self.twoLabels))
        #expect(MenuJudge.caption(.chose(labelIndex: 7), question: question, scanTitles: [1, 4]) == nil)
    }

    // MARK: - What is sent

    @Test func thePromptCarriesOnlyTheButtonsAndTheEscapeHatch() throws {
        let question = try #require(MenuJudge.question(
            candidates: Self.two, labels: Self.twoLabels, menuTitleText: "Hauptmenü"
        ))
        #expect(question.prompt.contains("\"Sehen Sie den Film\""))
        #expect(question.prompt.contains("\"none of these\""))
        #expect(question.prompt.contains("Hauptmenü"))
    }

    @Test func theInstructionsOfferTheEscapeHatch() {
        #expect(MenuJudge.instructions.contains("none of these"))
        #expect(MenuJudge.instructions.contains("not a trailer"))
    }
}
