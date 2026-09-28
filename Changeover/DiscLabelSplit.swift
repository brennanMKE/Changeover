import Foundation

/// #0158 — a volume label that names more than one film, cut back into the
/// separate titles it concatenated.
///
/// #0157 taught the app to recognise a disc holding several features
/// (`DiscTitleHeuristic.severalFeatures`). The search box did not follow.
/// `UNCLE_BUCK_GREAT_OUTDOORS`, captured from the real disc on 2026-09-27,
/// derives as the single term "Uncle Buck Great Outdoors" — a film that does
/// not exist, so TMDB returns **0 results** and the user is left staring at
/// an empty list with no hint of what went wrong. The disc actually holds two
/// John Candy films, 90m25s and 99m38s, both already in the user's library
/// under different TMDB ids (2616 and 2617).
///
/// This type only *proposes*: every way of cutting the label into exactly
/// `count` terms at separator boundaries. Choosing between the proposals —
/// asking TMDB, scoring the answers against the discs' runtimes — belongs to
/// the caller and needs the network; that is why it is not here. A proposal
/// costs nothing if it is wrong, which is the same standing
/// `DiscNameSearchTerm.derive` has, and for the same reason: the result only
/// ever seeds a search the user can overrule.
///
/// The judgement of what is a usable term is **not** re-made here. Each part
/// is handed to `DiscNameSearchTerm.derive`, so the trailing-junk rules, the
/// generic-name list, the plausibility floor and the title-casing are shared,
/// and a split is proposed only when every one of its parts survives that
/// same rule list. `7000078778_1` — the Get Hard / The Campaign disc's real
/// volume label, a catalogue number — proposes nothing, because neither half
/// contains a letter and `derive` already says so.
///
/// `nonisolated`, file-scope, pure: the convention `DiscNameSearchTerm`,
/// `SelectionReset` and `DiscTitleHeuristic` use for a decision that must be
/// unit-testable with no disc, no view, no network.
nonisolated enum DiscLabelSplit {

    /// Every way of cutting `volumeName` into exactly `count` candidate
    /// search terms, in a stable order.
    ///
    /// Empty when the label cannot carry `count` titles: fewer
    /// separator-delimited words than parts asked for, `count` below two, or
    /// no arrangement whose every part is a term `DiscNameSearchTerm` would
    /// accept on its own.
    ///
    /// Order is the cut positions ascending — `["Uncle", "Buck Great
    /// Outdoors"]` before `["Uncle Buck", "Great Outdoors"]` before
    /// `["Uncle Buck Great", "Outdoors"]` — so a caller that scores the
    /// proposals gets the same list in the same order on every run. No
    /// ranking is implied by it; scoring is the caller's job.
    static func candidateSplits(volumeName: String, count: Int) -> [[String]] {
        // One part is not a split; it is `DiscNameSearchTerm.derive`, which
        // already exists and is what the caller should use instead.
        guard count >= 2 else { return [] }

        let words = separatorDelimitedWords(volumeName)
        // Every part needs at least one word of its own: never mid-word.
        guard words.count >= count else { return [] }

        var splits: [[String]] = []
        var seen: Set<[String]> = []
        for cuts in cutPositions(wordCount: words.count, parts: count) {
            guard let terms = terms(words: words, cuts: cuts) else { continue }
            // Two different cut sets can land on the same terms once
            // `derive` has stripped trailing junk from the parts, and a
            // caller scoring the list must not pay for the same proposal
            // twice. First occurrence wins, so the order above survives.
            if seen.insert(terms).inserted {
                splits.append(terms)
            }
        }
        return splits
    }

    // MARK: - Words

    /// The characters a DVD authoring tool uses between words. Underscore is
    /// overwhelmingly the common one (`UNCLE_BUCK_GREAT_OUTDOORS`); spaces,
    /// hyphens and dots are the same idea from a different tool, and
    /// `DiscNameSearchTerm.normalize` already treats underscore and dot as
    /// word breaks. Runs collapse because empty pieces are dropped, so
    /// `UNCLE__BUCK   GREAT-OUTDOORS` yields the same four words.
    private static let separators = CharacterSet(charactersIn: "_-.")
        .union(.whitespacesAndNewlines)

    /// The label's words, and the only places a cut may fall. Splitting at a
    /// boundary — never inside a word — is what keeps this from inventing
    /// titles: every proposed term is made of whole words the label actually
    /// contains, in the order it contains them.
    private static func separatorDelimitedWords(_ raw: String) -> [String] {
        raw.unicodeScalars
            .split(whereSeparator: separators.contains)
            .map { String(String.UnicodeScalarView($0)) }
    }

    // MARK: - Cuts

    /// The sets of `parts - 1` cut positions, ascending, that divide
    /// `wordCount` words into `parts` non-empty runs — `C(wordCount - 1,
    /// parts - 1)` of them.
    ///
    /// That count stays small at the sizes real labels reach: the four words
    /// of `UNCLE_BUCK_GREAT_OUTDOORS` give 3 proposals at `count` 2, and an
    /// eight-word label — longer than anything in the 26-capture corpus —
    /// gives 7 at `count` 2 and 21 at `count` 3. There is nothing to prune,
    /// so nothing here prunes.
    private static func cutPositions(wordCount: Int, parts: Int) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []

        func choose(from start: Int, remaining: Int) {
            guard remaining > 0 else {
                result.append(current)
                return
            }
            // Leave one word for each part still to be closed after this one.
            let last = wordCount - remaining
            guard start <= last else { return }
            for cut in start...last {
                current.append(cut)
                choose(from: cut + 1, remaining: remaining - 1)
                current.removeLast()
            }
        }

        choose(from: 1, remaining: parts - 1)
        return result
    }

    /// The parts these cuts make, each put through
    /// `DiscNameSearchTerm.derive`. `nil` — the whole split is dropped — as
    /// soon as one part is not a term worth searching for, because a split is
    /// only useful if *every* film it names can be looked up. A label whose
    /// halves are a catalogue number and a disc index proposes nothing at
    /// all, which is the correct answer for `7000078778_1`.
    private static func terms(words: [String], cuts: [Int]) -> [String]? {
        var terms: [String] = []
        var start = 0
        for boundary in cuts + [words.count] {
            let part = words[start..<boundary].joined(separator: " ")
            guard let term = DiscNameSearchTerm.derive(volumeName: part) else { return nil }
            terms.append(term)
            start = boundary
        }
        return terms
    }
}
