import Foundation
import Testing
@testable import Changeover

/// #0187 — "do I already have this featurette?" is answerable after all.
///
/// #0185 said it was not: Plex has no per-extra record to query the way
/// `LibraryProbe` queries a film's `{tmdb-ID}` folder, so the doubt resolved
/// towards keeping the disc. The user pointed out the obvious — Plex keeps
/// extras in named subfolders of the movie's own folder, so the answer is on
/// the filesystem next to the film, in the folder the app already lists.
///
/// Matched on duration, not on name. The library copy was named by whatever
/// tool filed it, possibly by hand and possibly years ago; the disc's label
/// comes off a menu read through OCR. Two runtimes agreeing is evidence. Two
/// names agreeing is a coincidence waiting to happen.
@Suite struct LibraryExtrasTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.33)
    }

    private static func filed(_ folder: String, _ name: String, seconds: Int?) -> LibraryExtraFile {
        LibraryExtraFile(folderName: folder,
                         file: LibraryFile(name: name, sizeBytes: 1,
                                           durationSeconds: seconds))
    }

    /// Signs' six featurettes, half of them already filed.
    private static let signsExtras = [
        title(9, seconds: 375), title(10, seconds: 485), title(11, seconds: 1357),
        title(12, seconds: 516), title(13, seconds: 510), title(14, seconds: 291),
    ]

    /// #0231 — a title must not lose its file to a title that merely tolerates it.
    ///
    /// Observed on Pacific Rim: Uprising, where all 17 extras had imported
    /// successfully and `library` reported three of them missing. The matcher
    /// walked titles in index order and gave each its nearest unclaimed file,
    /// so title 11 (0:32) took the 0:38 file — six seconds out, inside the
    /// twelve-second tolerance, nothing closer left — and title 30, whose
    /// runtime is 0:38 exactly, was then reported as not in the library.
    ///
    /// The output is agent-facing, which is what makes it serious: it does not
    /// merely omit something, it states confidently that three extras are
    /// missing, and an agent acting on that re-imports files already filed.
    @Test func aperfectMatchIsClaimedBeforeAToleratedOne() {
        let titles = [Self.title(11, seconds: 32), Self.title(30, seconds: 38)]
        let files = [Self.filed("Featurettes", "Jake & Nate Discuss Jake's Return.mp4", seconds: 38)]
        let verdicts = LibraryExtras.verdicts(forTitles: titles, against: files)

        #expect(verdicts.first { $0.titleIndex == 30 }?.existing?.file.name
                == "Jake & Nate Discuss Jake's Return.mp4",
                "the 0:38 file belongs to the title whose runtime is 0:38")
        #expect(verdicts.first { $0.titleIndex == 11 }?.isHeld == false)
        #expect(LibraryExtras.stillMissing(verdicts) == [11])
    }

    /// The same shape with every extra present, which is the real disc.
    ///
    /// Three near-duplicate runtimes and three files that match them exactly.
    /// Index order would have the 0:32 titles consume the 0:35 and 0:38 files
    /// and report the titles those files came from as missing. Nothing should
    /// be missing here.
    @Test func closeRuntimesAllPairWithTheirOwnFile() {
        let titles = [
            Self.title(9, seconds: 32), Self.title(11, seconds: 32),
            Self.title(30, seconds: 38), Self.title(33, seconds: 35),
        ]
        let files = [
            Self.filed("Featurettes", "a.mp4", seconds: 32),
            Self.filed("Featurettes", "b.mp4", seconds: 32),
            Self.filed("Featurettes", "Jake & Nate.mp4", seconds: 38),
            Self.filed("Featurettes", "Kaiju Brain from Fury.mp4", seconds: 35),
        ]
        let verdicts = LibraryExtras.verdicts(forTitles: titles, against: files)

        #expect(LibraryExtras.stillMissing(verdicts).isEmpty,
                "every title has an exact-length file; none should be reported missing")
        #expect(verdicts.first { $0.titleIndex == 30 }?.existing?.file.name == "Jake & Nate.mp4")
        #expect(verdicts.first { $0.titleIndex == 33 }?.existing?.file.name
                == "Kaiju Brain from Fury.mp4")
    }

    /// Order of the library listing must not change the answer.
    ///
    /// The filesystem decides what order `LibraryProbe` returns files in, and
    /// that is not something a report should depend on.
    @Test func thelistingOrderDoesNotChangeTheResult() {
        let titles = [Self.title(11, seconds: 32), Self.title(30, seconds: 38)]
        let forward = [Self.filed("F", "x.mp4", seconds: 38), Self.filed("F", "y.mp4", seconds: 32)]
        let reversed = Array(forward.reversed())

        let a = LibraryExtras.verdicts(forTitles: titles, against: forward)
        let b = LibraryExtras.verdicts(forTitles: titles, against: reversed)
        #expect(a == b)
        #expect(a.first { $0.titleIndex == 30 }?.existing?.file.name == "x.mp4")
    }

    @Test func atitleAlreadyFiledIsRecognisedByItsRuntime() {
        let verdicts = LibraryExtras.verdicts(
            forTitles: Self.signsExtras,
            against: [Self.filed("Behind The Scenes", "looking for Signs.mp4", seconds: 375)])
        #expect(verdicts.first { $0.titleIndex == 9 }?.isHeld == true)
        #expect(LibraryExtras.stillMissing(verdicts) == [10, 11, 12, 13, 14])
    }

    /// The name on disk is irrelevant — this is the whole point of matching on
    /// duration. A copy filed by hand years ago under any name at all is still
    /// recognised.
    @Test func thenameOnDiskDoesNotMatter() {
        let verdicts = LibraryExtras.verdicts(
            forTitles: [Self.title(11, seconds: 1357)],
            against: [Self.filed("Featurettes", "bonus_02_FINAL.mkv", seconds: 1360)])
        #expect(verdicts[0].isHeld)
    }

    /// Nothing filed, nothing held — every extra is still worth importing.
    @Test func anEmptyFolderHoldsNothing() {
        let verdicts = LibraryExtras.verdicts(forTitles: Self.signsExtras, against: [])
        #expect(verdicts.allSatisfy { !$0.isHeld })
        #expect(LibraryExtras.stillMissing(verdicts).count == 6)
    }

    /// A file whose runtime could not be read is NOT evidence of presence.
    /// The safe direction: offering a re-encode the user can cancel beats
    /// silently losing an extra, which is what libraries have been doing for
    /// years.
    @Test func anUnreadableFileLeavesTheTitleImportable() {
        let verdicts = LibraryExtras.verdicts(
            forTitles: [Self.title(9, seconds: 375)],
            against: [Self.filed("Behind The Scenes", "looking for Signs.mp4", seconds: nil)])
        #expect(!verdicts[0].isHeld)
    }

    /// One file answers for one title. Two extras of the same length on one
    /// disc are two different videos, and the second must not be declared held
    /// on the strength of the first.
    @Test func onefileCannotAccountForTwoTitles() {
        let verdicts = LibraryExtras.verdicts(
            forTitles: [Self.title(9, seconds: 375), Self.title(10, seconds: 377)],
            against: [Self.filed("Featurettes", "one.mp4", seconds: 376)])
        #expect(verdicts.filter(\.isHeld).count == 1)
        #expect(LibraryExtras.stillMissing(verdicts).count == 1)
    }

    /// Far enough off is a different video, not a sloppy encode.
    @Test func adifferentLengthIsADifferentVideo() {
        let verdicts = LibraryExtras.verdicts(
            forTitles: [Self.title(9, seconds: 375)],
            against: [Self.filed("Featurettes", "something else.mp4", seconds: 900)])
        #expect(!verdicts[0].isHeld)
    }

    /// The claim is checkable: it names the file it found rather than asking
    /// to be taken on trust — the standard #0153 set.
    @Test func theheldSentenceNamesTheFile() throws {
        let verdicts = LibraryExtras.verdicts(
            forTitles: [Self.title(9, seconds: 375)],
            against: [Self.filed("Behind The Scenes", "looking for Signs.mp4", seconds: 375)])
        let detail = try #require(LibraryExtras.heldDetail(verdicts[0]))
        #expect(detail == "title 9 is already in Behind The Scenes/looking for Signs.mp4")
    }

    /// A folder whose only videos are extras is still not a duplicate of the
    /// FILM: nothing would be overwritten, and refusing a rip on the strength
    /// of a featurette would be the worst possible reading.
    @Test func afolderWithOnlyExtrasIsNotAFilm() {
        let lookup = LibraryMatch.lookup(foldersWithExtras: [(
            "Signs (2002) {tmdb-2675}", "/Movies/Signs (2002) {tmdb-2675}",
            [],
            [Self.filed("Behind The Scenes", "making of.mp4", seconds: 3534)]
        )])
        #expect(lookup == .absent)
    }

    /// And when the film IS there, the extras ride along with it.
    @Test func thefilmCarriesItsExtras() throws {
        let lookup = LibraryMatch.lookup(foldersWithExtras: [(
            "Signs (2002) {tmdb-2675}", "/Movies/Signs (2002) {tmdb-2675}",
            [LibraryFile(name: "Signs (2002).mp4", sizeBytes: 1)],
            [Self.filed("Behind The Scenes", "making of.mp4", seconds: 3534)]
        )])
        guard case .present(let entries) = lookup else {
            Issue.record("the film is there"); return
        }
        let entry = try #require(entries.first)
        #expect(entry.files.count == 1)
        #expect(entry.extras.count == 1)
        #expect(entry.extras[0].folderName == "Behind The Scenes")
    }
}
