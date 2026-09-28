import Foundation
import Testing
@testable import Changeover

/// #0159 — letting the on-device model name more than one film.
///
/// Pinned against the two real double features in the corpus, using their own
/// captured OCR: Get Hard / The Campaign (`7000078778_1`, a catalogue number
/// for a label) and Uncle Buck / The Great Outdoors. Nothing here calls
/// Foundation Models — the instructions are a string and the parser is a pure
/// function, which is the whole reason they are separated from `ask`.
@Suite struct MultiTitleInferenceTests {

    private static func discFixture(_ slug: String, _ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/\(slug)/\(relativePath)")
    }

    private static func ocr(_ slug: String) throws -> MenuOCRDocument {
        try MenuOCRDocument.decode(Data(contentsOf: discFixture(slug, "menus/ocr.json")))
    }

    /// The structural count the caller passes in, computed the way the app
    /// computes it: HandBrake's own scan through `DiscTitleHeuristic`.
    private static func structuralFeatureCount(_ slug: String, volumeName: String) throws -> Int? {
        let text = try String(contentsOf: discFixture(slug, "scan.json"), encoding: .utf8)
        let output = HandBrakeScanParser.parse(text, volumeName: volumeName, driveName: "joe")
        return DiscTitleHeuristic.severalFeatures(output.disc)?.count
    }

    // MARK: - Get Hard / The Campaign, as captured

    /// The evidence the instructions lean on has to survive into the prompt.
    ///
    /// This disc's entry menu prints PLAY / WITH ENGLISH SUBTITLES / WITH
    /// SPANISH SUBTITLES **twice**, once per film, on one still. That
    /// repetition is the disc telling us it holds two features, and
    /// `DiscTitleInference`'s global dedupe — correct for a question that
    /// wants one title — deletes it. The contrast is asserted both ways so
    /// nobody "tidies" the multi-title builder into reusing the other one.
    @Test func theRepeatedMenuBlockSurvivesIntoTheMultiTitlePrompt() throws {
        let ocr = try Self.ocr("get-hard-campaign")

        let multi = try #require(MultiTitleInference.question(volumeName: "7000078778_1", ocr: ocr))
        #expect(multi.lines.filter { $0 == "PLAY" }.count == 2)
        #expect(multi.lines.filter { $0 == "WITH SPANISH SUBTITLES" }.count == 2)

        let single = try #require(DiscTitleInference.question(volumeName: "7000078778_1", ocr: ocr))
        #expect(single.lines.filter { $0 == "PLAY" }.count == 1)
    }

    /// Both films' text reaches the model, damage and all.
    @Test func theGetHardPromptCarriesBothFilmsAsTheDiscPrintedThem() throws {
        let question = try #require(
            MultiTitleInference.question(volumeName: "7000078778_1", ocr: Self.ocr("get-hard-campaign"))
        )
        #expect(question.lines.contains("• GET HARD"))
        // `DEÇAMPAGNI` on screen, read as this by Vision. Kept verbatim.
        #expect(question.lines.contains("DECAMPAIGNI"))
        #expect(question.prompt.contains("7000078778_1"))
        #expect(question.prompt.contains("One title per line"))
    }

    /// The reply this prompt actually produced on real hardware, 2026-09-27,
    /// parsed.
    ///
    /// "Decampagne" is wrong — the film is The Campaign — and the parser
    /// keeps it anyway. Repairing OCR damage is the model's job and it did
    /// not do it here; a parser that silently dropped the line would turn a
    /// visible limitation into a disc that quietly has one film again, which
    /// is the failure #0157 and this ticket both exist to end.
    @Test func theMeasuredGetHardReplyNamesTwoFilms() throws {
        let reading = MultiTitleInference.reading(from: "Get Hard\nDecampagne", expecting: 2)
        #expect(reading.titles == ["Get Hard", "Decampagne"])
        #expect(reading.agreement == .asExpected)
    }

    /// What the single-title prompt produced on the same disc, for contrast:
    /// one film, and the other structurally unreachable.
    @Test func theSingleTitleReplyStillNamesOnlyOneFilm() {
        let reading = MultiTitleInference.reading(from: "GET HARD", expecting: 2)
        #expect(reading.titles == ["GET HARD"])
        #expect(reading.agreement == .fewer(found: 1, expected: 2))
    }

    // MARK: - Uncle Buck / The Great Outdoors, as captured

    /// This disc does not make anyone infer the structure: it prints it.
    @Test func theUncleBuckMenuAnnouncesItsOwnStructure() throws {
        let question = try #require(
            MultiTitleInference.question(
                volumeName: "UNCLE_BUCK_GREAT_OUTDOORS",
                ocr: Self.ocr("uncle-buck-great-outdoors")
            )
        )
        #expect(question.lines.contains("PLEASE SELECT FEATURE TO VIEW:"))
        // Both titles, both mangled — Vision read them off a painted menu.
        #expect(question.lines.contains("GÄT OUDOORS"))
        #expect(question.lines.contains("Unde ßuck"))
        #expect(MultiTitleInference.instructions.contains("PLEASE SELECT FEATURE TO VIEW"))
    }

    @Test func theUncleBuckReplyNamesTwoFilms() {
        let reading = MultiTitleInference.reading(
            from: "Uncle Buck\nThe Great Outdoors",
            expecting: 2
        )
        #expect(reading.titles == ["Uncle Buck", "The Great Outdoors"])
        #expect(reading.agreement == .asExpected)
    }

    // MARK: - The count the caller passes in

    /// The expected count is not a constant in a test — it is what the app's
    /// own structural rule says about these two captures.
    @Test(arguments: [
        ("get-hard-campaign", "7000078778_1"),
        ("uncle-buck-great-outdoors", "UNCLE_BUCK_GREAT_OUTDOORS"),
    ])
    func theStructuralCountForBothRealDoubleFeaturesIsTwo(slug: String, volumeName: String) throws {
        #expect(try Self.structuralFeatureCount(slug, volumeName: volumeName) == 2)
    }

    // MARK: - A mismatch is information, never a truncation

    /// Three titles against a two-feature disc stay three. The caller is told
    /// they disagree and asks a person; it is not handed a tidy pair with the
    /// third answer deleted.
    @Test func moreTitlesThanFeaturesAreAllKept() {
        let reading = MultiTitleInference.reading(
            from: "Get Hard\nThe Campaign\nThe Other Guys",
            expecting: 2
        )
        #expect(reading.titles.count == 3)
        #expect(reading.agreement == .more(found: 3, expected: 2))
    }

    /// No structural count is not the same as agreement.
    @Test func noExpectedCountReportsUnknownRatherThanAgreement() {
        let reading = MultiTitleInference.reading(from: "Get Hard", expecting: nil)
        #expect(reading.expected == nil)
        #expect(reading.agreement == .unknown)
    }

    // MARK: - Edge cases in what the model says

    @Test func anEmptyReplyNamesNothing() {
        #expect(MultiTitleInference.titles(from: "") == [])
        #expect(MultiTitleInference.titles(from: "   \n\n  \n") == [])
        #expect(MultiTitleInference.reading(from: "", expecting: 2).agreement
                == .fewer(found: 0, expected: 2))
    }

    /// `NONE` is the instructed refusal and must not become a film.
    @Test func aRefusalNamesNothing() {
        #expect(MultiTitleInference.titles(from: "NONE") == [])
        #expect(MultiTitleInference.titles(from: "none\nNone") == [])
    }

    /// A single-feature disc answered here still works: one line, one film.
    @Test func oneTitleIsAValidReply() {
        #expect(MultiTitleInference.titles(from: "Enemy at the Gates") == ["Enemy at the Gates"])
        #expect(MultiTitleInference.titles(from: "  Enemy at the Gates  \n") == ["Enemy at the Gates"])
    }

    /// Told not to number its lines, the model numbers its lines.
    @Test func numberingAndBulletsAreStrippedRatherThanRejected() {
        #expect(MultiTitleInference.titles(from: "1. Get Hard\n2. The Campaign")
                == ["Get Hard", "The Campaign"])
        #expect(MultiTitleInference.titles(from: "1) Get Hard\n2) The Campaign")
                == ["Get Hard", "The Campaign"])
        #expect(MultiTitleInference.titles(from: "(1) Get Hard\n(2) The Campaign")
                == ["Get Hard", "The Campaign"])
        #expect(MultiTitleInference.titles(from: "- Get Hard\n* The Campaign\n• Uncle Buck")
                == ["Get Hard", "The Campaign", "Uncle Buck"])
    }

    /// Four digits are not a list marker: `1917` is a film, and a disc
    /// labelled `1917` is in the corpus. It still reaches no search box from
    /// here — `sanitize` refuses a letterless answer on both paths, and that
    /// title is recovered from the *label* by
    /// `DiscTitleInference.labelAsSearchTerm`, not from a model's reply.
    @Test func aNumericLineIsNotTreatedAsListNumbering() {
        #expect(MultiTitleInference.stripListMarker("1917") == "1917")
        #expect(MultiTitleInference.titles(from: "1917") == [])
    }

    @Test func repeatedTitlesAreNamedOnce() {
        #expect(MultiTitleInference.titles(from: "Get Hard\nGET HARD\nget hard") == ["Get Hard"])
        #expect(MultiTitleInference.titles(from: "Get Hard\nThe Campaign\nGet hard")
                == ["Get Hard", "The Campaign"])
    }

    /// A model that will not stop explaining itself.
    @Test func commentaryAroundTheTitlesIsDropped() {
        let reply = """
        This disc holds two films:
        1. Get Hard
        2. The Campaign
        Both are comedies starring Will Ferrell.
        """
        #expect(MultiTitleInference.titles(from: reply) == ["Get Hard", "The Campaign"])
    }

    /// `sanitize`'s preamble and year rules, reused per line rather than
    /// reimplemented.
    @Test func preamblesQuotesAndYearsAreStrippedPerLine() {
        #expect(MultiTitleInference.titles(from: "Get Hard (2015)\n\"The Campaign\"")
                == ["Get Hard", "The Campaign"])
        #expect(MultiTitleInference.titles(from: "The film is Get Hard") == ["Get Hard"])
    }

    /// The catalogue-number rule, enforced twice: the instructions say it,
    /// and `sanitize`'s "must contain a letter" refuses it even if the model
    /// ignores them.
    @Test func aCatalogueNumberIsNotATitle() {
        #expect(MultiTitleInference.instructions.contains("7000078778_1"))
        #expect(MultiTitleInference.titles(from: "7000078778_1\nGet Hard") == ["Get Hard"])
    }

    /// A model that starts transcribing the menu is stopped, well above the
    /// four features a disc can structurally hold.
    @Test func aRunawayReplyIsCapped() {
        let reply = (1...20).map { "Film Number \($0)" }.joined(separator: "\n")
        let reading = MultiTitleInference.reading(from: reply, expecting: 2)
        #expect(reading.titles.count == MultiTitleInference.maximumTitles)
        #expect(MultiTitleInference.maximumTitles > DiscTitleHeuristic.maximumFeaturesPerDisc)
        #expect(reading.agreement == .more(found: 8, expected: 2))
    }

    // MARK: - The single-title path is untouched

    /// #0159 adds a second mode. `DiscTitleInference` still asks for one
    /// title, still answers with one, and still throws away everything after
    /// the first line — which is exactly why it needed a sibling rather than
    /// an edit.
    @Test func theSingleTitlePathStillAsksForOneTitleAndKeepsOneLine() {
        #expect(DiscTitleInference.instructions.contains("Reply with the film's title and nothing else"))
        #expect(DiscTitleInference.sanitize("Get Hard\nThe Campaign") == "Get Hard")
    }

    /// The new instructions say the opposite, in as many words.
    @Test func theMultiTitleInstructionsAskForOneLinePerFilm() {
        let text = MultiTitleInference.instructions
        #expect(text.contains("A disc may hold more than one film"))
        #expect(text.contains("one film title per line"))
        #expect(text.contains("WITH SPANISH SUBTITLES"))
        #expect(text.contains("OCR"))
        #expect(text.contains("SCENE SELECTION"))
    }
}
