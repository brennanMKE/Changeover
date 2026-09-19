import Foundation

/// ISO 639-2 language-code normalization.
///
/// HandBrake's scan JSON reports ISO 639-2/T codes (`"fra"`, not `"fre"`) and
/// writes the literal string `"und"` for an untagged stream
/// (`HandBrakeScanParser`, #0033). A caller-supplied preference list — a
/// `Config`/`AppSettings` default, or something a user typed — may still use
/// the older bibliographic form. `normalize` collapses both to the
/// terminologic code HandBrake itself emits, so a comparison against a
/// `DiscStream.languageCode` never silently fails on `"fre"` vs `"fra"`.
///
/// Introduced by #0029 (its own test set needs the bibliographic mapping for
/// `AudioSelection.languages`) even though #0027's `AudioTrackOptions` was
/// the plan's original home for it — #0029 lands first in the phase's
/// implementation order, and #0027 reuses this rather than redefining it.
nonisolated enum LanguageCode {
    /// Lowercases and trims, then maps a bibliographic (ISO 639-2/B) code to
    /// its terminologic (ISO 639-2/T) equivalent. `nil`, `""`, and `"und"`
    /// (HandBrake's tag for "no language detected") all normalize to `nil` —
    /// never treat "unknown" as a language to filter by.
    nonisolated static func normalize(_ code: String?) -> String? {
        guard let code else { return nil }
        let lowered = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty, lowered != "und" else { return nil }
        return bibliographicToTerminologic[lowered] ?? lowered
    }

    /// The ISO 639-2 code for a language **name** as a disc's own menu prints
    /// it — `"Français"` → `"fra"`, `"ENGLISH 5.1"` → `"eng"`
    /// (`docs/menu-intelligence.md` §7.3, where an upgrade writes the code
    /// into the file while the menu's own word becomes the track title).
    ///
    /// `nil` for anything not in the table, and that is the point: an
    /// unrecognised word is never guessed at, so the upgrade simply does not
    /// offer a language for that track. The table covers the languages DVD
    /// menus in this library actually print; adding a row is how it grows.
    nonisolated static func code(forMenuName name: String) -> String? {
        let cleaned = name
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Menus print "ENGLISH 5.1", "English (Dolby Digital)" and the like:
        // take the leading word run and look that up.
        let head = cleaned.prefix { !$0.isNumber && $0 != "(" && $0 != "-" && $0 != "·" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return menuNameToCode[cleaned] ?? menuNameToCode[head]
    }

    /// Both the endonym a menu prints and the English name, folded to
    /// unaccented lowercase by `code(forMenuName:)` before the lookup — so
    /// `"français"`, `"Francais"` and `"FRENCH"` all land on `fra`.
    private static let menuNameToCode: [String: String] = [
        "english": "eng", "anglais": "eng", "ingles": "eng", "englisch": "eng",
        "francais": "fra", "french": "fra", "frances": "fra",
        "espanol": "spa", "spanish": "spa", "castellano": "spa", "espagnol": "spa",
        "deutsch": "deu", "german": "deu", "allemand": "deu",
        "italiano": "ita", "italian": "ita",
        "portugues": "por", "portuguese": "por",
        "nederlands": "nld", "dutch": "nld",
        "svenska": "swe", "swedish": "swe",
        "dansk": "dan", "danish": "dan",
        "norsk": "nor", "norwegian": "nor",
        "suomi": "fin", "finnish": "fin",
        "polski": "pol", "polish": "pol",
        "russkij": "rus", "russian": "rus", "русский": "rus",
        "日本語": "jpn", "japanese": "jpn", "nihongo": "jpn",
        "한국어": "kor", "korean": "kor",
        "中文": "zho", "chinese": "zho", "mandarin": "zho", "cantonese": "yue",
        "latin american spanish": "spa", "brazilian portuguese": "por",
    ]

    /// The ISO 639-2 languages where the bibliographic (/B) and terminologic
    /// (/T) codes differ — every other code is identical in both sets, so
    /// this table is deliberately short.
    private static let bibliographicToTerminologic: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya",
        "chi": "zho", "cze": "ces", "dut": "nld", "fre": "fra",
        "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
        "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas",
        "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]
}
