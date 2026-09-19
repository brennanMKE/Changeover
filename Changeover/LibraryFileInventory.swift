import Foundation

/// What one video stream in a library file looks like to us
/// (`docs/menu-intelligence.md` §7.2).
nonisolated struct StreamSummary: Equatable, Sendable, Codable {
    var index: Int
    var codec: String
    var width: Int?
    var height: Int?
}

/// One audio stream, as `ffprobe` reports it.
///
/// `title` is read from **both** `tags.title` and `tags.name`: in MP4 an audio
/// track title written with `-metadata:s:a:0 title=…` is read back as the
/// `name` tag, not `title` (measured by hand on Bloodsport, 2026-09-18). A
/// verification that only looked for `title` would report a successful write
/// as a failure and refuse a perfectly good upgrade.
nonisolated struct AudioSummary: Equatable, Sendable, Codable {
    /// The stream's index **within the audio streams**, 0-based — what
    /// `-metadata:s:a:<n>` addresses, not ffprobe's global stream index.
    var track: Int
    var codec: String
    var channels: Int
    /// `nil` when absent or `und` (`LanguageCode.normalize`'s rule).
    var language: String?
    var title: String?
}

/// One chapter, in milliseconds.
///
/// **Milliseconds, never ffprobe's raw `start`/`end`.** A remux rewrites the
/// chapter atom on the container's own timebase — 1/90000 where the source
/// used 1/1000 — so the raw integers differ by three orders of magnitude while
/// the moments they name are identical. Comparing raw values would fail every
/// verification; comparing milliseconds is comparing the thing that matters.
nonisolated struct ChapterSummary: Equatable, Sendable, Codable {
    var startMS: Int
    var endMS: Int
    var title: String
}

/// #0062/§7.2 — what is actually *inside* a file already in the Plex library.
///
/// The duplicate check (`LibraryProbe`) already says a film is there; this
/// says what it has. Filled by `ffprobe -v error -print_format json
/// -show_format -show_streams -show_chapters <file>`, which is optional
/// (`brew install ffmpeg`) and never on the rip path.
///
/// `parse` is pure over the JSON bytes, so every rule below — the placeholder
/// chapter-name test, the millisecond conversion, the MP4 `name`-vs-`title`
/// quirk — is unit-tested with no `ffprobe`, no library volume and no disc.
nonisolated struct LibraryFileInventory: Equatable, Sendable, Codable {
    var durationMS: Int
    var sizeBytes: Int64?
    var video: StreamSummary?
    var audio: [AudioSummary]
    var subtitleCount: Int
    /// Streams that are neither video, audio nor subtitle — a DVD rip's
    /// leftover `bin_data` timed-metadata stream being the one that turns up
    /// in practice. Counted so verification can say "junk left" rather than
    /// "a stream was lost": these do **not** survive an MP4 remux, and that is
    /// correct behaviour, not data loss.
    var otherStreamCount: Int
    var chapters: [ChapterSummary]

    var durationSeconds: Int { Int((Double(durationMS) / 1000).rounded()) }

    init(
        durationMS: Int,
        sizeBytes: Int64? = nil,
        video: StreamSummary? = nil,
        audio: [AudioSummary] = [],
        subtitleCount: Int = 0,
        otherStreamCount: Int = 0,
        chapters: [ChapterSummary] = []
    ) {
        self.durationMS = durationMS
        self.sizeBytes = sizeBytes
        self.video = video
        self.audio = audio
        self.subtitleCount = subtitleCount
        self.otherStreamCount = otherStreamCount
        self.chapters = chapters
    }

    // MARK: - Chapter names

    /// True when every chapter title is empty or a placeholder — i.e. nobody
    /// ever named them. This is the gate on rewriting chapter names without
    /// asking: a file whose chapters carry real names is never renamed unless
    /// the user explicitly ticks to overwrite them.
    var chaptersAreUnnamed: Bool {
        !chapters.isEmpty && chapters.allSatisfy { Self.isPlaceholderChapterName($0.title) }
    }

    /// How many chapters carry a name a person would recognise as a name.
    var namedChapterCount: Int {
        chapters.filter { !Self.isPlaceholderChapterName($0.title) }.count
    }

    /// Empty, or one of the shapes a tool writes when it has no name to write:
    /// `Chapter 4`, `Chapter 04`, `chapter 4`, a bare `4`, `Scene 4`,
    /// `Kapitel 4`. Deliberately narrow — anything else is a real name, and a
    /// real name is never overwritten silently.
    static func isPlaceholderChapterName(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lowered = trimmed.lowercased()
        if Int(lowered) != nil { return true }
        for word in ["chapter", "scene", "kapitel", "chapitre", "capítulo", "capitulo", "part"] {
            if lowered.hasPrefix(word + " "), Int(lowered.dropFirst(word.count + 1).trimmingCharacters(in: .whitespaces)) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Parsing ffprobe's JSON

    /// The exact argument vector `ffprobe` is run with. Pure so the flags are
    /// pinned by a test rather than by whatever a shell history remembers.
    static func ffprobeArguments(path: String) -> [String] {
        [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-show_chapters",
            path,
        ]
    }

    /// `nil` when the bytes are not ffprobe's JSON at all. A file with no
    /// chapters, no audio or no duration still parses — those are facts about
    /// the file, not parse failures.
    ///
    /// Hand-decoded through `JSONSerialization` rather than `Codable`:
    /// ffprobe types the same quantity two ways in the same document
    /// (`start` is a number, `start_time` a string; `duration` is a string in
    /// `format` and sometimes absent in `streams`), and a `Codable` model of
    /// that is more fragile than reading the handful of keys we need.
    static func parse(ffprobeJSON: Data) -> LibraryFileInventory? {
        guard let root = (try? JSONSerialization.jsonObject(with: ffprobeJSON)) as? [String: Any] else {
            return nil
        }
        guard root["streams"] != nil || root["format"] != nil else { return nil }

        let format = root["format"] as? [String: Any]
        let durationMS = format.flatMap { number($0["duration"]) }.map { Int(($0 * 1000).rounded()) } ?? 0
        let sizeBytes = format.flatMap { number($0["size"]) }.map { Int64($0) }

        var video: StreamSummary?
        var audio: [AudioSummary] = []
        var subtitleCount = 0
        var otherStreamCount = 0

        for case let stream as [String: Any] in (root["streams"] as? [Any] ?? []) {
            let index = number(stream["index"]).map { Int($0) } ?? 0
            let codec = stream["codec_name"] as? String ?? "?"
            let tags = stream["tags"] as? [String: Any]
            switch stream["codec_type"] as? String {
            case "video":
                // The first video stream is the movie; an embedded cover-art
                // "video" stream (`attached_pic`) is not, and must never be
                // mistaken for it.
                if number(stream["disposition"].flatMap { ($0 as? [String: Any])?["attached_pic"] }) == 1 {
                    otherStreamCount += 1
                } else if video == nil {
                    video = StreamSummary(
                        index: index,
                        codec: codec,
                        width: number(stream["width"]).map { Int($0) },
                        height: number(stream["height"]).map { Int($0) }
                    )
                } else {
                    otherStreamCount += 1
                }
            case "audio":
                audio.append(AudioSummary(
                    track: audio.count,
                    codec: codec,
                    channels: number(stream["channels"]).map { Int($0) } ?? 0,
                    language: LanguageCode.normalize(tags?["language"] as? String),
                    title: trimmedOrNil(tags?["title"] as? String) ?? trimmedOrNil(tags?["name"] as? String)
                ))
            case "subtitle":
                subtitleCount += 1
            default:
                otherStreamCount += 1
            }
        }

        var chapters: [ChapterSummary] = []
        for case let chapter as [String: Any] in (root["chapters"] as? [Any] ?? []) {
            let scale = timebaseScale(chapter["time_base"] as? String)
            let start = number(chapter["start"]).map { $0 * scale }
                ?? number(chapter["start_time"]).map { $0 * 1000 } ?? 0
            let end = number(chapter["end"]).map { $0 * scale }
                ?? number(chapter["end_time"]).map { $0 * 1000 } ?? 0
            let tags = chapter["tags"] as? [String: Any]
            chapters.append(ChapterSummary(
                startMS: Int(start.rounded()),
                endMS: Int(end.rounded()),
                title: (tags?["title"] as? String) ?? ""
            ))
        }

        return LibraryFileInventory(
            durationMS: durationMS,
            sizeBytes: sizeBytes,
            video: video,
            audio: audio,
            subtitleCount: subtitleCount,
            otherStreamCount: otherStreamCount,
            chapters: chapters
        )
    }

    /// `"1/1000"` → 1 ms per unit; `"1/90000"` → 1/90 ms per unit. Anything
    /// unparseable falls back to milliseconds, which is what every MP4 this
    /// app writes actually uses.
    private static func timebaseScale(_ timeBase: String?) -> Double {
        guard let timeBase else { return 1 }
        let parts = timeBase.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else {
            return 1
        }
        return numerator / denominator * 1000
    }

    /// ffprobe writes the same quantity as a number or a string depending on
    /// which section it is in.
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
