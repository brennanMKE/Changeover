import Foundation

// The disc-name auto-search: a DVD's volume name is often the movie title
// with the spaces knocked out, e.g. `ARMY_OF_DARKNESS`. Before this, the
// user retyped it by hand every time (`Changeover-problem.png`'s motivating
// screenshot). `derive` turns a volume name into a plausible TMDB search
// term, or `nil` when it clearly isn't one — a short, explainable rule list,
// not a cleverness engine: a wrong guess costs nothing (it only seeds the
// search box, `SearchPrefill` below never lets it overwrite what the user
// typed), so the rules stay conservative rather than clever.
//
// `nonisolated`, file-scope, pure — the convention `SelectionReset`/
// `OpticalDiscClassifier` use for a decision that must be unit-testable with
// no disc, no view, no `MovieSearchViewModel`.
nonisolated enum DiscNameSearchTerm {

    /// Normalized names (separators already collapsed to single spaces) that
    /// carry no title at all — the disc's format, not the movie on it.
    /// Compared case-insensitively, so `NO_NAME` and `DVD_VIDEO` are caught
    /// the same way `DVDVIDEO` (no separator to begin with) is.
    private static let genericNames: Set<String> = [
        "DVD VIDEO", "DVDVIDEO", "DVD", "UNTITLED", "NO NAME", "MOVIE",
    ]

    /// Trailing single-word junk, stripped one word at a time from the end
    /// inward before the generic-name and length checks run, so
    /// `MOVIE_DISC_1` reduces to `MOVIE` and is still rejected rather than
    /// surviving because "MOVIE DISC 1" itself isn't a blocked phrase.
    private static let trailingSingleWordJunk: Set<String> = [
        "D1", "DISC1", "DISC2", "NTSC", "PAL", "WS", "FS", "16X9", "SE",
    ]

    /// Small connector words a plain title-case pass keeps lowercase, unless
    /// they open or close the phrase — the rule `THE_GIRL_IN_THE_SPIDER'S
    /// _WEB` needs to come back as "The Girl in the Spider's Web" rather than
    /// "The Girl In The Spider's Web".
    private static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of",
        "on", "or", "so", "the", "to", "up", "yet", "vs",
    ]

    /// Turns a DVD volume name into a search term, or `nil` when it isn't
    /// worth prefilling.
    ///
    /// - Real names that motivated each rule (`ARMY_OF_DARKNESS`,
    ///   `OPPENHEIMER`, `HORNETS_NEST`, `THE_GIRL_IN_THE_SPIDER'S_WEB`,
    ///   `GROUNDHOG_DAY`, `WEIRD_SCIENCE` — the user's own screenshot and the
    ///   committed disc corpus) all derive sensibly; see
    ///   `DiscNameSearchTermTests`.
    static func derive(volumeName: String) -> String? {
        var words = normalize(volumeName)
        stripTrailingJunk(&words)

        let candidate = words.joined(separator: " ")
        guard isPlausibleTitle(candidate) else { return nil }

        return isAllCaps(candidate) ? titleCased(words) : candidate
    }

    // MARK: - Normalize

    /// Underscores and dots become spaces (`ARMY_OF_DARKNESS`, a real disc,
    /// motivates the underscore case; `.`-separated names are the same idea
    /// with a different disc-authoring tool), runs of whitespace collapse to
    /// one space, and the result is split into words with nothing empty.
    private static func normalize(_ raw: String) -> [String] {
        let replaced = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        return replaced.split(separator: " ").map(String.init)
    }

    // MARK: - Trailing junk

    /// Pops trailing junk tokens one at a time (so `…_DISC_1_WS` loses `WS`
    /// then `DISC 1`), until the last word no longer matches anything.
    private static func stripTrailingJunk(_ words: inout [String]) {
        while let last = words.last?.uppercased() {
            // `DISC_2`/`SIDE_A` (the two motivating examples) both split into
            // two words once underscores become spaces. Generalized to any
            // trailing digit or single letter after `DISC`/`SIDE` — both
            // conventionally label a part of a multi-disc set, never the
            // title — rather than pinning the literal `2`/`A`.
            if words.count >= 2 {
                let marker = words[words.count - 2].uppercased()
                let isDiscOrSideMarker = marker == "DISC" || marker == "SIDE"
                let lastIsDigits = !last.isEmpty && last.allSatisfy(\.isNumber)
                let lastIsSingleLetter = last.count == 1 && last.rangeOfCharacter(from: .letters) != nil
                if isDiscOrSideMarker, lastIsDigits || lastIsSingleLetter {
                    words.removeLast(2)
                    continue
                }
            }
            if trailingSingleWordJunk.contains(last) {
                words.removeLast()
                continue
            }
            // A trailing 4-digit year "if it survives as its own token" —
            // i.e. checked last, after any disc/side/format junk ahead of it
            // has already been stripped.
            if last.count == 4, last.allSatisfy(\.isNumber) {
                words.removeLast()
                continue
            }
            break
        }
    }

    // MARK: - Plausibility

    private static func isPlausibleTitle(_ candidate: String) -> Bool {
        guard candidate.count >= 3 else { return false }
        guard candidate.rangeOfCharacter(from: .letters) != nil else { return false }
        guard !genericNames.contains(candidate.uppercased()) else { return false }
        return true
    }

    // MARK: - Casing

    /// True only when every letter present is uppercase — a name that
    /// already mixes case (or is already lowercase) is left alone rather
    /// than reformatted.
    private static func isAllCaps(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    private static func titleCased(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            let lower = word.lowercased()
            let isEdgeWord = index == 0 || index == words.count - 1
            if !isEdgeWord, minorWords.contains(lower) {
                return lower
            }
            guard let first = word.first else { return word }
            return String(first).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
