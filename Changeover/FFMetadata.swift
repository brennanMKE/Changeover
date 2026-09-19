import Foundation

/// The two text artefacts an upgrade produces before anything is written to
/// the library: the ffmetadata file, and the `ffmpeg` argument vector
/// (`docs/menu-intelligence.md` §7.5).
///
/// Both are pure, so the shape proved by hand on Bloodsport (2026-09-18) is
/// pinned by tests rather than by a shell history:
///
/// ```
/// ffmpeg -i <library file> -i chapters.ffmeta \
///        -map_metadata 1 -map_chapters 1 -map 0 -c copy \
///        -metadata:s:a:0 language=eng -metadata:s:a:0 title=English \
///        -movflags +faststart <staged .mp4>
/// ```
///
/// Two things in here are scars, not style:
///
/// - the chapter **timings come from the file's own inventory**, never from
///   the disc. Names are attached to moments that already exist; no moment is
///   moved, added or removed.
/// - the staged output keeps the `.mp4` extension. ffmpeg picks its muxer from
///   the output filename, so a `.enriching` suffix fails outright with
///   "Unable to choose an output format".
nonisolated enum FFMetadata {

    /// The ffmetadata file's name inside the staging directory.
    static let fileName = "chapters.ffmeta"

    /// The staged output's name: the destination's own name with an
    /// `.upgrade` marker **before** the extension, so the extension — and
    /// therefore ffmpeg's muxer choice — is unchanged.
    static func stagedFileName(for destinationFileName: String) -> String {
        let name = destinationFileName as NSString
        let ext = name.pathExtension
        guard !ext.isEmpty else { return destinationFileName + ".upgrade" }
        return "\(name.deletingPathExtension).upgrade.\(ext)"
    }

    /// One `[CHAPTER]` block per chapter, timings copied from `chapters` and
    /// names from `names` (matched by 1-based number).
    ///
    /// Returns `nil` when the two do not line up exactly — the same
    /// count-equality rule `UpgradeProposal` applies, checked again here at
    /// the point where a wrong file would actually be written.
    static func text(chapters: [ChapterSummary], names: [MarkerRow]) -> String? {
        guard !chapters.isEmpty, names.count == chapters.count else { return nil }
        guard names.map(\.number) == Array(1...chapters.count) else { return nil }

        var lines = [";FFMETADATA1"]
        for (index, chapter) in chapters.enumerated() {
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(chapter.startMS)")
            lines.append("END=\(chapter.endMS)")
            lines.append("title=\(escape(names[index].name))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// ffmetadata escapes `=`, `;`, `#` and `\` with a backslash, and a
    /// newline ends the value — so a name carrying one is flattened rather
    /// than silently truncating the file at that byte.
    static func escape(_ value: String) -> String {
        var escaped = ""
        for character in value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ") {
            if character == "=" || character == ";" || character == "#" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// The argument vector. `metadataPath` is `nil` for an audio-only
    /// upgrade, which needs no second input and no chapter mapping at all.
    static func arguments(
        input: String,
        metadataPath: String?,
        audio: [AudioTag],
        output: String
    ) -> [String] {
        // `-nostdin` so a background ffmpeg can never consume the app's
        // stdin; `-y` because the staged path is ours and freshly made.
        var arguments = ["-nostdin", "-y", "-i", input]
        if let metadataPath {
            arguments += ["-i", metadataPath, "-map_metadata", "1", "-map_chapters", "1"]
        }
        // `-map 0` keeps every stream of the original, and `-c copy` is what
        // makes this a remux: the verification checks the codecs afterwards
        // rather than trusting the flag.
        arguments += ["-map", "0", "-c", "copy"]
        for tag in audio.sorted(by: { $0.track < $1.track }) {
            if let language = tag.language {
                arguments += ["-metadata:s:a:\(tag.track)", "language=\(language)"]
            }
            if let title = tag.title {
                arguments += ["-metadata:s:a:\(tag.track)", "title=\(title)"]
            }
        }
        arguments += ["-movflags", "+faststart", output]
        return arguments
    }
}
