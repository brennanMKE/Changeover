import Foundation
import Testing
@testable import Changeover

/// #0175 — asking a disc several questions instead of one, and believing only
/// what it can corroborate.
///
/// Both real discs are here, with their captured OCR and their scanned
/// runtimes, and the model is stubbed with answers measured from the real one
/// on joe — including the answers it got wrong, because the point of this
/// design is that a wrong answer is caught rather than acted on.
@Suite struct DiscInterrogationTests {

    private static func title(_ index: Int, seconds: Int, aspect: Double = 1.33) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil, displayAspect: aspect)
    }

    // MARK: - The two real discs

    /// Signs: the film, a 58:54 bonus reel, six named featurettes.
    static var signs: DiscEvidence {
        DiscEvidence(
            volumeName: "Signs",
            menuPages: [
                ["play", "bonus", "scenes", "set up"],
                ["play all", "looking for Signs (6:11)", "building Signs (8:02)",
                 "making Signs: a commentary", "by M. Night Shyamalan (22:33)",
                 "the effects of Signs (8:31)", "last voices: the music›",
                 "of Signs (8:26)", "full circle (4:48)"],
            ],
            titles: [
                title(1, seconds: 6385, aspect: 1.78),
                title(8, seconds: 3534), title(9, seconds: 375), title(10, seconds: 485),
                title(11, seconds: 1357), title(12, seconds: 516), title(13, seconds: 510),
                title(14, seconds: 291),
            ],
            mainFeatureIndex: 1)
    }

    /// Get Hard / The Campaign: two films, one menu, no extras named.
    static var doubleFeature: DiscEvidence {
        DiscEvidence(
            volumeName: "7000078778_1",
            menuPages: [["KEVN MART", "GET HARD", "D°ÇAMPAIGN", "PLAY",
                         "WITH ENGLISH SUBTITLES", "WITH SPANISH SUBTITLES",
                         "PLAY", "WITH ENGLISH SUBTITLES", "WITH SPANISH SUBTITLES"]],
            titles: [title(4, seconds: 5122, aspect: 1.78),
                     title(5, seconds: 6012, aspect: 1.78)],
            mainFeatureIndex: nil)
    }

    // MARK: - Evidence

    /// Repetition within one menu page survives; repetition across pages does
    /// not. The repeated PLAY block is the double-feature signal.
    @Test func repetitionWithinAPageIsKept() {
        func still(_ id: String, _ lines: [String]) -> MenuOCRDocument.Still {
            MenuOCRDocument.Still(
                id: id,
                frame: MenuStructure.Frame(width: 720, height: 480, standard: "NTSC"),
                note: nil,
                observations: lines.enumerated().map { index, text in
                    TextObservation(text: text, confidence: 1,
                                    rect: PixelRect(minX: 10, minY: index * 20,
                                                    maxX: 400, maxY: index * 20 + 18))
                })
        }
        let ocr = MenuOCRDocument(
            format: "changeover-menu-ocr/1",
            engine: MenuOCRDocument.Engine(
                framework: "Vision", api: "VNRecognizeTextRequest", os: "test",
                level: "accurate", languageCorrection: false, languages: ["en"],
                customWords: 0, upscale: 1, minimumTextHeightFraction: 0.02),
            note: nil,
            stills: [still("a", ["PLAY", "PLAY"]), still("b", ["PLAY"])])
        let evidence = DiscEvidence.make(
            volumeName: "X", ocr: ocr,
            disc: DiscInfo(volumeName: "X", driveName: "d", titles: []),
            mainFeatureIndex: nil)
        #expect(evidence.menuPages.first?.count == 2, "both PLAYs on one screen are kept")
        #expect(evidence.menuPages.count == 1, "the second screen's repeat is furniture")
    }

    // MARK: - The prompts

    /// Each question is shown what it can use, and nothing else.
    @Test func theFilmsQuestionSeesMenusAndTheExtrasQuestionSeesRuntimes() {
        let films = DiscInterrogation.prompt(.films, evidence: Self.signs)
        let extras = DiscInterrogation.prompt(.extras, evidence: Self.signs)
        #expect(films.contains("looking for Signs"))
        #expect(!films.contains("title 11"), "a film is not chosen by title number")
        #expect(extras.contains("title 11"), "an extra is checked against runtimes")
    }

    @Test func everyQuestionIsToldWhatIsNotContent() {
        for question in DiscInterrogation.Question.allCases {
            let text = DiscInterrogation.instructions(for: question)
            #expect(text.contains("SCENE SELECTION"))
            #expect(text.contains("NONE"))
        }
    }

    // MARK: - Reading replies

    @Test func atrailingRuntimeIsPulledOffTheClaim() throws {
        let claims = DiscInterrogation.claims(
            from: "The Making of Signs (58:54)\nlooking for Signs (6:11)", question: .extras)
        #expect(claims.count == 2)
        #expect(claims[0].label == "The Making of Signs")
        #expect(claims[0].seconds == 3534)
        #expect(claims[1].seconds == 371)
    }

    @Test func aplainTitleWithNoRuntimeIsStillAClaim() {
        let claims = DiscInterrogation.claims(from: "Get Hard", question: .films)
        #expect(claims.map(\.label) == ["Get Hard"])
        #expect(claims[0].seconds == nil)
    }

    @Test func noneAndCommentaryAreNotClaims() {
        #expect(DiscInterrogation.claims(from: "NONE", question: .films).isEmpty)
        #expect(DiscInterrogation.claims(
            from: "The films on this disc are:", question: .films).isEmpty)
    }

    @Test func aruawayReplyIsCapped() {
        let reply = (1...40).map { "Thing \($0) (0:3\($0 % 10))" }.joined(separator: "\n")
        #expect(DiscInterrogation.claims(from: reply, question: .extras).count
                <= DiscInterrogation.maximumClaimsPerQuestion)
    }

    // MARK: - Verification is the whole safety story

    /// The invented answers, measured from the real model on joe. Neither
    /// carries a runtime the disc agrees with, so neither becomes a finding.
    @Test func inventedFilmsAreNotBelieved() {
        let claims = [
            DiscInterrogation.Claim(question: .bonusFeature, label: "DREAMSCAPE", seconds: 9_999),
            DiscInterrogation.Claim(question: .bonusFeature, label: "DREAMLAND", seconds: 1),
        ]
        let (findings, unverified) = DiscInterrogation.verify(
            claims, against: Self.signs.titles, question: .bonusFeature)
        #expect(findings.isEmpty)
        #expect(unverified.count == 2, "kept and marked, never acted on and never hidden")
    }

    /// A claim with no runtime cannot be checked here and says so.
    @Test func anUntimedClaimIsUnverifiedNotRejected() {
        let claims = [DiscInterrogation.Claim(question: .films, label: "Get Hard")]
        let (findings, unverified) = DiscInterrogation.verify(
            claims, against: Self.doubleFeature.titles, question: .films)
        #expect(findings.isEmpty)
        #expect(unverified.map(\.label) == ["Get Hard"],
                "films are bound by TMDB runtimes in FeatureMatching, not here")
    }

    // MARK: - The whole sequence

    /// Signs, end to end, with the model answering as it actually does.
    @Test func signsIsUnderstoodEndToEnd() async {
        let understanding = await DiscInterrogation.run(evidence: Self.signs) { instructions, _ in
            if instructions.contains("FEATURE FILMS") { return "Signs" }
            if instructions.contains("BONUS material") { return "The Making of Signs (58:54)" }
            return """
            looking for Signs (6:11)
            building Signs (8:02)
            making Signs: a commentary by M. Night Shyamalan (22:33)
            the effects of Signs (8:31)
            last voices: the music of Signs (8:26)
            full circle (4:48)
            """
        }

        // The bonus reel, bound to the title that carries it.
        #expect(understanding.bonusFeatures.map(\.titleIndex) == [8])
        #expect(understanding.bonusFeatures.first?.label == "The Making of Signs")

        // And all six extras, each on its own title.
        #expect(understanding.extras.map(\.titleIndex) == [9, 10, 11, 12, 13, 14])
        #expect(understanding.extras.first { $0.titleIndex == 14 }?.label == "full circle")
        for extra in understanding.extras { #expect((extra.offBySeconds ?? 99) <= 5) }

        // The film's own title is never offered to the bonus or extras pass.
        #expect(!understanding.claimedTitles.contains(1))

        // "Signs" carried no runtime, so it stays unverified here — naming the
        // film is FeatureMatching's job, against TMDB.
        #expect(understanding.unverified.contains { $0.label == "Signs" })
    }

    /// A model that answers nothing leaves the disc exactly as it found it.
    @Test func silenceChangesNothing() async {
        let understanding = await DiscInterrogation.run(evidence: Self.signs) { _, _ in nil }
        #expect(understanding.isEmpty)
    }

    /// A model that invents throughout produces no findings at all.
    @Test func inventionThroughoutProducesNoFindings() async {
        let understanding = await DiscInterrogation.run(evidence: Self.signs) { _, _ in
            "DREAMSCAPE (1:11:11)\nDREAMLAND (2:22:22)"
        }
        #expect(understanding.allFindings.isEmpty)
        #expect(!understanding.unverified.isEmpty)
    }

    /// A title is never named twice across questions — the sequence narrows.
    @Test func atitleIsClaimedOnlyOnce() async {
        let understanding = await DiscInterrogation.run(evidence: Self.signs) { instructions, _ in
            // Both passes try to claim the 58:54 reel.
            if instructions.contains("FEATURE FILMS") { return "NONE" }
            return "The bonus reel (58:54)"
        }
        let indices = understanding.allFindings.map(\.titleIndex)
        #expect(Set(indices).count == indices.count)
        #expect(understanding.bonusFeatures.map(\.titleIndex) == [8])
        #expect(understanding.extras.isEmpty, "the reel was already spoken for")
    }

    /// Scope: an extra may not bind to a long title, nor a bonus feature to a
    /// short one.
    @Test func questionsStayInTheirSizeRange() {
        let reel = Self.title(8, seconds: 3534)
        let short = Self.title(14, seconds: 291)
        #expect(DiscInterrogation.inScope(reel, of: .bonusFeature, evidence: Self.signs))
        #expect(!DiscInterrogation.inScope(reel, of: .extras, evidence: Self.signs))
        #expect(DiscInterrogation.inScope(short, of: .extras, evidence: Self.signs))
        #expect(!DiscInterrogation.inScope(short, of: .bonusFeature, evidence: Self.signs))
        // And the film itself is off limits to everything but the film question.
        let film = Self.title(1, seconds: 6385)
        #expect(!DiscInterrogation.inScope(film, of: .extras, evidence: Self.signs))
        #expect(!DiscInterrogation.inScope(film, of: .bonusFeature, evidence: Self.signs))
    }
}
