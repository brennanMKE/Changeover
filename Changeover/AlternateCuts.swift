import Foundation

/// #0235 — two cuts of one film, offered as two buttons.
///
/// REPO_MEN, 2026-10-07: title 1 runs 1:59:28 with 21 chapters and title 2
/// 1:51:06 with 21 chapters. The disc was classified `multipleFeatures`, Start
/// refused with `noFeatureChosen`, and an agent was asked to name a second film
/// that does not exist. They are the Unrated and Theatrical cuts of one film,
/// and the menu says so in as many words: "PLAY UNRATED VERSION" and "PLAY
/// THEATRICAL VERSION".
///
/// ## Why the runtimes cannot answer this
///
/// They are too close to the real thing to separate. Measured:
///
///     WILLIS       1:48:55 / 1:42:43   ratio 0.943   11 /  9 chapters   TWO films
///     Repo Men     1:59:28 / 1:51:06   ratio 0.930   21 / 21 chapters   ONE film
///     Uncle Buck   1:40    / 1:31      ratio 0.910   17 / 17 chapters   TWO films
///
/// Read that table again, because it is the whole argument. The one disc that
/// IS two cuts sits **between** two discs that are not, and WILLIS — a genuine
/// double feature — has the *closest* runtimes of the three. A ratio threshold
/// would not merely be imprecise here; it would be inverted. Chapters do not
/// rescue it either: Uncle Buck's two films match exactly at 17/17, and #0157's
/// chapter test was removed precisely because it rejected discs whose counts
/// agreed.
///
/// Nothing in the title list can separate these cases, and a rule built on
/// runtimes or chapters would have collapsed WILLIS into one film and lost
/// Mortal Thoughts silently.
///
/// So this does not touch the runtime or chapter rules at all. It asks a
/// different question, of a different source: **does the menu offer these as
/// versions of one thing?** A disc holding two films names two films. A disc
/// holding two cuts names one film twice and distinguishes them with a word
/// like UNRATED or THEATRICAL. That word is the evidence, and nothing else on
/// the disc carries it.
///
/// ## The asymmetry, unchanged
///
/// #0173's rule still governs: a false positive here blocks nothing — it
/// collapses two groups into one film and the disc imports — while a false
/// negative leaves the disc demanding a second film that is not there, which is
/// what REPO_MEN did. But the reverse error matters too: collapsing a real
/// double feature would silently lose the second film. So this fires only on an
/// explicit version word, never on runtimes, and never when the menu offers
/// nothing to read.
nonisolated enum AlternateCuts {

    /// The words that mark one cut of a film rather than a different film.
    ///
    /// Deliberately the *distinguishing* words only. "VERSION" and "CUT" on
    /// their own are too weak — "VERSION FRANÇAISE" is a language, not a cut —
    /// so each entry here is a word that can only qualify an edition.
    ///
    /// Matching is case-insensitive and diacritic-folded, the same convention
    /// `MenuLexicon` uses and for the same reason: OCR drops accents on
    /// stylised type more often than it drops letters.
    ///
    /// `rated` is deliberately absent. It is a real edition word — a disc can
    /// offer "RATED VERSION" beside "UNRATED VERSION" — but it is a substring of
    /// "unrated", and a menu naming only the unrated cut would score two. Word
    /// matching fixes that, and the entry still earns nothing: a disc offering
    /// both always names the unrated one, which is already here.
    static let versionWords: [String] = [
        "unrated",
        "theatrical",
        "directors cut",
        "extended",
        "uncut",
        "special edition",
    ]

    /// Folds a line the way the lexicon does, so comparisons agree, and
    /// reduces everything that is not a letter or digit to a single space.
    ///
    /// The punctuation flattening is what lets a phrase be matched on word
    /// boundaries: "DIRECTOR'S CUT" and "DIRECTORS CUT" both become
    /// "directors cut" only after the apostrophe goes, so one entry covers
    /// whichever form OCR returns.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: nil)
        let flattened = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(flattened).split(separator: " ").joined(separator: " ")
    }

    /// Whether `haystack` contains `needle` as whole words.
    ///
    /// Substring matching is wrong here, and the test that caught it is the
    /// reason this exists: "UNRATED" *contains* "rated", so a menu offering only
    /// the unrated cut counted two version words and would have collapsed a disc
    /// it should not have touched. Padding both sides makes the boundaries
    /// explicit without reaching for a regex.
    static func containsWords(_ haystack: String, _ needle: String) -> Bool {
        (" " + haystack + " ").contains(" " + needle + " ")
    }

    /// Words that make a line an offer of an edition rather than a mention of
    /// one.
    ///
    /// Reading REPO_MEN's real menu is what put this here. "THEATRICAL" appears
    /// on four of its pages, only one of which is the choice: the others are a
    /// DVS notice and a disclaimer. And on half the DVDs ever pressed the
    /// bonus page says **THEATRICAL TRAILER**, which would have collapsed a
    /// genuine double feature the moment its menu also said EXTENDED anywhere.
    ///
    /// A line that offers a cut says which cut *of what*: "PLAY UNRATED
    /// VERSION", "DIRECTOR'S CUT". A trailer is neither, so a version word with
    /// no qualifier beside it is not evidence.
    ///
    /// Confirmed against a real disc rather than invented text: DRAGNET (1987)
    /// has a bonus page reading "THEATRICAL TRAILER", and 714 lines of its menu
    /// are pinned in the corpus with the assertion that none of them counts as
    /// an edition. Its prose carries the other trap too — "one released
    /// theatrically in 1954" — which whole-word matching rejects for the same
    /// reason it rejects "rated" inside "unrated".
    static let qualifiers = ["version", "cut"]

    /// Lines that disqualify themselves whatever else they contain.
    static let disqualifiers = ["trailer"]

    /// Whether this line is offering an edition.
    static func offersAnEdition(_ folded: String) -> Bool {
        guard !disqualifiers.contains(where: { containsWords(folded, $0) }) else { return false }
        return qualifiers.contains { containsWords(folded, $0) }
    }

    /// The distinct version words this menu names **as a choice of edition**.
    ///
    /// Distinct, because the signal is that the menu distinguishes **two**
    /// editions. A single "UNRATED" on a disc holding one cut is a label, not a
    /// choice, and must not collapse anything.
    static func versionWords(inMenu lines: [String]) -> [String] {
        let offers = lines.map(fold).filter(offersAnEdition)
        var found: [String] = []
        for word in versionWords {
            let folded = fold(word)
            if offers.contains(where: { containsWords($0, folded) }), !found.contains(folded) {
                found.append(folded)
            }
        }
        return found
    }

    /// Whether this menu offers alternate cuts of one film.
    ///
    /// Two different version words, so the menu is making a choice between
    /// editions rather than labelling one. "UNRATED" beside "THEATRICAL"
    /// qualifies; "UNRATED" alone does not, and neither does a menu that was
    /// never read.
    static func namesAlternateCuts(menuLines: [String]) -> Bool {
        versionWords(inMenu: menuLines).count >= 2
    }

    /// Whether these runtime groups are plausibly cuts of one film.
    ///
    /// A weak check on purpose: the menu is the evidence and this only stops
    /// the menu's wording being applied to something it cannot be describing —
    /// a disc whose two candidates are 90 minutes apart is not two cuts
    /// whatever its buttons say. Two cuts of a film differ by minutes of
    /// footage, not by half the picture.
    static let minimumCutRatio = 0.75

    static func plausiblyCuts(_ groups: [[DiscTitle]]) -> Bool {
        let lengths = groups.compactMap { $0.map(\.durationSeconds).max() }
        guard let longest = lengths.max(), let shortest = lengths.min(), longest > 0
        else { return false }
        return Double(shortest) / Double(longest) >= minimumCutRatio
    }
}
