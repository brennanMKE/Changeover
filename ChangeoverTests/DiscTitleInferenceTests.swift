import Foundation
import Testing
@testable import Changeover

/// The model is never run here. What is tested is everything around it: the
/// question built from a real disc's menu text, and the sanitising of what a
/// small model hands back.
struct DiscTitleInferenceTests {

    /// Enemy at the Gates, as actually captured: the title appears nowhere in
    /// plain type except inside a bonus feature's name.
    static let eatgLines = [
        "*** SPECIAL FEATURES", "* THEATRICAL TRAILER", "* THROUGH THE CROSSHAIRS",
        "* INSIDE ENEMY AT THE GATES", "ADDITIONAL SCENES", "* MAIN MENU",
        "*SCENE SELECTION", "1. The Wolf Hunter", "2. Crossing The Volga",
        "AUDIO OPTIONS", "* ENGLISH 5.1 SURROUND", "CAPTIONS, INC. LOS ANGELES",
    ]

    static func ocr(_ lines: [String]) -> MenuOCRDocument {
        MenuOCRDocument(
            format: "changeover-menu-ocr/1",
            engine: MenuOCRDocument.Engine(
                framework: "Vision", api: "VNRecognizeTextRequest", os: "test",
                level: "accurate", languageCorrection: false, languages: ["en"],
                customWords: 0, upscale: 1, minimumTextHeightFraction: 0.02
            ),
            note: nil,
            stills: [
                MenuOCRDocument.Still(
                    id: "vtsm-03-lu1-pgc12",
                    frame: MenuStructure.Frame(width: 720, height: 480, standard: "NTSC"),
                    note: nil,
                    observations: lines.enumerated().map { index, text in
                        TextObservation(text: text, confidence: 1,
                                        rect: PixelRect(minX: 10, minY: index * 20,
                                                        maxX: 400, maxY: index * 20 + 18))
                    }
                ),
            ]
        )
    }

    // MARK: - The question

    @Test func theQuestionCarriesTheLabelAndTheDiscsOwnWords() throws {
        let question = try #require(
            DiscTitleInference.question(volumeName: "ENEMYATTHEGATES", ocr: Self.ocr(Self.eatgLines))
        )
        #expect(question.volumeName == "ENEMYATTHEGATES")
        #expect(question.lines.contains("* INSIDE ENEMY AT THE GATES"))
        #expect(question.prompt.contains("ENEMYATTHEGATES"))
        #expect(question.prompt.contains("INSIDE ENEMY AT THE GATES"))
        #expect(question.prompt.contains("What film is on this disc?"))
    }

    /// Nothing derived goes in — only what the disc printed — so a wrong
    /// answer can always be traced to something that was on screen.
    @Test func theQuestionCarriesNothingButTheDiscsText() throws {
        let question = try #require(
            DiscTitleInference.question(volumeName: "FARGO_WS", ocr: Self.ocr(["PLAY", "PLAY", "SETUP"]))
        )
        #expect(question.lines == ["PLAY", "SETUP"], "repeats are dropped")
    }

    @Test func aDiscWithNoReadableMenuTextAsksNothing() {
        #expect(DiscTitleInference.question(volumeName: "X", ocr: nil) == nil)
        #expect(DiscTitleInference.question(volumeName: "X", ocr: Self.ocr([])) == nil)
        #expect(DiscTitleInference.question(volumeName: "X", ocr: Self.ocr(["***", "---"])) == nil,
                "punctuation is not text")
    }

    // MARK: - What comes back

    @Test func aPlainTitleSurvivesUnchanged() {
        #expect(DiscTitleInference.sanitize("Enemy at the Gates") == "Enemy at the Gates")
    }

    /// Everything a small model does to a one-line answer.
    @Test func theUsualDecorationIsStripped() {
        #expect(DiscTitleInference.sanitize("\"Enemy at the Gates\"") == "Enemy at the Gates")
        #expect(DiscTitleInference.sanitize("The film is Enemy at the Gates") == "Enemy at the Gates")
        #expect(DiscTitleInference.sanitize("Enemy at the Gates (2001)") == "Enemy at the Gates")
        #expect(DiscTitleInference.sanitize("Title: Enemy at the Gates") == "Enemy at the Gates")
        #expect(DiscTitleInference.sanitize("Enemy at the Gates\nIt is a 2001 war film.") == "Enemy at the Gates")
    }

    @Test func noAnswerIsRefusedInItsSeveralSpellings() {
        #expect(DiscTitleInference.sanitize("NONE") == nil)
        #expect(DiscTitleInference.sanitize("none") == nil)
        #expect(DiscTitleInference.sanitize("\"NONE\"") == nil)
        #expect(DiscTitleInference.sanitize("") == nil)
        #expect(DiscTitleInference.sanitize("   ") == nil)
    }

    /// An explanation that slipped past the first-line rule is not a title.
    @Test func aSentenceIsNotATitle() {
        #expect(DiscTitleInference.sanitize(
            "I am not able to determine which film this disc contains from the menus"
        ) == nil)
        #expect(DiscTitleInference.sanitize(String(repeating: "a", count: 200)) == nil)
    }

    @Test func theModelIsNeverAskedWhenTheFrameworkIsAbsent() async {
        // On a machine without Apple Intelligence this is the whole contract:
        // an answer that changes nothing.
        let question = DiscTitleInference.Question(volumeName: "X", lines: ["Y"])
        let answer = await DiscTitleInference.answer(for: question)
        if case .unavailable = answer { return }
        // With a model present a real title is also acceptable — this test
        // asserts only that it never throws and never returns junk.
        #expect(answer.title != nil)
    }
}
