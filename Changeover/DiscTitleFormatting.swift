import Foundation

/// #0026 — pure formatting/derivation helpers for the disc title list, kept
/// out of `DiscTitleListView` so they're unit-testable with no SwiftUI and no
/// disc.
nonisolated enum DiscTitleFormatting {
    /// `H:MM:SS`, e.g. 6645 seconds → "1:50:45" — the confirmation row's
    /// worked example in the Plan ("Title 3 · 1:50:45 · 21 chapters").
    static func duration(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    /// `ByteCountFormatter` in file style, e.g. "6.3 GB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "2 audio (eng, spa) · 1 sub" — must survive a title where **no**
    /// stream carries a language tag at all (`hornets-nest-min0.txt`'s
    /// feature has zero attribute-3 lines across every stream): the
    /// parenthetical is omitted entirely, never rendered as "()" or "(nil)".
    /// A single untagged stream among tagged siblings likewise contributes
    /// nothing to the parenthetical, since `orderedUniqueLanguages` only
    /// collects streams that actually carry a code.
    static func streamSummary(for title: DiscTitle) -> String {
        let audio = title.streams.filter { $0.kind == .audio }
        let subtitles = title.streams.filter { $0.kind == .subtitle }

        var parts: [String] = []
        if !audio.isEmpty {
            let languages = orderedUniqueLanguages(audio)
            let suffix = languages.isEmpty ? "" : " (\(languages.joined(separator: ", ")))"
            parts.append("\(audio.count) audio\(suffix)")
        }
        if !subtitles.isEmpty {
            parts.append("\(subtitles.count) sub\(subtitles.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "no audio or subtitle streams" : parts.joined(separator: " · ")
    }

    /// First-appearance-order, de-duplicated, tagged-only language codes.
    private static func orderedUniqueLanguages(_ streams: [DiscStream]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for stream in streams {
            guard let code = stream.languageCode, !code.isEmpty, seen.insert(code).inserted else { continue }
            result.append(code)
        }
        return result
    }

    /// The Play All refusal's one sentence, e.g. "This looks like a TV
    /// season disc — 8 titles of about 21 minutes that together match the
    /// length of title 12." `episodes` are the indices
    /// `DiscTitleHeuristic.playAllEpisodes` clustered; `index` is the
    /// suspicious long title. Names what was found, not what was rejected.
    static func playAllMessage(index: Int, episodes: [Int], disc: DiscInfo) -> String {
        let episodeTitles = disc.titles.filter { episodes.contains($0.index) }
        let averageSeconds = episodeTitles.isEmpty
            ? 0
            : episodeTitles.reduce(0) { $0 + $1.durationSeconds } / episodeTitles.count
        // Round to the nearest minute for the sentence; the exact seconds
        // are visible per-row in the table below it.
        let averageMinutes = (averageSeconds + 30) / 60
        return "This looks like a TV season disc — \(episodes.count) titles of about "
            + "\(averageMinutes) minutes that together match the length of title \(index)."
    }
}
