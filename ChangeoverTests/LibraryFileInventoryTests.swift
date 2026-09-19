import Foundation
import Testing
@testable import Changeover

/// §7.2 — reading what is actually inside a file already in the Plex library,
/// and the file-only half of §7's comparison (`LibraryFileGaps`), which a
/// library-wide sweep could run over 200 files with no disc anywhere near it.
///
/// The three captures under `Fixtures/ffprobe/` are the two real library files
/// §7.1 names plus the remuxed result of one of them. Every quirk asserted
/// here cost a real failure by hand on 2026-09-18.
struct LibraryFileInventoryTests {

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ffprobe/\(name)"))
    }

    static func inventory(_ name: String) throws -> LibraryFileInventory {
        let parsed = LibraryFileInventory.parse(ffprobeJSON: try fixture(name))
        return try #require(parsed)
    }

    // MARK: - The two library files §7.1 names

    @Test func oppenheimerHasTwentyPlaceholderChapters() throws {
        let inventory = try Self.inventory("oppenheimer-library.json")

        #expect(inventory.chapters.count == 20)
        #expect(inventory.chaptersAreUnnamed)
        #expect(inventory.namedChapterCount == 0)
        #expect(inventory.chapters.first?.title == "Chapter 1")
        #expect(inventory.durationSeconds == 10811)
        #expect(inventory.audio.count == 1)
        #expect(inventory.audio[0].language == "eng")
        #expect(inventory.audio[0].title == nil)
        #expect(inventory.video?.codec == "hevc")
    }

    @Test func bloodsportHasTwentyThreeChaptersAndAnUntaggedTrack() throws {
        let inventory = try Self.inventory("bloodsport-library.json")

        #expect(inventory.chapters.count == 23)
        #expect(inventory.chaptersAreUnnamed)
        // The gap this whole feature exists for: no language at all.
        #expect(inventory.audio[0].language == nil)
        #expect(inventory.audio[0].channels == 2)
    }

    /// A DVD rip carries a `bin_data` stream that an MP4 remux drops. It is
    /// counted apart from video/audio/subtitles so verification can say "junk
    /// left" rather than "a stream was lost".
    @Test func binDataIsCountedAsAnOtherStreamRatherThanLost() throws {
        let before = try Self.inventory("bloodsport-library.json")
        let after = try Self.inventory("bloodsport-upgraded.json")

        #expect(before.otherStreamCount == 1)
        #expect(after.otherStreamCount == 0)
        #expect(before.audio.count == after.audio.count)
        #expect(before.video?.codec == after.video?.codec)
    }

    /// The remux rewrites chapters on a finer timebase, so ffprobe's raw
    /// integers differ by a factor of 90 while the moments are identical.
    /// Comparing raw values would fail every verification; the inventory
    /// normalises to milliseconds, which is the thing that matters.
    @Test func chapterTimesSurviveATimebaseChange() throws {
        let before = try Self.inventory("bloodsport-library.json")
        let after = try Self.inventory("bloodsport-upgraded.json")

        #expect(before.chapters.count == after.chapters.count)
        for (index, pair) in zip(before.chapters, after.chapters).enumerated() {
            #expect(abs(pair.0.startMS - pair.1.startMS) <= 1, "chapter \(index + 1) start")
            #expect(abs(pair.0.endMS - pair.1.endMS) <= 1, "chapter \(index + 1) end")
        }
    }

    /// In MP4 an audio title written with `-metadata:s:a:0 title=…` is read
    /// back as the `name` tag. A reader that only looked for `title` would
    /// report a successful write as a failure.
    @Test func audioTitleIsReadBackFromTheMP4NameTag() throws {
        let after = try Self.inventory("bloodsport-upgraded.json")
        #expect(after.audio[0].title == "English")
        #expect(after.audio[0].language == "eng")
    }

    // MARK: - Placeholder names

    @Test(arguments: ["", "   ", "Chapter 1", "chapter 04", "Scene 12", "Kapitel 3", "7"])
    func placeholderNamesAreRecognised(_ title: String) {
        #expect(LibraryFileInventory.isPlaceholderChapterName(title))
    }

    @Test(arguments: ["World's warriors", "Chapter and Verse", "Scene of the crime", "Chapter 1: Training"])
    func realNamesAreNeverTreatedAsPlaceholders(_ title: String) {
        #expect(!LibraryFileInventory.isPlaceholderChapterName(title))
    }

    @Test func aFileWithOneRealNameIsNotUnnamed() {
        let inventory = LibraryFileInventory(durationMS: 1000, chapters: [
            ChapterSummary(startMS: 0, endMS: 500, title: "Chapter 1"),
            ChapterSummary(startMS: 500, endMS: 1000, title: "Training"),
        ])
        #expect(!inventory.chaptersAreUnnamed)
        #expect(inventory.namedChapterCount == 1)
    }

    // MARK: - Parsing edges

    @Test func nonsenseIsRefusedRatherThanParsedAsAnEmptyFile() {
        #expect(LibraryFileInventory.parse(ffprobeJSON: Data("not json".utf8)) == nil)
        #expect(LibraryFileInventory.parse(ffprobeJSON: Data("{}".utf8)) == nil)
    }

    @Test func aFileWithNoChaptersStillParses() throws {
        let json = """
        {"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":720,"height":480}],
         "format":{"duration":"120.0","size":"100"}}
        """
        let inventory = try #require(LibraryFileInventory.parse(ffprobeJSON: Data(json.utf8)))
        #expect(inventory.chapters.isEmpty)
        #expect(!inventory.chaptersAreUnnamed)
        #expect(inventory.durationSeconds == 120)
    }

    /// Cover art is an `attached_pic` "video" stream and must never be
    /// mistaken for the movie.
    @Test func coverArtIsNotTheVideoStream() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_name":"mjpeg","codec_type":"video","width":600,"height":900,
           "disposition":{"attached_pic":1}},
          {"index":1,"codec_name":"hevc","codec_type":"video","width":720,"height":480,
           "disposition":{"attached_pic":0}}],
         "format":{"duration":"10.0"}}
        """
        let inventory = try #require(LibraryFileInventory.parse(ffprobeJSON: Data(json.utf8)))
        #expect(inventory.video?.codec == "hevc")
        #expect(inventory.otherStreamCount == 1)
    }

    @Test func theArgumentVectorIsTheOneWeMeant() {
        #expect(LibraryFileInventory.ffprobeArguments(path: "/a/b.mp4") == [
            "-v", "error", "-print_format", "json",
            "-show_format", "-show_streams", "-show_chapters", "/a/b.mp4",
        ])
    }

    // MARK: - The file-only half (what a library sweep would list)

    @Test func gapsAreReadableFromTheFileAloneWithNoDisc() throws {
        let gaps = LibraryFileGaps.find(try Self.inventory("bloodsport-library.json"))

        #expect(gaps.wantsChapterNames)
        #expect(gaps.chapterCount == 23)
        #expect(gaps.untaggedAudioTracks == [0])
        #expect(gaps.hasNoSubtitles)
        #expect(!gaps.isEmpty)
        #expect(gaps.summaryLine == "23 chapters, all unnamed · 1 audio track with no language · no subtitles")
    }

    @Test func oppenheimerGapsAreChapterNamesOnly() throws {
        let gaps = LibraryFileGaps.find(try Self.inventory("oppenheimer-library.json"))

        #expect(gaps.wantsChapterNames)
        #expect(gaps.chapterCount == 20)
        // Its audio is tagged `eng`, so the language is not a gap — only the
        // track's name is.
        #expect(gaps.untaggedAudioTracks.isEmpty)
        #expect(gaps.untitledAudioTracks == [0])
    }

    @Test func aFileWithNothingToGainSaysSo() {
        let inventory = LibraryFileInventory(
            durationMS: 1000,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: "eng", title: "English")],
            subtitleCount: 1,
            chapters: [ChapterSummary(startMS: 0, endMS: 1000, title: "Training")]
        )
        let gaps = LibraryFileGaps.find(inventory)
        #expect(gaps.isEmpty)
        #expect(gaps.summaryLine.isEmpty)
    }
}
