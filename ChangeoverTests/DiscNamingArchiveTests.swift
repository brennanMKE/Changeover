import Foundation
import Testing
@testable import Changeover

/// The ground truth for `docs/disc-name-inference.md`: what a disc called
/// itself, beside what it turned out to be.
///
/// Nothing was keeping these pairs, so the question "how often does the rule
/// ladder actually miss?" had no answer and any inference built to fix it
/// would have had nothing to be judged against.
struct DiscNamingArchiveTests {

    // MARK: - The fold the match check uses

    /// Case and punctuation fold away; **word boundaries do not**. A term
    /// with the spaces missing finds nothing on TMDB, and that is the thing
    /// being measured — so the label and the title must not compare equal
    /// just because they share their letters.
    @Test func foldingKeepsWordBoundariesAndDropsEverythingElse() {
        #expect(MenuArchive.fold("Enemy at the Gates") == "enemy at the gates")
        #expect(MenuArchive.fold("ENEMYATTHEGATES") == "enemyatthegates")
        #expect(MenuArchive.fold("Enemy at the Gates") != MenuArchive.fold("ENEMYATTHEGATES"),
                "an unsegmented label is not a match for the title it hides")

        // Case, underscores and an apostrophe are all noise.
        #expect(MenuArchive.fold("The Girl in the Spider's Web")
                == MenuArchive.fold("THE_GIRL_IN_THE_SPIDERS_WEB"))
        #expect(MenuArchive.fold("  Fargo  ") == "fargo")
        #expect(MenuArchive.fold("") == "")
    }

    // MARK: - The record

    /// The case the whole document is about: a label with no word boundaries,
    /// which the rule ladder declines, beside the title the user typed. This
    /// row is the one worth studying.
    @Test func aLabelTheRulesDeclineIsRecordedWithTheTitleTheUserChose() {
        let naming = MenuArchive.naming(
            volumeName: "ENEMYATTHEGATES",
            discID: "8a2b1c",
            derivedSearchTerm: DiscNameSearchTerm.derive(volumeName: "ENEMYATTHEGATES"),
            chosenTitle: "Enemy at the Gates",
            chosenYear: "2001",
            tmdbID: "621"
        )
        #expect(naming.volumeName == "ENEMYATTHEGATES", "the label is kept exactly as the drive reported it")
        #expect(naming.chosenTitle == "Enemy at the Gates")
        #expect(!naming.derivedMatchesChoice, "the rules did not recover the words")
    }

    /// And the case that works today, so a regression in the rules shows up
    /// as this flipping to false rather than as a quiet change in behaviour.
    @Test func aLabelTheRulesHandleIsRecordedAsAMatch() {
        let naming = MenuArchive.naming(
            volumeName: "ARMY_OF_DARKNESS",
            discID: nil,
            derivedSearchTerm: DiscNameSearchTerm.derive(volumeName: "ARMY_OF_DARKNESS"),
            chosenTitle: "Army of Darkness",
            chosenYear: "1992",
            tmdbID: "766"
        )
        #expect(naming.derivedSearchTerm == "Army of Darkness")
        #expect(naming.derivedMatchesChoice)
    }

    /// A generic label carries no title, so the rules decline — and that is a
    /// different thing from failing to segment one. The archive has to keep
    /// them apart or the "how often do the rules miss" count is meaningless.
    @Test func aGenericLabelIsRecordedAsNoTermRatherThanAWrongOne() {
        let naming = MenuArchive.naming(
            volumeName: "DVD_VIDEO",
            discID: nil,
            derivedSearchTerm: DiscNameSearchTerm.derive(volumeName: "DVD_VIDEO"),
            chosenTitle: "Fargo",
            chosenYear: "1996",
            tmdbID: "275"
        )
        #expect(naming.derivedSearchTerm == nil)
        #expect(!naming.derivedMatchesChoice)
    }

    // MARK: - Writing it

    @Test func theRecordLandsBesideTheDiscsMenusAndReadsBack() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("disc-naming-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let naming = MenuArchive.naming(
            volumeName: "ENEMYATTHEGATES",
            discID: "8a2b1c",
            derivedSearchTerm: nil,
            chosenTitle: "Enemy at the Gates",
            chosenYear: "2001",
            tmdbID: "621"
        )
        let path = try #require(MenuArchive.writeNaming(root: root, slug: "8a2b1c", naming: naming))
        #expect(path == "\(root)/8a2b1c/naming.json", "one directory per disc, beside its menus")

        let reread = try JSONDecoder().decode(
            MenuArchive.DiscNaming.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        #expect(reread == naming, "the record round-trips — collecting it is only useful if it reads back")
        #expect(reread.format == "changeover-disc-naming/1")
    }

    /// A second rip of the same disc rewrites the record rather than leaving
    /// the first answer in place — a retry after a wrong choice must not
    /// leave the archive asserting the wrong movie.
    @Test func aLaterRipOfTheSameDiscReplacesTheRecord() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("disc-naming-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        _ = MenuArchive.writeNaming(root: root, slug: "abc", naming: MenuArchive.naming(
            volumeName: "FARGO_WS", discID: "abc", derivedSearchTerm: "Fargo",
            chosenTitle: "Fargo", chosenYear: "1996", tmdbID: "275"
        ))
        let corrected = MenuArchive.naming(
            volumeName: "FARGO_WS", discID: "abc", derivedSearchTerm: "Fargo",
            chosenTitle: "Fargo", chosenYear: "1996", tmdbID: "275"
        )
        let path = try #require(MenuArchive.writeNaming(root: root, slug: "abc", naming: corrected))
        let reread = try JSONDecoder().decode(
            MenuArchive.DiscNaming.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        #expect(reread.chosenTitle == "Fargo")
    }

    /// The archive is never worth a rip. An unwritable root is silence.
    @Test func anUnwritableRootIsNotAFailure() {
        let naming = MenuArchive.naming(
            volumeName: "X", discID: nil, derivedSearchTerm: nil,
            chosenTitle: "X", chosenYear: "2000", tmdbID: "1"
        )
        #expect(MenuArchive.writeNaming(root: "/dev/null/nope", slug: "x", naming: naming) == nil)
    }
}
