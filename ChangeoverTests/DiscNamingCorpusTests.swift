import Foundation
import Testing
@testable import Changeover

/// Replays every archived disc's *naming* evidence — its volume label and the
/// text Vision read off its menus — against the pure parts of identification,
/// and pins what fraction of them each rung of the ladder actually gets right.
///
/// Why this exists: `THESECRETLIFEOFWALTERMITTY` is the film's title with the
/// spaces knocked out, its menus print nothing resembling it, and on-device
/// inference answered "The Caretaker". TMDB had a 2026 film of that name with
/// the same 114-minute runtime, so auto-select took it and the disc would have
/// been filed in Plex under the wrong film. The fix is to let the label lead —
/// and the risk of that fix is the opposite disc: `WILLIS`, a Bruce Willis
/// box-set label that is an *actor*, on two different discs whose menus, not
/// whose label, name the film. Both poles are in the corpus and both are
/// asserted here.
///
/// `Fixtures/naming/corpus.json` is built from joe's `~/changeover-fixtures`.
/// Ground truth is `naming.json` — written by `MenuArchive.writeNaming` at the
/// moment the user committed to a rip, so `chosenTitle`/`tmdbID` is what the
/// user actually picked, not something a reader inferred. Two archives are
/// byte-identical re-filings of another disc's capture and are excluded from
/// every count; two more (`1917`, `NOBODY`) have no `naming.json` and are
/// marked `reviewed: false`, so nothing here may assert on them.
///
/// The on-device model is not called: it needs joe and is not deterministic.
/// What is tested is every pure seam around it — label derivation, the
/// condensed comparison, the answer/label agreement check and its length
/// floor.
struct DiscNamingCorpusTests {

    // MARK: - Corpus shape

    struct Corpus: Codable {
        var format: String
        var discs: [Disc]
    }

    struct Disc: Codable {
        struct Film: Codable {
            var title: String
            var year: String?
            var tmdbID: String?
        }
        var id: String
        var volumeName: String
        var discID: String?
        /// "title" | "collection" | "abbreviation" | "generic" — what the
        /// label actually names. Only "title" labels may be judged by.
        var labelKind: String
        var film: Film
        var reviewed: Bool
        var groundTruthSource: String
        var duplicateOf: String?
        var recordedDerivedSearchTerm: String?
        var recordedDerivedMatchesChoice: Bool?
        var titleInMenus: Bool
        var titleInMenusEvidence: [String]
        var menuLineCount: Int
        var menuLines: [String]
        var menuHighlights: [String]
        var note: String?
    }

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/naming/corpus.json")
    }

    private static func load() throws -> Corpus {
        let data = try Data(contentsOf: corpusURL)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    /// One record per *physical* disc: the two byte-identical re-filings are
    /// not independent evidence and must never inflate an accuracy number.
    private static func distinctDiscs() throws -> [Disc] {
        try load().discs.filter { $0.duplicateOf == nil }
    }

    /// The subset any accuracy claim may rest on: a pairing recorded by the
    /// app itself, not reconstructed by a reader.
    private static func solidDiscs() throws -> [Disc] {
        try distinctDiscs().filter(\.reviewed)
    }

    // MARK: - The corpus is there and is honest

    @Test func theCorpusHasDiscsToSweep() throws {
        let discs = try Self.distinctDiscs()
        #expect(discs.count >= 20, "the naming corpus should sweep every archived disc, not a handful")
        #expect(try Self.solidDiscs().count >= 20)
    }

    @Test func everySolidPairingCarriesARecordedChoice() throws {
        for disc in try Self.solidDiscs() {
            #expect(!disc.film.title.isEmpty, "\(disc.id) is marked reviewed with no film")
            #expect(disc.groundTruthSource == "naming.json" || disc.groundTruthSource == "duplicate-ocr",
                    "\(disc.id) is marked reviewed but its pairing was inferred, not recorded")
        }
    }

    /// An unreviewed record must never be silently treated as truth. These
    /// are the archives with no `naming.json` — the disc was captured but no
    /// rip committed — and they are here for their OCR, not their pairing.
    @Test func unreviewedRecordsSayWhyTheyAreUnreviewed() throws {
        for disc in try Self.distinctDiscs() where !disc.reviewed {
            #expect(disc.note?.isEmpty == false, "\(disc.id) is unreviewed with no explanation")
            #expect(disc.groundTruthSource == "inferred")
        }
    }

    /// A duplicate archive must agree with the disc it duplicates, or the
    /// deduplication itself was wrong.
    @Test func duplicateArchivesAgreeWithTheirSource() throws {
        let all = try Self.load().discs
        let bySlug = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var found = 0
        for disc in all {
            guard let source = disc.duplicateOf else { continue }
            found += 1
            let origin = try #require(bySlug[source])
            #expect(disc.film.title == origin.film.title)
            #expect(disc.film.tmdbID == origin.film.tmdbID)
            #expect(disc.menuLines == origin.menuLines, "\(disc.id) was deduplicated against \(source) on identical OCR")
        }
        #expect(found == 2, "the two known re-filed archives should both be marked duplicateOf")
    }

    // MARK: - Rung 1: can the label alone name the film?

    /// The recorded rate, straight off the archives: `derivedMatchesChoice`
    /// as `MenuArchive.writeNaming` wrote it at rip time.
    ///
    /// 10 of 21. That is the number the label rung scores today on a literal
    /// string comparison, and it is the reason the ladder has more rungs.
    @Test func recordedLabelMatchRateIsWhatTheArchivesSay() throws {
        let recorded = try Self.distinctDiscs().compactMap(\.recordedDerivedMatchesChoice)
        #expect(recorded.count == 21, "21 archives carry a naming.json")
        #expect(recorded.filter { $0 }.count == 10)
    }

    /// Recomputing the same thing from the label and the chosen title must
    /// agree with what was recorded — otherwise one of the two is lying and
    /// every number below is built on sand. Recomputed exactly as
    /// `MenuArchive.naming` does it, through `fold`, which is why
    /// `TOP_GUN_MAVERICK` counts as a match for "Top Gun: Maverick".
    @Test func recomputingTheRecordedMatchReproducesIt() throws {
        for disc in try Self.distinctDiscs() {
            guard let recorded = disc.recordedDerivedMatchesChoice else { continue }
            let derived = DiscNameSearchTerm.derive(volumeName: disc.volumeName)
            #expect(derived == disc.recordedDerivedSearchTerm,
                    "\(disc.volumeName): derive now returns \(derived ?? "nil"), the archive recorded \(disc.recordedDerivedSearchTerm ?? "nil")")
            let matches = derived.map { MenuArchive.fold($0) == MenuArchive.fold(disc.film.title) } ?? false
            #expect(matches == recorded,
                    "\(disc.volumeName): recorded derivedMatchesChoice \(recorded) but recomputes to \(matches) (derived \(derived ?? "nil") vs \(disc.film.title))")
        }
    }

    /// The label rung, judged the way the *new* logic judges it: condensed,
    /// so `ENEMYATTHEGATES` counts as Enemy at the Gates and
    /// `THESECRETLIFEOFWALTERMITTY` counts as The Secret Life of Walter
    /// Mitty. 15 of the 23 distinct discs — and every one of those 15 is a
    /// disc the model never needs to be asked about.
    @Test func condensedLabelMatchesTheFilmOnFifteenOfTwentyThreeDiscs() throws {
        let discs = try Self.distinctDiscs()
        let exact = discs.filter { disc in
            guard let term = DiscTitleInference.labelAsSearchTerm(disc.volumeName) else { return false }
            return DiscTitleInference.condensed(term) == DiscTitleInference.condensed(disc.film.title)
        }
        #expect(discs.count == 23)
        #expect(exact.count == 15, "exact condensed label matches: \(exact.map(\.volumeName).sorted())")
    }

    /// Allowing containment in either direction — the label missing a
    /// leading "The", or carrying an authoring suffix — takes it to 18 of
    /// 23 (78.3%). The five that remain are the discs where the label names
    /// something that is not the film.
    @Test func containmentTakesTheLabelRungToEighteenOfTwentyThree() throws {
        let discs = try Self.distinctDiscs()
        let carried = discs.filter { Self.labelCarriesTitle($0) }
        #expect(carried.count == 18, "labels that carry the title: \(carried.map(\.volumeName).sorted())")
    }

    private static func labelCarriesTitle(_ disc: Disc) -> Bool {
        guard let term = DiscTitleInference.labelAsSearchTerm(disc.volumeName) else { return false }
        let label = DiscTitleInference.condensed(term)
        let title = DiscTitleInference.condensed(disc.film.title)
        guard !label.isEmpty, !title.isEmpty else { return false }
        return label.contains(title) || title.contains(label)
    }

    /// The five discs the label cannot name, by name — the working set for
    /// anything that has to come after the label.
    ///
    /// `WILLIS` twice (an actor, on two different box-set discs), `BLUSBRO`
    /// (an abbreviation with no word boundaries to recover), `DVD_VIDEO`
    /// (the disc's format) and `DIE_HARD_3_DISC1` (the popular name, where
    /// TMDB's title is "Die Hard: With a Vengeance").
    @Test func exactlyFiveLabelsNameSomethingOtherThanTheFilm() throws {
        let failing = try Self.distinctDiscs()
            .filter { !Self.labelCarriesTitle($0) }
            .map(\.volumeName)
            .sorted()
        #expect(failing == ["BLUSBRO", "DIE_HARD_3_DISC1", "DVD_VIDEO", "WILLIS", "WILLIS"])
    }

    /// `1917`'s label *is* its title, and `DiscNameSearchTerm` returns nil
    /// for it — correctly, by its own contract: it refuses every letterless
    /// name so that `1234` never seeds a search. The naming ladder's own
    /// rung is where the exception belongs, and it stays narrow.
    @Test func aBareYearLabelIsATitleOnTheLadderButNotInTheSearchPrefill() {
        #expect(DiscNameSearchTerm.derive(volumeName: "1917") == nil)
        #expect(DiscTitleInference.labelAsSearchTerm("1917") == "1917")
        #expect(DiscTitleInference.labelAsSearchTerm("1234") == nil)
        #expect(DiscTitleInference.labelAsSearchTerm("9999") == nil)
        // The rule it must not break: a year after a real title still goes.
        #expect(DiscNameSearchTerm.derive(volumeName: "FARGO_1996") == "Fargo")
        // And a bare year is far too short to judge an answer by.
        #expect(DiscTitleInference.labelCanJudgeAnswer("1917") == false)
    }

    // MARK: - Rung 2: what the menus alone could supply

    /// The menus print the film's title on 11 of 23 discs. That is the
    /// ceiling on anything menu-only, and it is why the label must lead:
    /// the label carries the title on 18.
    @Test func theMenusNameTheFilmOnElevenOfTwentyThreeDiscs() throws {
        let discs = try Self.distinctDiscs()
        #expect(discs.filter(\.titleInMenus).count == 11)
    }

    /// The discs where the menus are the *only* evidence: the label carries
    /// no title, so inference has to work or the user types it. Four of the
    /// five have the title somewhere on their menus; `DIE_HARD_3_DISC1` has
    /// neither, and is the one disc in the corpus where no automatic rung
    /// can reach the right TMDB title.
    @Test func theMenusAreTheOnlyEvidenceOnFiveDiscs() throws {
        let stranded = try Self.distinctDiscs().filter { !Self.labelCarriesTitle($0) }
        #expect(stranded.count == 5)
        let withoutMenuEvidence = stranded.filter { !$0.titleInMenus }.map(\.volumeName)
        #expect(withoutMenuEvidence == ["DIE_HARD_3_DISC1"])
    }

    /// The Willis discs, spelled out, because they are the counter-example
    /// the label-anchored fix must not break: one label, two discs, two
    /// different films, and the film named only in the menu text — where
    /// Vision even split "The Whole Nine Yards" across three observations.
    @Test func theWillisBoxSetDiscsShareALabelAndDifferInFilm() throws {
        let willis = try Self.distinctDiscs().filter { $0.volumeName == "WILLIS" }
        #expect(willis.count == 2)
        #expect(Set(willis.map(\.film.title)) == ["The Whole Nine Yards", "The Jackal"])
        #expect(willis.allSatisfy { $0.labelKind == "collection" })
        let yards = try #require(willis.first { $0.film.title == "The Whole Nine Yards" })
        let joined = DiscTitleInference.condensed(yards.menuLines.joined())
        #expect(joined.contains("thewholenineyards"),
                "the OCR splits the title across lines; only a condensed, boundary-free read finds it")
    }

    // MARK: - The check that must not misfire

    /// The bug, pinned: "The Caretaker" does not fit
    /// `THESECRETLIFEOFWALTERMITTY`, and the right answer does.
    @Test func theWrongAnswerThatCausedThisIsRefused() {
        let label = "THESECRETLIFEOFWALTERMITTY"
        #expect(DiscTitleInference.answerFitsLabel("The Caretaker", volumeName: label) == false)
        #expect(DiscTitleInference.answerFitsLabel("The Secret Life of Walter Mitty", volumeName: label))
        #expect(DiscTitleInference.answerFitsLabel("the secret life of walter mitty", volumeName: label))
    }

    /// **The most important test in this file.** The check may never reject
    /// the film a disc actually is — a false rejection breaks a disc that
    /// works today, which is strictly worse than the bug being fixed.
    @Test func theCheckNeverRejectsTheFilmTheDiscActuallyIs() throws {
        for disc in try Self.solidDiscs() {
            #expect(DiscTitleInference.answerFitsLabel(disc.film.title, volumeName: disc.volumeName),
                    "\(disc.volumeName) would reject its own recorded film \(disc.film.title)")
        }
    }

    /// Named explicitly, because these four are the ones the length floor
    /// exists for. Each is a correct answer that disagrees with its label.
    @Test func theLabelsThatMustNotVetoAnythingDoNot() {
        #expect(DiscTitleInference.answerFitsLabel("The Whole Nine Yards", volumeName: "WILLIS"))
        #expect(DiscTitleInference.answerFitsLabel("The Jackal", volumeName: "WILLIS"))
        #expect(DiscTitleInference.answerFitsLabel("The Blues Brothers", volumeName: "BLUSBRO"))
        #expect(DiscTitleInference.answerFitsLabel("Underworld", volumeName: "DVD_VIDEO"))
        #expect(DiscTitleInference.answerFitsLabel("Die Hard: With a Vengeance", volumeName: "DIE_HARD_3_DISC1"))
    }

    /// Containment has to work in both directions: a label can sit inside
    /// its title or its title inside the label, and the corpus has both.
    @Test func containmentIsAllowedInBothDirections() {
        // label inside title — the disc drops the leading "The"
        #expect(DiscTitleInference.answerFitsLabel("The Secret of My Success", volumeName: "SECRET_OF_MY_SUCCESS"))
        #expect(DiscTitleInference.answerFitsLabel("The Wolf of Wall Street", volumeName: "WOLF_OF_WALL_STREET"))
        // title inside label — the disc carries an authoring suffix
        #expect(DiscTitleInference.answerFitsLabel("Live Free or Die Hard", volumeName: "LIVEFREE_OR_DIEHARD_BRANCH"))
        // and a genuine disagreement on a long label is still refused
        #expect(DiscTitleInference.answerFitsLabel("Die Hard 2", volumeName: "LIVEFREE_OR_DIEHARD_BRANCH") == false)
    }

    /// The floor, measured across the whole corpus rather than chosen: 9 is
    /// the lowest length at which no disc's own film is rejected, and 8
    /// costs exactly one disc (`DIE_HARD_3_DISC1`, whose label condenses to
    /// `diehard3`). Below 7, `WILLIS` and `BLUSBRO` fall in too.
    @Test func nineIsTheLowestSafeLengthFloorAndTwelveIsWhatWeShip() throws {
        let discs = try Self.solidDiscs()

        func falseRejections(floor: Int) -> [String] {
            discs.filter { disc in
                guard let term = DiscTitleInference.labelAsSearchTerm(disc.volumeName) else { return false }
                let label = DiscTitleInference.condensed(term)
                guard label.count >= floor else { return false }
                let title = DiscTitleInference.condensed(disc.film.title)
                return !(label.contains(title) || title.contains(label))
            }.map(\.volumeName).sorted()
        }

        #expect(falseRejections(floor: 6) == ["BLUSBRO", "DIE_HARD_3_DISC1", "WILLIS", "WILLIS"])
        #expect(falseRejections(floor: 7) == ["BLUSBRO", "DIE_HARD_3_DISC1"])
        #expect(falseRejections(floor: 8) == ["DIE_HARD_3_DISC1"])
        #expect(falseRejections(floor: 9).isEmpty)
        #expect(falseRejections(floor: DiscTitleInference.labelVetoMinimumLength).isEmpty)
        #expect(DiscTitleInference.labelVetoMinimumLength >= 9)
    }

    /// The veto has to still bite where it was needed. Twelve is above the
    /// measured floor, so check it has not been raised past the point of
    /// usefulness: the discs whose labels spell the title in full must still
    /// be able to refuse a wandering answer.
    @Test func theVetoStillAppliesWhereItIsNeeded() throws {
        let judgeable = try Self.distinctDiscs()
            .filter { DiscTitleInference.labelCanJudgeAnswer($0.volumeName) }
        #expect(judgeable.count >= 10, "the veto should still cover the long, title-shaped labels")
        #expect(DiscTitleInference.labelCanJudgeAnswer("THESECRETLIFEOFWALTERMITTY"))
        #expect(DiscTitleInference.labelCanJudgeAnswer("ENEMYATTHEGATES"))
        #expect(DiscTitleInference.labelCanJudgeAnswer("WILLIS") == false)
        #expect(DiscTitleInference.labelCanJudgeAnswer("BLUSBRO") == false)
        #expect(DiscTitleInference.labelCanJudgeAnswer("DVD_VIDEO") == false)
        #expect(DiscTitleInference.labelCanJudgeAnswer("DIE_HARD_3_DISC1") == false)
    }

    // MARK: - Condensation and the uninformative set

    @Test func condensationIgnoresEverythingButLettersAndDigits() {
        #expect(DiscTitleInference.condensed("THE_BREAKFAST_CLUB") == "thebreakfastclub")
        #expect(DiscTitleInference.condensed("The Breakfast Club") == "thebreakfastclub")
        #expect(DiscTitleInference.condensed("Top Gun: Maverick") == "topgunmaverick")
        #expect(DiscTitleInference.condensed("TOP_GUN_MAVERICK") == "topgunmaverick")
        #expect(DiscTitleInference.condensed("") == "")
    }

    /// The format names carry nothing, and the check must refuse to judge by
    /// them however long they are.
    @Test func formatLabelsAreNeverASearchTerm() {
        for name in ["DVD_VIDEO", "DVDVIDEO", "NO_NAME", "UNTITLED", "MOVIE", "NEW_VOLUME"] {
            #expect(DiscTitleInference.labelAsSearchTerm(name) == nil, "\(name) should not be searched")
            #expect(DiscTitleInference.answerFitsLabel("Underworld", volumeName: name),
                    "\(name) has no standing to reject an answer")
        }
    }

    /// An empty or nonsense answer is not "no objection" — a judgeable label
    /// still refuses it.
    @Test func anEmptyAnswerIsRefusedByAJudgeableLabel() {
        #expect(DiscTitleInference.answerFitsLabel("", volumeName: "THESECRETLIFEOFWALTERMITTY") == false)
        #expect(DiscTitleInference.answerFitsLabel("...", volumeName: "THESECRETLIFEOFWALTERMITTY") == false)
    }

    // MARK: - What the model would be shown

    /// The corpus's `menuLines` must be exactly what `question(volumeName:
    /// ocr:)` would put in front of the model — otherwise every menu-side
    /// conclusion here is about a different input than production uses.
    @Test func theCorpusMenuLinesAreShapedLikeTheRealQuestion() throws {
        for disc in try Self.distinctDiscs() where !disc.menuLines.isEmpty {
            #expect(disc.menuLines.allSatisfy { $0.count <= DiscTitleInference.Question.maximumLineLength },
                    "\(disc.id) carries a line longer than the question allows")
            #expect(disc.menuLines.allSatisfy { $0.contains(where: \.isLetter) })
            let keys = disc.menuLines.map { $0.lowercased() }
            #expect(Set(keys).count == keys.count, "\(disc.id) carries duplicate lines")
        }
    }

    /// The prompt has to lead with the label now — the old wording told the
    /// model the menus rarely print the title, which is what let it talk
    /// itself out of a perfect label.
    @Test func theInstructionsLeadWithTheLabel() {
        let text = DiscTitleInference.instructions
        #expect(text.contains("Start with the disc label"))
        #expect(!text.contains("The menus rarely print the title plainly"))
    }
}
