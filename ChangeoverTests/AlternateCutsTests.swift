import Foundation
import Testing
@testable import Changeover

/// #0235 — a disc offering two cuts of one film is not a double feature.
///
/// The case that forced this: REPO_MEN was classified `multipleFeatures`, Start
/// refused with `noFeatureChosen`, and the CLI was asked to name a second film
/// that does not exist.
///
/// The tests that matter most here are the ones proving the rule does **not**
/// fire. A false positive collapses a genuine double feature into one film and
/// silently loses the second — the exact failure #0157's removed chapter test
/// caused on Uncle Buck — so every guard gets its own case.
@Suite struct AlternateCutsTests {

    private static func title(_ index: Int, seconds: Int, chapters: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: chapters,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }

    private static func disc(_ titles: [DiscTitle], label: String = "DISC") -> DiscInfo {
        DiscInfo(volumeName: label, driveName: "drive", titles: titles)
    }

    /// Repo Men's real numbers: 1:59:28 and 1:51:06, 21 chapters each.
    private static let repoMen = [
        title(1, seconds: 7168, chapters: 21),
        title(2, seconds: 6666, chapters: 21),
    ]

    /// Uncle Buck / The Great Outdoors — a genuine double feature with almost
    /// exactly Repo Men's shape. This is why the menu has to decide.
    private static let uncleBuck = [
        title(1, seconds: 6000, chapters: 17),
        title(2, seconds: 5460, chapters: 17),
    ]

    /// WILLIS, measured on hardware 2026-10-08: Perfect Stranger 1:48:55 with
    /// 11 chapters and Mortal Thoughts 1:42:43 with 9. A genuine double
    /// feature whose runtimes are CLOSER than Repo Men's two cuts — 0.943
    /// against 0.930 — which is why no ratio threshold can work.
    private static let willis = [
        title(5, seconds: 6535, chapters: 11),
        title(6, seconds: 6163, chapters: 9),
    ]

    /// Its whole menu, one page, as the OCR read it. No edition words at all.
    private static let willisMenu = [
        "MORTAL", "THOUGHTS", "PERFECT", "STRANGER", "SUBTITLES: ON/OFF",
    ]

    private static let repoMenMenu = [
        "PLAY UNRATED VERSION", "PLAY THEATRICAL VERSION",
        "SCENE SELECTION", "SPECIAL FEATURES", "SETUP",
    ]

    // MARK: - Against the real disc

    /// #0235's second round. The first version of this rule passed every
    /// synthetic test and did nothing at all on the disc, because the menu
    /// lines never reached `severalFeatures` in production — the same shape as
    /// #0216, where a match could not fire because the thing it needed was
    /// never measured.
    ///
    /// So this one is fed REPO_MEN's actual OCR output, 191 lines of it,
    /// captured off joe. It lives in the external corpus rather than in this
    /// repository: #0224 moved authored menu text out of a public repo, and a
    /// disc's menu wording is exactly that. Skips when the corpus is absent.
    @Test func therealRepoMenMenuNamesAlternateCuts() throws {
        guard let url = DiscAssets.file("menu-lines.json", inDisc: "repo-men") else {
            // Returns rather than fails, the way the rest of the asset-backed
            // suite does. `DiscAssetAvailabilityTests` is what makes a thin run
            // look thin, so a silent skip here cannot hide a missing corpus.
            return
        }
        let lines = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        #expect(lines.count > 50, "the fixture should be the whole menu, not a sample")

        let words = AlternateCuts.versionWords(inMenu: lines)
        #expect(words.contains("unrated"))
        #expect(words.contains("theatrical"))
        #expect(AlternateCuts.namesAlternateCuts(menuLines: lines))

        #expect(DiscTitleHeuristic.severalFeatures(
            Self.disc(Self.repoMen), menuLines: lines) == nil,
            "the real menu should collapse the two cuts into one film")
    }

    /// The trailing asterisk on "PLAY UNRATED VERSION*" is why matching folds
    /// punctuation to spaces rather than comparing raw strings.
    @Test func punctuationGluedToAWordDoesNotHideIt() {
        #expect(AlternateCuts.namesAlternateCuts(
            menuLines: ["PLAY UNRATED VERSION*", "PLAY THEATRICAL VERSION"]))
    }

    /// The false positive the real menu warned about.
    ///
    /// "THEATRICAL TRAILER" is on a great many discs. Before the qualifier
    /// rule, a double feature whose bonus page said THEATRICAL TRAILER and
    /// whose other page said EXTENDED would have been collapsed into one film,
    /// silently losing the second feature.
    @Test func atrailerIsNotAnEdition() {
        #expect(!AlternateCuts.namesAlternateCuts(
            menuLines: ["THEATRICAL TRAILER", "EXTENDED VERSION"]))
        #expect(AlternateCuts.versionWords(inMenu: ["THEATRICAL TRAILER"]).isEmpty)
    }

    /// And a version word with no qualifier beside it is a mention, not an
    /// offer. REPO_MEN's own menu says "ON THE THEATRICAL" on a DVS notice.
    @Test func amentionIsNotAnOffer() {
        #expect(AlternateCuts.versionWords(inMenu: ["ON THE THEATRICAL"]).isEmpty)
        #expect(AlternateCuts.versionWords(inMenu: ["PLAY THEATRICAL VERSION"]) == ["theatrical"])
    }

    /// The inversion, pinned. A genuine double feature with runtimes closer
    /// than the real pair of cuts.
    ///
    /// If this ever fails because someone added a ratio rule, read the table in
    /// `AlternateCuts`: WILLIS scores 0.943 and Repo Men 0.930, so any
    /// threshold that collapses Repo Men collapses WILLIS first and loses
    /// Mortal Thoughts without saying so.
    @Test func agenuineDoubleFeatureWithCloserRuntimesThanTheRealCutsSurvives() {
        #expect(DiscTitleHeuristic.severalFeatures(
            Self.disc(Self.willis), menuLines: Self.willisMenu)?.count == 2,
            "WILLIS is two films; its menu names two films and no edition")
        #expect(AlternateCuts.versionWords(inMenu: Self.willisMenu).isEmpty)

        // And the runtimes really are closer than the disc that IS two cuts.
        let willisRatio = 6163.0 / 6535.0
        let repoMenRatio = 6666.0 / 7168.0
        #expect(willisRatio > repoMenRatio,
                "the premise of this test: a ratio rule would be inverted")
    }

    // MARK: - The vocabulary

    @Test func twoVersionWordsInAMenuNameAlternateCuts() {
        #expect(AlternateCuts.namesAlternateCuts(menuLines: Self.repoMenMenu))
    }

    /// One version word is a label, not a choice. A disc that only sells the
    /// unrated cut prints UNRATED and holds one film.
    @Test func oneVersionWordIsNotAChoice() {
        #expect(!AlternateCuts.namesAlternateCuts(
            menuLines: ["PLAY UNRATED VERSION", "SCENE SELECTION", "SETUP"]))
    }

    /// A menu that was never read says nothing, and must not be read as saying
    /// "one film".
    @Test func anunreadMenuNamesNothing() {
        #expect(!AlternateCuts.namesAlternateCuts(menuLines: []))
    }

    /// OCR drops accents on stylised type more often than it drops letters, so
    /// matching folds them — the same convention `MenuLexicon` uses.
    @Test func matchingIgnoresCaseAndAccents() {
        #expect(AlternateCuts.namesAlternateCuts(
            menuLines: ["play Ûnrated version", "Theatrical Cut"]))
    }

    // MARK: - The classification

    /// The bug, as the test that would have caught it.
    @Test func repoMenWithItsMenuIsOneFilm() {
        #expect(DiscTitleHeuristic.severalFeatures(
            Self.disc(Self.repoMen), menuLines: Self.repoMenMenu) == nil,
            "two cuts offered by one menu are one film")
    }

    /// Without the menu it still reads as two features — which is the honest
    /// answer, because nothing in the title list distinguishes it from Uncle
    /// Buck. This pins that the fix is the menu and not a loosened threshold.
    @Test func repoMenWithoutItsMenuIsStillTwoFeatures() {
        #expect(DiscTitleHeuristic.severalFeatures(Self.disc(Self.repoMen))?.count == 2)
    }

    /// The regression this rule must never cause. Uncle Buck's menu names two
    /// films, so nothing collapses.
    @Test func agenuineDoubleFeatureSurvives() {
        let menu = ["UNCLE BUCK", "THE GREAT OUTDOORS", "SCENE SELECTION", "SETUP"]
        #expect(DiscTitleHeuristic.severalFeatures(
            Self.disc(Self.uncleBuck), menuLines: menu)?.count == 2)
    }

    /// And it survives even if its menu happened to carry version words, because
    /// the runtimes would still have to be plausible as cuts. This is belt and
    /// braces: Uncle Buck's ratio is 0.91 so it *would* pass `plausiblyCuts`,
    /// which is exactly why the vocabulary and not the ratio is doing the work.
    @Test func thevocabularyIsWhatDecidesNotTheRatio() {
        #expect(AlternateCuts.plausiblyCuts([[Self.uncleBuck[0]], [Self.uncleBuck[1]]]),
                "Uncle Buck's runtimes alone look exactly like two cuts")
        #expect(AlternateCuts.plausiblyCuts([[Self.repoMen[0]], [Self.repoMen[1]]]))
    }

    /// Version words must not collapse groups that cannot be cuts of one film.
    @Test func faraparRuntimesAreNotCutsWhateverTheMenuSays() {
        let apart = [
            Self.title(1, seconds: 7168, chapters: 21),
            Self.title(2, seconds: 2400, chapters: 21),
        ]
        #expect(!AlternateCuts.plausiblyCuts([[apart[0]], [apart[1]]]),
                "40 minutes against two hours is not two cuts of one film")
    }
}
