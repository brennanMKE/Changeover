import Foundation
import Testing
@testable import Changeover

/// The archive's agreement record, driven as a pure function.
///
/// `DiscCorpusTests` proves the record matches the real captures; this proves
/// the *shape* can express the cases the corpus does not have yet — a disc
/// with no scanner answer, a Play All season disc, a play button that needs
/// one indirection, and menus that are absent or unreadable. Those four are
/// the ones a future capture will land on, and each of them is a different
/// verdict rather than the same silence.
struct MenuAgreementTests {

    // MARK: - The verdict rule

    @Test func bothSourcesNamingTheSameTitleAgree() {
        #expect(MenuAgreement.verdict(heuristicTitle: 1, menuRoute: .pgcCommands, menuTitle: 1) == .agree)
    }

    @Test func bothSourcesNamingDifferentTitlesDisagree() {
        #expect(MenuAgreement.verdict(heuristicTitle: 1, menuRoute: .structure, menuTitle: 3) == .disagree)
    }

    @Test func aHeuristicAnswerWithNoMenuAnswerIsTheMenuAbstaining() {
        #expect(MenuAgreement.verdict(heuristicTitle: 1, menuRoute: .unresolved, menuTitle: nil) == .menuAbstained)
    }

    @Test func aMenuAnswerWithNoHeuristicAnswerIsTheHeuristicAbstaining() {
        #expect(MenuAgreement.verdict(heuristicTitle: nil, menuRoute: .structure, menuTitle: 2) == .heuristicAbstained)
    }

    @Test func neitherAnsweringIsBothAbstaining() {
        #expect(MenuAgreement.verdict(heuristicTitle: nil, menuRoute: .noStructure, menuTitle: nil) == .bothAbstained)
    }

    /// **The distinction the report rests on.** A disc nobody has read must
    /// never be counted as a disagreement, however confident the heuristic
    /// was — most of the corpus is in that state, and a report that mixed the
    /// two would say the menu answer is untrustworthy when what it means is
    /// that nobody has looked.
    @Test func aDiscWhoseMenusWereNeverCapturedIsNotCapturedEvenWithAHeuristicAnswer() {
        #expect(MenuAgreement.verdict(heuristicTitle: 7, menuRoute: .notCaptured, menuTitle: nil) == .notCaptured)
    }

    /// A menu answer the scan cannot corroborate is not an answer. It is
    /// recorded under its own route so the archive can count how often the
    /// reader points somewhere HandBrake never went.
    @Test func aMenuTitleOutsideTheScanIsNotTreatedAsAnAnswer() {
        #expect(MenuAgreement.verdict(heuristicTitle: 1, menuRoute: .outsideScan, menuTitle: 42) == .menuAbstained)
    }

    // MARK: - The four shapes, end to end

    private func title(_ index: Int, seconds: Int, chapters: Int = 10) -> DiscTitle {
        DiscTitle(
            index: index,
            durationSeconds: seconds,
            chapterCount: chapters,
            sizeBytes: 0,
            outputFileName: nil
        )
    }

    private func disc(_ titles: [DiscTitle]) -> DiscInfo {
        DiscInfo(volumeName: "TEST", driveName: "test", titles: titles)
    }

    /// Hornet's Nest's shape: `MainFeature: -1`. The scanner column records
    /// the `-1` rather than dropping it — "no answer" and "said -1" are
    /// different stories about the same disc — and the heuristic's route says
    /// the 45-minute fallback answered instead (#0056).
    @Test func aDiscWithNoScannerAnswerRecordsTheRawValueAndTheLengthRoute() {
        let row = MenuAgreement.evaluate(
            slug: "no-main-feature",
            disc: disc([title(1, seconds: 400), title(11, seconds: 8813)]),
            mainFeatureIndex: -1,
            structure: nil,
            ocr: nil,
            menusCaptured: false
        )
        #expect(row.scannerTitle == nil)
        #expect(row.scannerRaw == -1)
        #expect(row.heuristicRoute == .length)
        #expect(row.heuristicTitle == 11)
        #expect(row.verdict == .notCaptured)
        #expect(MenuAgreementReport.scannerText(row) == "none (-1)")
    }

    /// A Play All season disc. The heuristic *names* title 14 and then
    /// refuses it, so the title is recorded (a menu pointing at the same one
    /// is agreeing about the title) and the route is what says the app would
    /// not rip it.
    @Test func aPlayAllDiscRecordsTheGuardAsItsRouteAndStillNamesTheTitle() {
        let episodes = (15...22).map { title($0, seconds: 1300) }
        let row = MenuAgreement.evaluate(
            slug: "season",
            disc: disc([title(14, seconds: 1300 * 8)] + episodes),
            mainFeatureIndex: 14,
            structure: nil,
            ocr: nil,
            menusCaptured: false
        )
        #expect(row.heuristicRoute == .playAllGuard)
        #expect(row.heuristicTitle == 14)
        #expect(!row.heuristicRoute.selectsATitle)
    }

    /// Menus captured, no structure to resolve — the `libdvdcss`-less host
    /// and the failed-helper shape. Distinct from `notCaptured`: somebody did
    /// look.
    @Test func aCaptureWithNoStructureAbstainsWithoutClaimingItWasNeverRead() {
        let row = MenuAgreement.evaluate(
            slug: "no-structure",
            disc: disc([title(1, seconds: 5000)]),
            mainFeatureIndex: 1,
            structure: nil,
            ocr: nil,
            menusCaptured: true
        )
        #expect(row.menuRoute == .noStructure)
        #expect(row.verdict == .menuAbstained)
    }

    /// The Bloodsport shape, as a value: one indirection (`LinkTailPGC` into
    /// the PGC's own post-commands) and a route that says so, so a review can
    /// tell a disc whose play button is a bare `JumpTT` from one that needed
    /// the extra step.
    @Test func oneIndirectionIsRecordedAsItsOwnRoute() throws {
        let structure = try Self.decodeSynthetic()
        let row = MenuAgreement.evaluate(
            slug: "synthetic",
            disc: disc([title(1, seconds: 5000)]),
            mainFeatureIndex: 1,
            structure: structure,
            ocr: nil,
            menusCaptured: true
        )
        #expect(row.menuTitle == 1)
        #expect(row.menuRoute == .pgcCommands)
        #expect(row.verdict == .agree)
        #expect(row.signals.menuCount == 1)
        #expect(row.signals.titleJumpingButtons == 1)
        #expect(row.signals.titlesJumpedTo == [1])
    }

    /// A root menu whose one button is a `LinkTailPGC` and whose PGC
    /// post-commands end in `JumpVTS_TT 1` — the shape the first real disc
    /// turned out to use, with that disc's own bytes. Written inline rather
    /// than loaded from the capture so the route is pinned by eight bytes
    /// that a reader can check against libdvdnav's table, not by a fixture
    /// that could be re-captured.
    private static func decodeSynthetic() throws -> MenuStructure {
        let json = """
        {
          "format": "changeover-menu-structure/1",
          "frame": { "width": 720, "height": 480 },
          "titles": [ { "title": 1, "vts": 1, "vtsTTN": 1, "ptts": 12 } ],
          "menus": [
            {
              "id": "vtsm-01-lu1-pgc1",
              "domain": "VTSM", "vts": 1, "languageUnit": 1, "pgc": 1,
              "entryType": "root",
              "cells": [ { "firstSector": 0, "lastSector": 100 } ],
              "commands": { "post": ["3003000000010000"] },
              "buttons": [
                { "number": 1, "rect": [100, 100, 300, 130], "autoAction": false,
                  "command": "200100000000040d" }
              ]
            }
          ]
        }
        """
        return try MenuStructure.decode(Data(json.utf8))
    }

    // MARK: - The report

    private func row(
        _ slug: String,
        heuristic: Int?,
        route: MenuAgreement.HeuristicRoute = .scanner,
        menuRoute: MenuAgreement.MenuRoute,
        menu: Int? = nil,
        labels: [MenuAgreement.Label] = []
    ) -> MenuAgreement {
        var signals = MenuAgreement.Signals()
        signals.labels = labels
        return MenuAgreement(
            slug: slug,
            scannerTitle: heuristic,
            scannerRaw: heuristic,
            heuristicRoute: route,
            heuristicTitle: heuristic,
            menuRoute: menuRoute,
            menuTitle: menu,
            menuLabel: nil,
            verdict: MenuAgreement.verdict(heuristicTitle: heuristic, menuRoute: menuRoute, menuTitle: menu),
            signals: signals
        )
    }

    @Test func theReportCountsEveryVerdictAndOrdersDiscsBySlug() {
        let report = MenuAgreementReport.make([
            row("zeta", heuristic: 1, menuRoute: .structure, menu: 1),
            row("alpha", heuristic: 1, menuRoute: .structure, menu: 4),
            row("mid", heuristic: 1, menuRoute: .notCaptured),
        ])
        #expect(report.rows.map(\.slug) == ["alpha", "mid", "zeta"])
        #expect(report.count(.agree) == 1)
        #expect(report.count(.disagree) == 1)
        #expect(report.count(.notCaptured) == 1)
        #expect(report.comparedDiscs == 2)
        #expect(report.disagreements.map(\.slug) == ["alpha"])
    }

    /// The report has to say the uncomfortable thing out loud: one agreeing
    /// disc is not evidence. If this sentence ever goes missing the artifact
    /// starts reading like a recommendation.
    @Test func theReportRefusesToPresentThinAgreementAsEvidence() {
        let text = MenuAgreementReport.make([
            row("one", heuristic: 1, menuRoute: .structure, menu: 1),
            row("two", heuristic: 1, menuRoute: .notCaptured),
        ]).text
        #expect(text.contains("1 disc has an answer from both sources: 1 agree, 0 disagree."))
        #expect(text.contains("is not"))
        #expect(text.contains("\"not captured\" is absence of evidence, never disagreement"))
    }

    @Test func theReportNamesEveryDisagreementSoItCanBeReadBack() {
        let text = MenuAgreementReport.make([
            row("odd-one", heuristic: 2, menuRoute: .lexicon, menu: 5),
        ]).text
        #expect(text.contains("odd-one: menu 5 vs heuristic 2 (scanner)"))
    }

    @Test func theReportMergesVocabularyAcrossDiscsAndListsWhatTheLexiconDoesNotKnow() {
        let report = MenuAgreementReport.make([
            row("a", heuristic: 1, menuRoute: .structure, menu: 1,
                labels: [.init(text: "Play Movie", role: .play, target: "title:1"),
                         .init(text: "Tocar", role: nil, target: "title:1")]),
            row("b", heuristic: 1, menuRoute: .structure, menu: 1,
                labels: [.init(text: "Play Movie", role: .play, target: "title:1")]),
        ])
        let playMovie = report.vocabulary.first { $0.text == "Play Movie" }
        #expect(playMovie?.discs == ["a", "b"])
        #expect(report.unknownWords.map(\.text) == ["Tocar"])
        #expect(report.text.contains("Unknown to MenuLexicon.entries"))
    }

    // MARK: - What counts as a button word

    /// The vocabulary column is only useful if its "unknown" list is short
    /// enough to act on. On the one captured disc, button rectangles enclose
    /// cast-page sentences and OCR merges a whole row of captions into one
    /// observation; neither is a word the lexicon should be asked to learn.
    @Test(arguments: [
        ("Play Movie", true),
        ("Cast & Crew", true),
        ("本編再生", true),
        ("Back", true),
        ("7-12 13-18 19-23", false),
        ("4 Training.", false),
        ("Bloodsport (1987)", false),
        ("Fean Claude Van Damme...Frank Dux", false),
        ("", false),
    ])
    func buttonWordsAreSeparatedFromTheSentencesInsideButtonRectangles(word: String, isAWord: Bool) {
        #expect(MenuAgreement.looksLikeAButtonWord(word) == isAWord)
    }
}

/// The lexicon is a table, and every consumer reads the same table.
///
/// It used to be three: `MenuLexicon`'s play words, its non-feature words,
/// and a second hand-kept copy inside `MenuOCR.defaultCustomWords` that had
/// already drifted — Vision was primed for "Continue" and "Main Menu" that
/// the matcher had never heard of, so a button carrying one read perfectly
/// and then meant nothing.
struct MenuLexiconTableTests {

    @Test func everyRowIsReachableThroughTheMatcher() {
        for entry in MenuLexicon.entries {
            switch entry.role {
            case .play:
                #expect(MenuLexicon.isPlayLabel(entry.text), "\(entry.text) is a play row the matcher does not recognise")
            case .nonFeature:
                #expect(MenuLexicon.isNonFeatureLabel(entry.text), "\(entry.text) is a non-feature row the matcher does not recognise")
            }
            #expect(MenuLexicon.role(of: entry.text) == entry.role, "\(entry.text): role round-trip")
        }
    }

    /// The accented spelling is what a disc prints and what Vision is primed
    /// with; the folded spelling is what OCR often returns. Both have to
    /// match, from one row.
    @Test(arguments: [
        ("Ver película", "ver pelicula"),
        ("Suppléments", "supplements"),
        ("Hauptmenü", "hauptmenu"),
    ])
    func accentedRowsMatchTheirFoldedSpelling(authored: String, folded: String) {
        #expect(MenuLexicon.normalize(authored) == folded)
        #expect(MenuLexicon.isKnownLabel(authored))
        #expect(MenuLexicon.isKnownLabel(folded))
    }

    /// Vision's custom words and the matcher's table are the same list. A new
    /// disc's vocabulary is one row, and both paths get it.
    @Test func visionIsPrimedWithExactlyTheWordsTheMatcherKnows() {
        let table = Set(MenuLexicon.entries.map(\.text))
        #expect(table.isSubset(of: Set(MenuOCR.defaultCustomWords)))
        #expect(Set(MenuOCR.defaultCustomWords).subtracting(table) == Set(MenuLexicon.misreadCorrections))
    }

    /// The words the first real disc printed, as the design's own list of
    /// what a DVD menu says. Every one is in the table with the disc behind
    /// it, so the next disc that prints them is deterministic.
    @Test(arguments: [
        "Play Movie", "Start Movie", "Scene Selections", "Special Features",
        "Cast & Crew", "Theatrical Trailer", "Main Menu", "Back", "Continue",
        "End Credits", "Languages",
    ])
    func theVocabularyReadOffARealDiscIsInTheTableWithItsProvenance(word: String) {
        #expect(MenuLexicon.isKnownLabel(word), "\(word) was OCR'd off a real disc and the lexicon has no row for it")
        let row = MenuLexicon.entries.first { MenuLexicon.normalize($0.text) == MenuLexicon.normalize(word) }
        #expect(row?.seenOn.contains("bloodsport") == true, "\(word): the row has no disc behind it")
    }

    /// A play word and a non-feature word are different answers, and the
    /// resolver's trailer guard depends on it. `Play All` is deliberately a
    /// play word — the Play All *guard* is the heuristic's job, not the
    /// lexicon's.
    @Test func trailerLikeWordsAreNeverPlayWords() {
        #expect(!MenuLexicon.isPlayLabel("Theatrical Trailer"))
        #expect(!MenuLexicon.isPlayLabel("Scene Selections"))
        #expect(!MenuLexicon.isPlayLabel("Play with commentary"))
        #expect(MenuLexicon.isPlayLabel("Play All"))
    }

    @Test func anUnknownWordIsAnHonestNil() {
        #expect(MenuLexicon.role(of: "Tocar la película") == nil)
        #expect(MenuLexicon.role(of: "") == nil)
    }
}
