import Foundation
import Testing
@testable import Changeover

/// The chapter-name extractor, pinned on a real disc's real OCR output.
///
/// `Fixtures/discs/bloodsport/menus/ocr.json` is what Vision actually
/// returned for the sixteen captured Bloodsport menu stills — every
/// observation, with its box, including the 0.30-confidence smear. Nothing
/// in it was tidied up, which matters because the two failures this code
/// exists to survive are both in there:
///
/// 1. Vision merges a whole **row** of three captions into one observation
///    (`"1World's warriors, 2 Dux ducks out. 3 A mentor:"`), so a chapter
///    name is not a line.
/// 2. A long caption **wraps** onto a second observation with no number on
///    it (`"Tanaka."`, `"montage."`, `"chase."`), so the continuation has to
///    be joined to the right one of three columns — by geometry, because
///    nothing in the text says which.
///
/// A line-by-line regex reads 21 of the 23 names and mis-assigns two more.
/// The geometric rule reads all 23, and the names below were checked against
/// the stills one by one.
struct ChapterNamesTests {

    static var bloodsportOCR: MenuOCRDocument {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/discs/bloodsport/menus/ocr.json")
            return try MenuOCRDocument.decode(Data(contentsOf: url))
        }
    }

    static let chapterPages = ["menu_05", "menu_06", "menu_07", "menu_08"]

    static let expectedNames = [
        "World's warriors", "Dux ducks out", "A mentor: Tanaka", "Training",
        "Ray Jackson", "No man's land", "Death touch", "Bet on a woman",
        "The mightiest prevail", "First bouts", "Fight to Survive montage",
        "Hong Kong chase", "Under covers, undercover", "Second rounds",
        "Ray vs. Chong Li", "Being the best", "Nearly zapped", "Dux vs. Paco",
        "Short work for Chong Li", "Championship", "Victory out of dust",
        "Goodbye", "Coda and End Credits",
    ]

    static func bloodsportCandidates() throws -> [ChapterNames.Candidate] {
        let document = try bloodsportOCR
        return ChapterNames.candidates(stills: chapterPages.map { document.still($0)?.observations ?? [] })
    }

    // MARK: - The real disc

    @Test func bloodsportYieldsAllTwentyThreeChapterNames() throws {
        let candidates = try Self.bloodsportCandidates()
        #expect(candidates.count == 23)
        #expect(candidates.sorted { $0.chapter < $1.chapter }.map(\.name) == Self.expectedNames)
    }

    /// The three wrapped captions, named individually — these are the cases a
    /// line-by-line reader gets wrong, and each one wraps under a different
    /// column so a rule that guessed "always the first column" or "always the
    /// last" would fail on two of them.
    @Test(arguments: [
        (3, "A mentor: Tanaka"),          // continuation "Tanaka." — third column
        (9, "The mightiest prevail"),     // "prevail."          — third column
        (11, "Fight to Survive montage"), // "montage."          — second column
        (12, "Hong Kong chase"),          // "chase."            — third column
        (13, "Under covers, undercover"), // "undercover."       — first column
        (15, "Ray vs. Chong Li"),         // "Chong Li."         — third column
        (19, "Short work for Chong Li"),  // "Chong Li."         — first column
        (21, "Victory out of dust"),      // "of dust."          — third column
        (23, "Coda and End Credits"),     // "Credits.."         — second column
    ])
    func wrappedCaptionsJoinTheRightColumn(chapter: Int, name: String) throws {
        let candidates = try Self.bloodsportCandidates()
        #expect(candidates.first { $0.chapter == chapter }?.name == name)
    }

    /// Chapter 20's caption fits on one line, so it has no continuation. It
    /// must come back as "Championship", not as "Championship" plus whatever
    /// happens to sit below it.
    @Test func anUnwrappedCaptionIsNotExtended() throws {
        let candidates = try Self.bloodsportCandidates()
        #expect(candidates.first { $0.chapter == 20 }?.name == "Championship")
    }

    /// The page-range buttons ("1-6 7-12 13-18 19-23") begin with digits and
    /// are navigation, not captions. They must not become chapters 1, 7, 13
    /// and 19 — which would silently overwrite four real names.
    @Test func pageRangeButtonsAreNotChapters() throws {
        let candidates = try Self.bloodsportCandidates()
        #expect(candidates.filter { $0.chapter == 7 }.count == 1)
        #expect(candidates.first { $0.chapter == 7 }?.name == "Death touch")
        #expect(candidates.first { $0.chapter == 13 }?.name == "Under covers, undercover")
        #expect(!candidates.contains { $0.name.hasPrefix("-") })
    }

    /// "Start Movie", "Main Menu" and "End Credits" are buttons ~50 px below
    /// the last caption row. They have no number, so they are candidate
    /// continuations, and only the distance rule keeps them out.
    @Test func navigationButtonsAreNotJoinedAsContinuations() throws {
        let candidates = try Self.bloodsportCandidates()
        for forbidden in ["Start Movie", "Main Menu", "Scene Selections"] {
            #expect(!candidates.contains { $0.name.contains(forbidden) }, "\(forbidden) leaked into a chapter name")
        }
        // "End Credits" is deliberately not in that list: the page's fourth
        // navigation button says "End Credits" *and* chapter 23 is genuinely
        // named "Coda and End Credits". A substring check would have to
        // reject one of the two, so the button is excluded the only way that
        // is actually correct — by never being a whole name of its own.
        #expect(!candidates.contains { $0.name == "End Credits" })
        #expect(candidates.contains { $0.name == "Coda and End Credits" })
    }

    /// The one low-confidence observation in the whole capture — `ONAOC`, a
    /// 0.30 smear off the credits thumbnail — sits 33 px below the caption
    /// row on the same page and must not be joined to chapter 21.
    @Test func aLowConfidenceSmearIsNotJoined() throws {
        let candidates = try Self.bloodsportCandidates()
        #expect(!candidates.contains { $0.name.contains("ONAOC") })
    }

    /// Geometry is per frame. Bloodsport's four chapter pages put their
    /// captions at the same two y bands, so pooling the pages before
    /// resolving lets page 3's "Chong Li." continue page 1's "A mentor:".
    /// This is not a hypothetical: it is what the first implementation did.
    @Test func poolingPagesBeforeResolvingCorruptsTheNames() throws {
        let document = try Self.bloodsportOCR
        let pooled = ChapterNames.candidates(
            observations: Self.chapterPages.flatMap { document.still($0)?.observations ?? [] }
        )
        #expect(
            pooled.first { $0.chapter == 3 }?.name != "A mentor: Tanaka",
            "if this ever passes, the per-still rule has stopped mattering and this test should be rewritten"
        )
    }

    // MARK: - The CSV, and its refusals

    @Test func twentyThreeNamesMakeTwentyThreeRows() throws {
        let rows = try #require(ChapterNames.markers(Self.bloodsportCandidates(), chapterCount: 23))
        #expect(rows.count == 23)
        #expect(rows.map(\.number) == Array(1...23))
        #expect(rows.allSatisfy { !$0.name.isEmpty })
    }

    /// **The refusal.** A wrong name is a wrong caption at the right
    /// timestamp; a wrong *count* is a CSV HandBrake applies by number to
    /// markers it has already placed. So fewer than half the chapters named
    /// produces no CSV at all and the encode keeps today's bare `--markers`.
    @Test func fewerThanHalfTheChaptersNamedRefusesOutright() throws {
        let candidates = try Self.bloodsportCandidates().filter { $0.chapter <= 11 }
        #expect(candidates.count == 11)
        #expect(ChapterNames.markers(candidates, chapterCount: 23) == nil)
    }

    @Test func exactlyHalfIsAccepted() throws {
        let candidates = try Self.bloodsportCandidates().filter { $0.chapter <= 12 }
        #expect(candidates.count == 12)
        #expect(ChapterNames.markers(candidates, chapterCount: 23)?.count == 12)
    }

    /// A row HandBrake has no marker for is the one output of this code that
    /// can break an encode, so the chapter count is a hard ceiling — not a
    /// hint, not a warning.
    @Test func noRowMayExceedTheChapterCount() throws {
        let rows = try #require(ChapterNames.markers(Self.bloodsportCandidates(), chapterCount: 20))
        #expect(rows.count == 20)
        #expect(rows.allSatisfy { $0.number <= 20 })
    }

    @Test func aChapterCountOfZeroRefuses() throws {
        let candidates = try Self.bloodsportCandidates()
        #expect(ChapterNames.markers(candidates, chapterCount: 0) == nil)
    }

    /// A candidate whose printed number disagrees with the button's own
    /// `JumpVTS_PTT` chapter is kept in the archive and dropped from the CSV.
    @Test func disputedCandidatesNeverReachTheCSV() {
        let candidates = [
            ChapterNames.Candidate(chapter: 1, printedNumber: 1, name: "One", confidence: 1),
            ChapterNames.Candidate(chapter: 2, printedNumber: 9, name: "Two", confidence: 1, disputed: true),
            ChapterNames.Candidate(chapter: 3, printedNumber: 3, name: "Three", confidence: 1),
            ChapterNames.Candidate(chapter: 4, printedNumber: 4, name: "Four", confidence: 1),
        ]
        let rows = ChapterNames.markers(candidates, chapterCount: 4)
        #expect(rows?.map(\.number) == [1, 3, 4])
    }

    @Test func twoUnnumberedCandidatesForOneChapterNameNeither() {
        let candidates = [
            ChapterNames.Candidate(chapter: 1, printedNumber: nil, name: "One", confidence: 1),
            ChapterNames.Candidate(chapter: 1, printedNumber: nil, name: "Other", confidence: 1),
            ChapterNames.Candidate(chapter: 2, printedNumber: 2, name: "Two", confidence: 1),
        ]
        let rows = ChapterNames.markers(candidates, chapterCount: 2)
        #expect(rows?.map(\.number) == [2], "chapter 1 is contested, so it is named by neither candidate")
        #expect(ChapterNames.markers(candidates, chapterCount: 1) == nil, "with chapter 1 contested nothing is left")
    }

    @Test func aNumberedCandidateBeatsAnUnnumberedOneForTheSameChapter() {
        let candidates = [
            ChapterNames.Candidate(chapter: 1, printedNumber: nil, name: "Unnumbered", confidence: 1),
            ChapterNames.Candidate(chapter: 1, printedNumber: 1, name: "Numbered", confidence: 1),
        ]
        #expect(ChapterNames.markers(candidates, chapterCount: 1)?.first?.name == "Numbered")
    }

    @Test func emptyNamesAreOmittedNotWritten() {
        let candidates = [
            ChapterNames.Candidate(chapter: 1, printedNumber: 1, name: "  .  ", confidence: 1),
            ChapterNames.Candidate(chapter: 2, printedNumber: 2, name: "Real", confidence: 1),
        ]
        #expect(ChapterNames.markers(candidates, chapterCount: 2)?.map(\.name) == ["Real"])
    }

    // MARK: - The CSV text

    @Test func csvPutsOneRowPerLine() throws {
        let rows = try #require(ChapterNames.markers(Self.bloodsportCandidates(), chapterCount: 23))
        let lines = ChapterNames.csv(rows).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 23)
        #expect(lines.first == "1,World's warriors")
        #expect(lines.last == "23,Coda and End Credits")
    }

    /// HandBrake takes the first comma as the separator, so a comma inside a
    /// name would silently truncate it. Bloodsport has exactly one such name.
    @Test func commasInsideNamesAreReplaced() throws {
        let rows = try #require(ChapterNames.markers(Self.bloodsportCandidates(), chapterCount: 23))
        let line = ChapterNames.csv(rows).split(separator: "\n").first { $0.hasPrefix("13,") }
        #expect(line == "13,Under covers - undercover")
        #expect(rows.first { $0.number == 13 }?.name == "Under covers, undercover",
                "the real name is kept on the row; only the CSV rendering substitutes")
    }

    // MARK: - Cleaning

    @Test(arguments: [
        ("Training.", "Training"),
        ("No man's land. *", "No man's land"),
        ("Nearly zapped,", "Nearly zapped"),
        ("Coda and End Credits..", "Coda and End Credits"),
        ("  Ray vs. Chong Li  ", "Ray vs. Chong Li"),
        ("A mentor:  Tanaka", "A mentor: Tanaka"),
    ])
    func cleanStripsDecorationAndKeepsTheName(_ input: String, _ expected: String) {
        #expect(ChapterNames.clean(input) == expected)
    }

    // MARK: - The structural path

    /// With the disc's own buttons, the chapter number comes from the
    /// button's `JumpVTS_PTT` and the printed number is only a check.
    @Test func buttonsSupplyTheChapterNumberAndThePrintedNumberChecksIt() {
        let buttons = [
            ResolvedButton(
                ref: MenuButtonRef(menu: "vtsm-01-lu1-pgc2", number: 1),
                rect: PixelRect(minX: 137, minY: 100, maxX: 260, maxY: 170),
                autoAction: false,
                command: VMCommand(hex: "3005000400010000")!,
                target: .chapter(title: 1, ptt: 4),
                onEntryMenu: false,
                entryType: "chapter"
            )
        ]
        let agreeing = [TextObservation(text: "4 Training.", confidence: 1, rect: PixelRect(minX: 140, minY: 180, maxX: 250, maxY: 200))]
        let agreed = ChapterNames.candidates(buttons: buttons, observations: agreeing)
        #expect(agreed.first?.chapter == 4)
        #expect(agreed.first?.name == "Training")
        #expect(agreed.first?.disputed == false)

        let disagreeing = [TextObservation(text: "7 Training.", confidence: 1, rect: PixelRect(minX: 140, minY: 180, maxX: 250, maxY: 200))]
        let disputed = ChapterNames.candidates(buttons: buttons, observations: disagreeing)
        #expect(disputed.first?.chapter == 4, "the button's command is the source of truth, not the printed number")
        #expect(disputed.first?.disputed == true)
        #expect(ChapterNames.markers(disputed, chapterCount: 4) == nil, "a disputed row is dropped, and one of four is fewer than half")
    }
}
