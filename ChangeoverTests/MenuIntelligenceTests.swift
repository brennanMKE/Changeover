import Foundation
import Testing
@testable import Changeover

/// Tiers 1 and 2 assembled over a real disc's capture: which stills are the
/// chapter menu, which is the languages page, what the chapter names come out
/// as, and what the Confirm step ends up saying.
///
/// Everything here runs off `Fixtures/discs/bloodsport/menus/` — no disc, no
/// helper, no `ffmpeg`, no Vision. The capture is what it is: on that disc the
/// helper read 29 menu PGCs and **no button tables at all**, so tier 1 gives
/// nothing and the chapter names have to come from the numbers the disc
/// prints beside its own captions. That is not a workaround for the fixture;
/// it is the only disc the corpus has, and the app has to work on it.
struct MenuIntelligenceTests {

    private static func fixture(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/bloodsport/\(relativePath)")
    }

    static var bloodsportOCR: MenuOCRDocument {
        get throws { try MenuOCRDocument.decode(Data(contentsOf: fixture("menus/ocr.json"))) }
    }

    /// `structure.json` arrived with the second Bloodsport capture; a disc
    /// captured before `Tools/menudump` existed has OCR and nothing else, and
    /// the app must produce the same names either way.
    static var bloodsportStructure: MenuStructure? {
        let url = fixture("menus/structure.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MenuStructure.decode(data)
    }

    /// The names slice 1 checked against the stills one by one. Taken from
    /// `ChapterNamesTests` rather than copied: the disc gets re-captured
    /// whenever the tooling improves, and two lists of twenty-three strings
    /// would drift apart at the first re-capture.
    static var expectedNames: [String] { ChapterNamesTests.expectedNames }

    /// A synthetic two-button root menu — one `JumpTT 1`, one `JumpTT 4` —
    /// in the helper's own format. Written here rather than read from the
    /// corpus because the real disc's capture carries no button tables at
    /// all, and because a fixture being re-captured is not a stable place to
    /// pin tier 1's behaviour.
    static func structure(playTitle: Int, trailerTitle: Int) throws -> MenuStructure {
        let json = """
        {
          "format": "changeover-menu-structure/1",
          "frame": { "width": 720, "height": 480, "standard": "NTSC" },
          "titles": [
            { "title": \(playTitle), "vts": 1, "vtsTTN": 1, "ptts": 23, "angles": 1 },
            { "title": \(trailerTitle), "vts": 1, "vtsTTN": 2, "ptts": 1, "angles": 1 }
          ],
          "menus": [
            {
              "id": "vtsm-01-lu1-pgc1", "domain": "VTSM", "vts": 1, "languageUnit": 1,
              "pgc": 1, "entryType": "root", "buttons": [
                { "number": 1, "rect": [388, 148, 550, 178], "autoAction": false,
                  "command": "3002000000\(String(format: "%02X", playTitle))0000" },
                { "number": 2, "rect": [388, 188, 550, 218], "autoAction": false,
                  "command": "3002000000\(String(format: "%02X", trailerTitle))0000" }
              ]
            }
          ]
        }
        """
        return try MenuStructure.decode(Data(json.utf8))
    }

    // MARK: - The whole disc, as the app sees it

    /// The headline: hand the app everything the disc produced and it writes
    /// the twenty-three real chapter names — no cast page, no page-range
    /// button, no filmography year among them.
    @Test func bloodsportYieldsItsTwentyThreeChapterNames() throws {
        let menu = MenuIntelligence.derive(
            structure: Self.bloodsportStructure,
            ocr: try Self.bloodsportOCR,
            featureChapterCount: 23,
            scanTitles: [1, 2, 3, 4, 5, 6]
        )
        #expect(menu.markerPlan.isWrite)
        #expect(menu.markerRows.map(\.name) == Self.expectedNames)
        #expect(menu.markerRows.map(\.number) == Array(1...23))
    }

    /// The same disc against a title that has a different chapter count —
    /// the user picked another title, or the scan disagrees with the menu.
    /// Nothing is written.
    @Test func aDifferentChapterCountWritesNothing() throws {
        let menu = MenuIntelligence.derive(
            structure: Self.bloodsportStructure,
            ocr: try Self.bloodsportOCR,
            featureChapterCount: 21,
            scanTitles: [1]
        )
        #expect(!menu.markerPlan.isWrite)
        #expect(menu.markerRows.isEmpty)
    }

    /// Only the four chapter pages are read. The cast-and-crew pages print
    /// `Bloodsport (1987)` five times and the film's co-stars' filmographies
    /// beside them; none of that is a chapter page.
    @Test func onlyTheChapterPagesAreRead() throws {
        let ocr = try Self.bloodsportOCR
        let pages = MenuPages.chapterPages(ocr: ocr, structure: Self.bloodsportStructure, chapterCount: 23)
        #expect(pages.count == 4)
        #expect(Set(pages.map(\.id)).count == 4)
    }

    /// The filmography trap, pinned by name: the words on a bio page never
    /// become a chapter name.
    @Test func noCastPageTextBecomesAChapterName() throws {
        let menu = MenuIntelligence.derive(
            structure: Self.bloodsportStructure,
            ocr: try Self.bloodsportOCR,
            featureChapterCount: 23
        )
        let names = menu.chapterNames.map(\.name)
        #expect(!names.contains { $0.contains("1987") })
        #expect(!names.contains { $0.lowercased().contains("van damme") })
        #expect(!names.contains { $0.lowercased().contains("rambo") })
    }

    /// With no chapter count there is nothing to check the names against, so
    /// the text route selects no pages at all rather than reading every still
    /// it can.
    @Test func noChapterCountMeansNoTextRoute() throws {
        let ocr = try Self.bloodsportOCR
        #expect(MenuPages.chapterPages(ocr: ocr, structure: nil, chapterCount: 0).isEmpty)
    }

    /// A capture with OCR and no structure at all — every disc taken before
    /// the helper existed — still names its chapters.
    @Test func aPreHelperCaptureStillNamesItsChapters() throws {
        let menu = MenuIntelligence.derive(
            structure: nil,
            ocr: try Self.bloodsportOCR,
            featureChapterCount: 23
        )
        #expect(menu.markerRows.map(\.name) == Self.expectedNames)
    }

    // MARK: - Languages (advisory, never a mapping)

    /// The disc prints its spoken languages and the app repeats them beside
    /// the picker.
    @Test func theLanguagesPageIsReadAsAHint() throws {
        let menu = MenuIntelligence.derive(
            structure: Self.bloodsportStructure,
            ocr: try Self.bloodsportOCR,
            featureChapterCount: 23
        )
        let languages = try #require(menu.languages)
        #expect(languages.spoken.contains("English"))
        let line = try #require(MenuAudioHint.line(languages))
        #expect(line.contains("English"))
    }

    /// **The list is not the disc's inventory, and this disc proves it.** Its
    /// languages page prints four subtitle entries — English, Français, 日本語
    /// and "Off" — and no single Vision configuration reads all four: the
    /// recommended language list reads 日本語 and drops "Off", the defaults do
    /// the opposite. The captured run is one of those two, so the recorded
    /// list is short by one, and nothing anywhere may treat it as complete.
    @Test func theSubtitleListIsKnownToBeIncompleteOnThisDisc() throws {
        let menu = MenuIntelligence.derive(
            structure: Self.bloodsportStructure,
            ocr: try Self.bloodsportOCR,
            featureChapterCount: 23
        )
        let languages = try #require(menu.languages)
        #expect(languages.subtitles.count < 4)
        // And whatever it read, it is only ever a sentence.
        #expect(MenuAudioHint.line(languages)?.isEmpty == false)
    }

    /// Whichever shape the menu has, the hint says where the words came from
    /// — and in the shape that has no mapping at all, it says so outright.
    @Test func theHintNeverReadsLikeATrackAssignment() throws {
        let listing = LanguageHints.Lists(
            shape: .listing, spoken: ["English", "Français"], subtitles: ["English"]
        )
        #expect(MenuAudioHint.line(listing)?.contains("not a mapping") == true)

        let mapped = LanguageHints.Lists(
            shape: .buttons, spoken: ["English", "Français"], subtitles: [],
            trackMapping: ["1": "English", "2": "Français"]
        )
        let line = try #require(MenuAudioHint.line(mapped))
        #expect(line.contains("the tracks themselves are untouched"))

        #expect(MenuAudioHint.line(nil) == nil)
    }

    // MARK: - The captions

    @Test func readingSaysSoAndNothingElse() {
        #expect(MenuStatusLine.lines(.reading, scanFeatureTitle: 1) == ["Reading the disc's menus…"])
    }

    @Test func idleSaysNothing() {
        #expect(MenuStatusLine.lines(.idle, scanFeatureTitle: 1).isEmpty)
    }

    /// Every unavailable reason reaches the user as one line that ends the
    /// same way — the rip is unaffected.
    @Test func anUnavailableReadIsOneReassuringLine() {
        let lines = MenuStatusLine.lines(.unavailable(.helperMissing(path: "/x")), scanFeatureTitle: 1)
        #expect(lines.count == 1)
        #expect(lines[0].contains("The rip is unaffected."))
    }

    /// A disc whose menus gave nothing produces no captions at all: silence
    /// is the correct output, not "no menu data found".
    @Test func aDiscThatSaidNothingShowsNothing() {
        #expect(MenuStatusLine.lines(.ready(MenuIntelligence()), scanFeatureTitle: 1).isEmpty)
    }

    /// Tier 1 agreeing with the scan is a confirmation; disagreeing is
    /// information. Neither changes what Start does.
    @Test func thePlayButtonLineMatchesOrDisagrees() {
        var menu = MenuIntelligence()
        menu.playButton = PlayButtonResolver.Resolution(
            menu: "vtsm-01-lu1-pgc1", number: 1, label: "Play Movie",
            title: 1, resolvedBy: .structure, candidates: 1
        )
        #expect(MenuStatusLine.lines(.ready(menu), scanFeatureTitle: 1) == [
            "Disc menu: \"Play Movie\" starts title 1 — matches.",
        ])
        #expect(MenuStatusLine.lines(.ready(menu), scanFeatureTitle: 3) == [
            "Disc menu: \"Play Movie\" starts title 1; the scan chose title 3.",
        ])
    }

    /// A button pointing at a title the scan never found is dropped rather
    /// than captioned — tier 1 checks itself against the scan.
    @Test func aPlayButtonOutsideTheScanIsNotShown() throws {
        let menu = MenuIntelligence.derive(
            structure: try Self.structure(playTitle: 1, trailerTitle: 4),
            ocr: nil,
            featureChapterCount: nil,
            scanTitles: [99]
        )
        #expect(menu.playButton == nil)
    }

    /// Two title-jumping buttons with no labels resolve to nothing and ask
    /// nothing: there is no text for the lexicon to match and none for the
    /// model to read.
    @Test func twoUnlabelledButtonsResolveToSilence() throws {
        let menu = MenuIntelligence.derive(
            structure: try Self.structure(playTitle: 1, trailerTitle: 4),
            ocr: nil,
            featureChapterCount: nil,
            scanTitles: [1, 4]
        )
        #expect(menu.playButton == nil)
        #expect(menu.judgeQuestion == nil)
        #expect(MenuStatusLine.lines(.ready(menu), scanFeatureTitle: 1).isEmpty)
    }
}
