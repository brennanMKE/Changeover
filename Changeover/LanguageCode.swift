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
