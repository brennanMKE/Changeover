import Foundation
import Testing
@testable import Changeover

/// §7.5 — the ffmetadata file, the `ffmpeg` argument vector, and the
/// verification that runs on the staged copy before the library file is
/// touched.
///
/// Every case here is a failure that actually happened while proving the
/// mechanism by hand on Bloodsport (2026-09-18).
struct UpgradeRemuxTests {

    static func inventory(_ name: String) throws -> LibraryFileInventory {
        try LibraryFileInventoryTests.inventory(name)
    }

    // MARK: - The ffmetadata file

    @Test func chapterTimingsComeFromTheFileNeverFromTheDisc() throws {
        let chapters = [
            ChapterSummary(startMS: 0, endMS: 255_000, title: "Chapter 1"),
            ChapterSummary(startMS: 255_000, endMS: 500_123, title: "Chapter 2"),
        ]
        let names = [MarkerRow(number: 1, name: "World's warriors"), MarkerRow(number: 2, name: "Dux ducks out")]

        let text = try #require(FFMetadata.text(chapters: chapters, names: names))

        #expect(text.hasPrefix(";FFMETADATA1\n"))
        #expect(text.contains("TIMEBASE=1/1000\nSTART=255000\nEND=500123\ntitle=Dux ducks out"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func aCountMismatchProducesNoMetadataFileAtAll() {
        let chapters = [ChapterSummary(startMS: 0, endMS: 1000, title: "")]
        let names = [MarkerRow(number: 1, name: "A"), MarkerRow(number: 2, name: "B")]
        #expect(FFMetadata.text(chapters: chapters, names: names) == nil)
        #expect(FFMetadata.text(chapters: [], names: []) == nil)
    }

    @Test func metadataSpecialCharactersAreEscapedAndNewlinesFlattened() {
        #expect(FFMetadata.escape("A = B") == "A \\= B")
        #expect(FFMetadata.escape("semi; hash# slash\\") == "semi\\; hash\\# slash\\\\")
        #expect(FFMetadata.escape("two\nlines") == "two lines")
    }

    // MARK: - The staged filename

    /// ffmpeg picks its muxer from the output filename. A `.enriching` suffix
    /// fails outright with "Unable to choose an output format", which is
    /// exactly what happened by hand.
    @Test func theStagedFileKeepsTheMP4Extension() {
        #expect(FFMetadata.stagedFileName(for: "Bloodsport (1988).mp4") == "Bloodsport (1988).upgrade.mp4")
        #expect(FFMetadata.stagedFileName(for: "x.m4v") == "x.upgrade.m4v")
        #expect((FFMetadata.stagedFileName(for: "Bloodsport (1988).mp4") as NSString).pathExtension == "mp4")
    }

    // MARK: - The argument vector

    @Test func theArgumentVectorIsTheOneProvedByHand() {
        let arguments = FFMetadata.arguments(
            input: "/Plex/Bloodsport (1988).mp4",
            metadataPath: "/staging/chapters.ffmeta",
            audio: [AudioTag(track: 0, language: "eng", title: "English")],
            output: "/staging/Bloodsport (1988).upgrade.mp4"
        )

        #expect(arguments == [
            "-nostdin", "-y",
            "-i", "/Plex/Bloodsport (1988).mp4",
            "-i", "/staging/chapters.ffmeta",
            "-map_metadata", "1", "-map_chapters", "1",
            "-map", "0", "-c", "copy",
            "-metadata:s:a:0", "language=eng",
            "-metadata:s:a:0", "title=English",
            "-movflags", "+faststart",
            "/staging/Bloodsport (1988).upgrade.mp4",
        ])
    }

    @Test func anAudioOnlyUpgradeTakesNoSecondInput() {
        let arguments = FFMetadata.arguments(
            input: "/a.mp4",
            metadataPath: nil,
            audio: [AudioTag(track: 1, language: "fra", title: nil)],
            output: "/b.mp4"
        )
        #expect(!arguments.contains("-map_chapters"))
        #expect(arguments.filter { $0 == "-i" }.count == 1)
        #expect(arguments.contains("-metadata:s:a:1"))
        #expect(arguments.contains("language=fra"))
        #expect(!arguments.contains(where: { $0.hasPrefix("title=") }))
    }

    /// `-c copy` is what makes this a remux. Its absence would be a
    /// re-encode, which is the one thing this feature promises never to do.
    @Test func theCopyCodecIsAlwaysPresent() throws {
        let arguments = FFMetadata.arguments(input: "/a.mp4", metadataPath: nil, audio: [], output: "/b.mp4")
        let index = try #require(arguments.firstIndex(of: "-c"))
        #expect(arguments[index + 1] == "copy")
    }

    @Test func ffprobeIsFoundBesideFFmpeg() {
        #expect(UpgradeController.ffprobePath(forFFmpegPath: "/opt/homebrew/bin/ffmpeg") == "/opt/homebrew/bin/ffprobe")
        #expect(UpgradeController.ffprobePath(forFFmpegPath: "/usr/local/bin/ffmpeg7") == "/usr/local/bin/ffprobe7")
        #expect(UpgradeController.ffprobePath(forFFmpegPath: "") == "")
    }

    // MARK: - Verification

    static func plan() -> UpgradePlan {
        UpgradePlan(
            filePath: "/Plex/Bloodsport (1988).mp4",
            chapters: (1...23).map { MarkerRow(number: $0, name: ChapterNamesTests.expectedNames[$0 - 1]) },
            audio: [AudioTag(track: 0, language: "eng", title: "English")]
        )
    }

    /// The real before/after pair: a finer chapter timebase, a departed
    /// `bin_data` stream, and the audio title read back as `name`. All three
    /// are what a naive verification gets wrong.
    @Test func therealRemuxPasses() throws {
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: try Self.inventory("bloodsport-upgraded.json"),
            plan: Self.plan()
        )
        #expect(verdict == .ok)
    }

    @Test func aReEncodedVideoStreamIsCaught() throws {
        var upgraded = try Self.inventory("bloodsport-upgraded.json")
        upgraded.video?.codec = "h264"
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: upgraded,
            plan: Self.plan()
        )
        #expect(verdict.reason?.contains("that is a re-encode, not a copy") == true)
    }

    @Test func aReEncodedAudioStreamIsCaught() throws {
        var upgraded = try Self.inventory("bloodsport-upgraded.json")
        upgraded.audio[0].channels = 6
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: upgraded,
            plan: Self.plan()
        )
        #expect(verdict.reason?.contains("channels") == true)
    }

    @Test func aDurationThatDriftedIsCaught() throws {
        var upgraded = try Self.inventory("bloodsport-upgraded.json")
        upgraded.durationMS += 4_000
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: upgraded,
            plan: Self.plan()
        )
        #expect(verdict.reason?.contains("runs") == true)
    }

    @Test func aChapterThatMovedIsCaught() throws {
        var upgraded = try Self.inventory("bloodsport-upgraded.json")
        upgraded.chapters[4].startMS += 40
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: upgraded,
            plan: Self.plan()
        )
        #expect(verdict.reason?.hasPrefix("chapter 5 moved") == true)
    }

    @Test func aNameThatWasNotActuallyWrittenIsCaught() throws {
        var upgraded = try Self.inventory("bloodsport-upgraded.json")
        upgraded.chapters[0].title = "Chapter 1"
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: upgraded,
            plan: Self.plan()
        )
        #expect(verdict.reason?.contains("should read “World's warriors”") == true)
    }

    @Test func anAudioTagThatWasNotActuallyWrittenIsCaught() throws {
        var upgraded = try Self.inventory("bloodsport-upgraded.json")
        upgraded.audio[0].language = nil
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: upgraded,
            plan: Self.plan()
        )
        #expect(verdict.reason?.contains("should be tagged eng") == true)
    }

    @Test func aFileThatChangedSizeSubstantiallyIsCaught() throws {
        var upgraded = try Self.inventory("bloodsport-upgraded.json")
        upgraded.sizeBytes = (upgraded.sizeBytes ?? 0) / 2
        let verdict = RemuxVerification.verify(
            original: try Self.inventory("bloodsport-library.json"),
            upgraded: upgraded,
            plan: Self.plan()
        )
        #expect(verdict.reason?.contains("re-encoded something") == true)
    }

    /// The `bin_data` stream a DVD rip carries does **not** survive an MP4
    /// remux. That is junk leaving, not data lost, and a verification that
    /// compared stream counts would refuse every good upgrade.
    @Test func aDepartedBinDataStreamIsNotTreatedAsDataLost() throws {
        let original = try Self.inventory("bloodsport-library.json")
        let upgraded = try Self.inventory("bloodsport-upgraded.json")
        #expect(original.otherStreamCount > upgraded.otherStreamCount)
        #expect(RemuxVerification.verify(original: original, upgraded: upgraded, plan: Self.plan()) == .ok)
    }

    @Test func aLostSubtitleStreamIsCaught() throws {
        var original = try Self.inventory("bloodsport-library.json")
        original.subtitleCount = 1
        let verdict = RemuxVerification.verify(
            original: original,
            upgraded: try Self.inventory("bloodsport-upgraded.json"),
            plan: Self.plan()
        )
        #expect(verdict.reason == "the rewritten file lost a subtitle stream")
    }
}
