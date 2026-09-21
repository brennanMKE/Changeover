import Foundation

/// The shared formatters the plain register needs and nothing else owns, plus
/// the forbidden-terms list that keeps the register honest
/// (`docs/plain-language-ui.md` §1.2, §6.1).
///
/// Pure and `nonisolated`, like `DiscTitleFormatting`: every plain sentence in
/// the app is a value produced by a function a test can call with no disc, no
/// process and no window.
nonisolated enum PlainLanguage {

    // MARK: - Rounding (rule 4: minutes, never seconds)

    /// A spoken, rounded gap: "about 31 minutes", "about a minute",
    /// "about 2 hours 5 minutes". Used where the person is being told how far
    /// off something is, not how long it took.
    ///
    /// Anything under 90 seconds is "about a minute": the precise number of
    /// seconds is exactly the kind of thing the detail register keeps.
    static func minutes(_ seconds: Int) -> String {
        let total = abs(seconds)
        guard total >= 90 else { return "about a minute" }
        let rounded = (total + 30) / 60
        guard rounded >= 60 else { return "about \(rounded) minutes" }
        let hours = rounded / 60
        let remainder = rounded % 60
        let hourPart = "\(hours) hour\(hours == 1 ? "" : "s")"
        guard remainder > 0 else { return "about \(hourPart)" }
        return "about \(hourPart) \(remainder) minute\(remainder == 1 ? "" : "s")"
    }

    /// How long something took: "under a minute", "41 minutes",
    /// "1 h 5 min". The plain sibling of
    /// `JobPresentation.formatElapsed`, which keeps its "41m 12s" shape for
    /// the History window.
    static func elapsed(_ seconds: Int) -> String {
        let total = max(0, seconds)
        guard total >= 60 else { return "under a minute" }
        let minutes = total / 60
        guard minutes >= 60 else { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: - Names, not codes

    /// "spa" → "Spanish". The lookup `TrackSelectionView.languageLabel`
    /// already did, moved here so the audio picker, the disc table and the
    /// plain sentences all use one function and it gains a test. `nil` when
    /// the code is unknown to the system — the caller falls back to whatever
    /// the disc itself printed.
    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)
    }

    /// "a", "a and b", "a, b and c" — the joiner a sentence needs where a
    /// machine-readable list uses commas throughout.
    static func andList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: - The guard (§1.2, §8)

    /// Words a plain string may never contain: tool names, DVD vocabulary,
    /// identifiers and machine detail. Checked case-sensitively — "CSS" is a
    /// copy-protection scheme and "css" is not a word anyone types by
    /// accident — by `violations(in:)`, which `PlainLanguageTests` runs over
    /// every plain producer that can be enumerated without a disc.
    ///
    /// Two documented exemptions, both because the product name *is* the
    /// instruction: `FailureReason.activationExpired` (the person has to open
    /// MakeMKV.app to fix it) and the Settings caption that sends them to
    /// themoviedb.org for a key.
    static let forbiddenTerms: [String] = [
        "HandBrake", "HandBrakeCLI", "TMDB", "MakeMKV", "makemkvcon",
        "ffmpeg", "ffprobe", "libdvdcss", "libdvdread", "menudump", "lsdvd",
        "x265", "Vision", "tmdb-", "exit status", "signal ", "remux", "mux",
        "PGC", "mount", "raw device", "CSS", "chapter marker", "Δ",
    ]

    /// Every forbidden term `text` contains, plus `"title"` when it uses the
    /// DVD sense of the word. The regex is `\btitles?\b`, so "subtitle" and
    /// "subtitles" pass and "title 1" does not.
    static func violations(in text: String) -> [String] {
        var found = forbiddenTerms.filter { text.contains($0) }
        if text.range(of: "\\btitles?\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            found.append("title")
        }
        return found
    }
}
