import Foundation
import Testing
@testable import Changeover

/// §7.3 — the comparison, and every rule that refuses.
///
/// Pinned against the two real discs in the corpus: Bloodsport's menus name
/// **23** chapters for a 23-chapter file (the upgrade case), and Oppenheimer's
/// yield **0 of 21** with an unresolved play button, over a file that has 20
/// chapters where the scan says 21 (the refusal case, twice over).
struct UpgradeProposalTests {

    // MARK: - Real disc data

    private static func discFixture(_ slug: String, _ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/\(slug)/\(relativePath)")
    }

    /// The offer a disc's own menus produce, through the same
    /// `MenuIntelligence.derive` the app runs.
    static func offer(slug: String, chapterCount: Int) throws -> DiscUpgradeOffer {
        let ocr = try MenuOCRDocument.decode(Data(contentsOf: discFixture(slug, "menus/ocr.json")))
        let structure = (try? Data(contentsOf: discFixture(slug, "menus/structure.json")))
            .flatMap { try? MenuStructure.decode($0) }
        let menu = MenuIntelligence.derive(
            structure: structure,
            ocr: ocr,
            featureChapterCount: chapterCount
        )
        return DiscUpgradeOffer.make(menu: menu)
    }

    static func inventory(_ name: String) throws -> LibraryFileInventory {
        try LibraryFileInventoryTests.inventory(name)
    }

    // MARK: - Bloodsport: the upgrade case

    @Test func bloodsportOffersTwentyThreeNamesForATwentyThreeChapterFile() throws {
        let offer = try Self.offer(slug: "bloodsport", chapterCount: 23)
        #expect(offer.chapterNames.count == 23)
        #expect(offer.chapterNames.map(\.number) == Array(1...23))
        #expect(offer.chapterNames.map(\.name) == ChapterNamesTests.expectedNames)
    }

    @Test func bloodsportIsUpgradable() throws {
        let result = UpgradeProposal.compare(
            filePath: "/Plex/Movies/Bloodsport (1988) {tmdb-10336}/Bloodsport (1988).mp4",
            inventory: try Self.inventory("bloodsport-library.json"),
            offer: try Self.offer(slug: "bloodsport", chapterCount: 23)
        )

        let plan = try #require(result.plan)
        #expect(plan.chapters.count == 23)
        #expect(plan.chapters.first?.name == "World's warriors")
        #expect(result.headline == "This disc can improve that file without re-encoding it:")

        let chapters = try #require(result.rows.first { $0.label == "Chapters" })
        #expect(chapters.verdict == .upgrade)
        #expect(chapters.now == "23, unnamed (“Chapter 1”…“Chapter 23”)")
        #expect(chapters.fromDisc == "23 names from the scene menu")
    }

    /// The disc's Languages menu attaches its words to streams with `SetSTN`
    /// (§5.2 shape 1), so the untagged track gets both the ISO code and the
    /// menu's own word.
    @Test func bloodsportTagsItsUntaggedAudioTrackFromTheMenusOwnMapping() throws {
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: try Self.inventory("bloodsport-library.json"),
            offer: try Self.offer(slug: "bloodsport", chapterCount: 23)
        )

        let plan = try #require(result.plan)
        #expect(plan.audio == [AudioTag(track: 0, language: "eng", title: "English")])
        #expect(plan.changeSummary == "23 chapter names, 1 audio language")
    }

    @Test func aRemuxNeverPretendsItCanAddSubtitles() throws {
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: try Self.inventory("bloodsport-library.json"),
            offer: try Self.offer(slug: "bloodsport", chapterCount: 23)
        )
        let row = try #require(result.rows.first { $0.label == "Subtitles" })
        #expect(row.verdict == .needsRerip("a subtitle track has to be encoded, so this needs a re-rip"))
    }

    // MARK: - Oppenheimer: the refusal case

    @Test func oppenheimersMenusNameNoChaptersAtAll() throws {
        let offer = try Self.offer(slug: "oppenheimer", chapterCount: 21)
        #expect(offer.chapterNames.isEmpty)
    }

    @Test func oppenheimerOffersNothingAndSaysSoRatherThanOfferingANoOp() throws {
        let result = UpgradeProposal.compare(
            filePath: "/Plex/Movies/Oppenheimer (2023) {tmdb-872585}/Oppenheimer (2023).mp4",
            inventory: try Self.inventory("oppenheimer-library.json"),
            offer: try Self.offer(slug: "oppenheimer", chapterCount: 21)
        )

        #expect(result.plan == nil)
        #expect(!result.offersUpgrade)
        let chapters = try #require(result.rows.first { $0.label == "Chapters" })
        #expect(chapters.verdict == .unchanged)
        #expect(chapters.fromDisc == "—")
    }

    /// The headline rule, and the one the user asked for by name: the scan of
    /// the Oppenheimer disc reports **21** chapters and the file has **20**.
    /// Both numbers are said; nothing is trimmed to make them agree.
    @Test func aCountMismatchRefusesAndStatesBothCounts() throws {
        let names = (1...21).map { MarkerRow(number: $0, name: "Name \($0)") }
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: try Self.inventory("oppenheimer-library.json"),
            offer: DiscUpgradeOffer(chapterNames: names)
        )

        #expect(result.plan == nil)
        let chapters = try #require(result.rows.first { $0.label == "Chapters" })
        #expect(chapters.verdict == .refused("20 chapters in the file, 21 names on the disc — not upgraded"))
    }

    @Test func oneNameShortRefusesJustAsLoudlyAsOneNameOver() throws {
        let names = (1...19).map { MarkerRow(number: $0, name: "Name \($0)") }
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: try Self.inventory("oppenheimer-library.json"),
            offer: DiscUpgradeOffer(chapterNames: names)
        )
        #expect(result.plan == nil)
        #expect(result.rows.first?.verdict == .refused("20 chapters in the file, 19 names on the disc — not upgraded"))
    }

    @Test func namesThatAreNotChaptersOneThroughNAreRefused() throws {
        var names = (1...20).map { MarkerRow(number: $0, name: "Name \($0)") }
        names[19] = MarkerRow(number: 25, name: "Name 25")
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: try Self.inventory("oppenheimer-library.json"),
            offer: DiscUpgradeOffer(chapterNames: names)
        )
        #expect(result.plan == nil)
        #expect(result.rows.first?.verdict == .refused("the disc's names are not chapters 1…20 — not upgraded"))
    }

    // MARK: - Real names are never overwritten silently

    private static func namedFile(chapters: Int) -> LibraryFileInventory {
        LibraryFileInventory(
            durationMS: 1000 * chapters,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: "eng", title: "English")],
            subtitleCount: 1,
            chapters: (0..<chapters).map {
                ChapterSummary(startMS: $0 * 1000, endMS: ($0 + 1) * 1000, title: "Real name \($0 + 1)")
            }
        )
    }

    @Test func realChapterNamesAreRefusedWithoutTheExplicitTick() {
        let names = (1...5).map { MarkerRow(number: $0, name: "Disc name \($0)") }
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: Self.namedFile(chapters: 5),
            offer: DiscUpgradeOffer(chapterNames: names)
        )

        #expect(result.plan == nil)
        #expect(result.overwriteWouldHelp)
        #expect(result.rows.first?.verdict == .refused(
            "5 of the file's chapters already carry real names — tick “Replace existing names” to overwrite them"
        ))
    }

    @Test func realChapterNamesAreOverwrittenOnlyWhenTheUserSaysSo() throws {
        let names = (1...5).map { MarkerRow(number: $0, name: "Disc name \($0)") }
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: Self.namedFile(chapters: 5),
            offer: DiscUpgradeOffer(chapterNames: names),
            overwriteExistingNames: true
        )

        let plan = try #require(result.plan)
        #expect(plan.chapters.count == 5)
        #expect(result.rows.first?.verdict == .upgrade)
    }

    /// The tick is about *names*, never about counts: a mismatch stays
    /// refused however emphatically the user asks.
    @Test func theOverwriteTickNeverDefeatsTheCountRule() {
        let names = (1...4).map { MarkerRow(number: $0, name: "Disc name \($0)") }
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: Self.namedFile(chapters: 5),
            offer: DiscUpgradeOffer(chapterNames: names),
            overwriteExistingNames: true
        )
        #expect(result.plan == nil)
        #expect(result.rows.first?.verdict == .refused("5 chapters in the file, 4 names on the disc — not upgraded"))
    }

    // MARK: - Nothing to add

    @Test func aFileWithEverythingSaysSoRatherThanOfferingANoOp() {
        let result = UpgradeProposal.compare(
            filePath: "/Plex/x.mp4",
            inventory: Self.namedFile(chapters: 3),
            offer: DiscUpgradeOffer()
        )

        #expect(result.plan == nil)
        #expect(result.headline == "That file already has everything this disc can give it.")
        #expect(result.rows.allSatisfy { $0.verdict == .unchanged })
    }

    @Test func aFileWithNoChapterMarkersAtAllNeedsAReRip() {
        let inventory = LibraryFileInventory(
            durationMS: 1000,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: "eng", title: "English")],
            subtitleCount: 1
        )
        let names = (1...5).map { MarkerRow(number: $0, name: "Disc name \($0)") }
        let result = UpgradeProposal.compare(filePath: "/Plex/x.mp4", inventory: inventory, offer: DiscUpgradeOffer(chapterNames: names))

        #expect(result.plan == nil)
        #expect(result.rows.first?.verdict == .needsRerip(
            "the file has no chapter markers at all, and a remux cannot add timings"
        ))
    }

    // MARK: - Audio

    /// §5.2 shape 2: an ordered list of words is a caption, never a mapping.
    @Test func aLanguageListingWithNoMappingNeverBecomesAnAssignment() {
        let inventory = LibraryFileInventory(
            durationMS: 1000,
            audio: [
                AudioSummary(track: 0, codec: "ac3", channels: 6, language: nil, title: nil),
                AudioSummary(track: 1, codec: "ac3", channels: 2, language: nil, title: nil),
            ],
            subtitleCount: 1,
            chapters: [ChapterSummary(startMS: 0, endMS: 1000, title: "Real")]
        )
        let offer = DiscUpgradeOffer(
            chapterNames: [],
            languages: LanguageHints.Lists(shape: .listing, spoken: ["Svenska", "English"], subtitles: [])
        )
        let result = UpgradeProposal.compare(filePath: "/Plex/x.mp4", inventory: inventory, offer: offer)

        #expect(result.plan == nil)
        let rows = result.rows.filter { $0.label.hasPrefix("Audio") }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.verdict == .refused(
            "the disc's menu lists its languages but does not say which track is which — not upgraded"
        ) })
        #expect(rows[0].fromDisc == "menu lists: Svenska, English")
    }

    @Test func aTrackThatAlreadyCarriesALanguageIsLeftAlone() {
        let inventory = LibraryFileInventory(
            durationMS: 1000,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: "fra", title: "Français")],
            subtitleCount: 1,
            chapters: [ChapterSummary(startMS: 0, endMS: 1000, title: "Real")]
        )
        let offer = DiscUpgradeOffer(
            chapterNames: [],
            languages: LanguageHints.Lists(
                shape: .buttons, spoken: ["English"], subtitles: [], trackMapping: ["0": "English"]
            )
        )
        let result = UpgradeProposal.compare(filePath: "/Plex/x.mp4", inventory: inventory, offer: offer)

        #expect(result.plan == nil)
        #expect(result.rows.first { $0.label == "Audio 1" }?.verdict == .unchanged)
    }

    @Test(arguments: [("English", "eng"), ("Français", "fra"), ("ENGLISH 5.1", "eng"), ("ESPAÑOL", "spa"), ("日本語", "jpn")])
    func menuWordsResolveToISOCodes(word: String, code: String) {
        #expect(LanguageCode.code(forMenuName: word) == code)
    }

    @Test func anUnrecognisedMenuWordIsNeverGuessedAt() {
        #expect(LanguageCode.code(forMenuName: "Klingon") == nil)
    }

    /// A word the table does not know still names the track — it just does not
    /// invent an ISO code for it.
    @Test func anUnknownWordNamesTheTrackWithoutTaggingIt() throws {
        let inventory = LibraryFileInventory(
            durationMS: 1000,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: nil, title: nil)],
            subtitleCount: 1,
            chapters: [ChapterSummary(startMS: 0, endMS: 1000, title: "Real")]
        )
        let offer = DiscUpgradeOffer(
            chapterNames: [],
            languages: LanguageHints.Lists(
                shape: .buttons, spoken: ["Klingon"], subtitles: [], trackMapping: ["0": "Klingon"]
            )
        )
        let result = UpgradeProposal.compare(filePath: "/Plex/x.mp4", inventory: inventory, offer: offer)
        let plan = try #require(result.plan)
        #expect(plan.audio == [AudioTag(track: 0, language: nil, title: "Klingon")])
        #expect(plan.changeSummary == "1 audio track name")
    }
}
