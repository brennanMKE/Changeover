import Foundation
import Testing
@testable import Changeover

/// #0069 — the archive collected two of the three things an analysis needs.
///
/// It kept the menus, the OCR, the stills and the (label, chosen film) pair,
/// and threw away every number: how long each title runs, how many chapters
/// it has, what HandBrake claimed was the feature. And it wrote nothing at
/// all for a disc that was identified but never ripped — which on 2026-09-24
/// meant the single most informative event of the evening, a disc labelled
/// THESECRETLIFEOFWALTERMITTY identified as "The Caretaker", left no trace.
@Suite struct ArchiveCompletenessTests {

    private static func title(_ index: Int, _ seconds: Int, chapters: Int = 1) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: chapters,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }

    private static func tempRoot() -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("changeover-archive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - The scan

    /// Every title's duration survives the round trip. This is the half of
    /// the fingerprint that was missing entirely.
    @Test func theScanIsArchivedWithEveryTitlesDuration() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let disc = DiscInfo(volumeName: "IDENTITY", driveName: "disk4", titles: [
            Self.title(1, 5397, chapters: 28),
            Self.title(2, 5464, chapters: 28),
            Self.title(13, 146),
        ])
        let path = try #require(MenuArchive.writeScan(
            root: root, slug: "vol-identity", disc: disc, mainFeatureIndex: 13))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(MenuArchive.ArchivedScan.self, from: data)
        #expect(decoded.disc.titles.map(\.durationSeconds) == [5397, 5464, 146])
        #expect(decoded.disc.titles.map(\.chapterCount) == [28, 28, 1])
    }

    /// What HandBrake *claimed* is evidence in its own right. On The Bourne
    /// Identity it claimed a 2:26 trailer was the main feature; an archive
    /// keeping only the titles could never show that it had.
    @Test func whatTheScannerClaimedIsKeptToo() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let disc = DiscInfo(volumeName: "IDENTITY", driveName: "disk4",
                            titles: [Self.title(1, 5397), Self.title(13, 146)])
        let path = try #require(MenuArchive.writeScan(
            root: root, slug: "s", disc: disc, mainFeatureIndex: 13))
        let decoded = try JSONDecoder().decode(
            MenuArchive.ArchivedScan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(decoded.mainFeatureIndex == 13)
    }

    /// It lands beside the hand-captured corpus under the same name, so one
    /// piece of analysis code reads both.
    @Test func itIsWrittenWhereCaptureDiscScriptWritesIts() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = try #require(MenuArchive.writeScan(
            root: root, slug: "vol-x",
            disc: DiscInfo(volumeName: "X", driveName: "disk4", titles: [Self.title(1, 5000)]),
            mainFeatureIndex: 1))
        #expect(path.hasSuffix("vol-x/scan.json"))
    }

    /// An empty archive path disables collection entirely, as it always has.
    @Test func nothingIsWrittenWhenCollectionIsOff() {
        #expect(MenuArchive.writeScan(
            root: "", slug: "s",
            disc: DiscInfo(volumeName: "X", driveName: "disk4", titles: []),
            mainFeatureIndex: nil) == nil)
    }

    // MARK: - The naming record

    /// The TMDB id is the fact that makes a record checkable later without
    /// re-searching by title, and it is what a wrong identification gets
    /// wrong.
    @Test func theNamingRecordCarriesTheSelectedTmdbID() {
        let naming = MenuArchive.naming(
            volumeName: "THESECRETLIFEOFWALTERMITTY", discID: nil,
            derivedSearchTerm: "Thesecretlifeofwaltermitty",
            chosenTitle: "The Secret Life of Walter Mitty", chosenYear: "2013",
            tmdbID: "116745")
        #expect(naming.tmdbID == "116745")
        #expect(naming.volumeName == "THESECRETLIFEOFWALTERMITTY")
    }

    /// The failure that started this: a disc identified, never ripped, and
    /// previously unrecorded. `occasion` is what distinguishes it.
    @Test func aDiscIdentifiedButNeverRippedIsRecordedAsSuch() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let naming = MenuArchive.naming(
            volumeName: "THESECRETLIFEOFWALTERMITTY", discID: nil,
            derivedSearchTerm: "Thesecretlifeofwaltermitty",
            chosenTitle: "The Caretaker", chosenYear: "2026", tmdbID: "1495638",
            resolvedBy: "inference", menuTitle: nil, inferredTitle: "The Caretaker",
            candidateIDs: ["1495638", "1659351"], recommendedTmdbID: "1495638",
            selectedTitleIndex: 1, featureDurationSeconds: 6868,
            occasion: "identified")
        let path = try #require(MenuArchive.writeNaming(root: root, slug: "m", naming: naming))
        let decoded = try JSONDecoder().decode(
            MenuArchive.DiscNaming.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

        #expect(decoded.occasionOrRip == "identified")
        // Every fact needed to attribute the failure to a rung.
        #expect(decoded.resolvedBy == "inference")
        #expect(decoded.menuTitle == nil, "the menus named no film — that is the finding")
        #expect(decoded.inferredTitle == "The Caretaker")
        #expect(decoded.featureDurationSeconds == 6868)
        #expect(decoded.candidateIDs?.contains("1495638") == true)
    }

    /// A rip overwrites the identified record in place, so a ripped disc
    /// reads exactly as it did before and nothing downstream changes.
    @Test func aRipOverwritesTheIdentifiedRecord() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let identified = MenuArchive.naming(
            volumeName: "WILLIS", discID: nil, derivedSearchTerm: "Willis",
            chosenTitle: "The Whole Nine Yards", chosenYear: "2000",
            tmdbID: "2069", occasion: "identified")
        MenuArchive.writeNaming(root: root, slug: "w", naming: identified)
        let ripped = MenuArchive.naming(
            volumeName: "WILLIS", discID: nil, derivedSearchTerm: "Willis",
            chosenTitle: "The Whole Nine Yards", chosenYear: "2000",
            tmdbID: "2069", occasion: "rip")
        let path = try #require(MenuArchive.writeNaming(root: root, slug: "w", naming: ripped))
        let decoded = try JSONDecoder().decode(
            MenuArchive.DiscNaming.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(decoded.occasionOrRip == "rip")
    }

    /// A record written by an older build still decodes — every new field is
    /// optional, so the 21 already on joe are not orphaned.
    @Test func recordsFromBeforeThisChangeStillDecode() throws {
        let old = """
        {"format":"changeover-disc-naming/1","recordedAt":"2026-09-24T00:51:04Z",
         "volumeName":"WILLIS","discID":"vol:WILLIS|-|7867269120",
         "derivedSearchTerm":"Willis","derivedMatchesChoice":false,
         "chosenTitle":"The Whole Nine Yards","chosenYear":"2000","tmdbID":"2069"}
        """
        let decoded = try JSONDecoder().decode(
            MenuArchive.DiscNaming.self, from: Data(old.utf8))
        #expect(decoded.tmdbID == "2069")
        #expect(decoded.resolvedBy == nil)
        #expect(decoded.occasion == nil, "the key is absent, and must not be required")
        #expect(decoded.occasionOrRip == "rip", "records predating this were all written at rip time")
    }
}
