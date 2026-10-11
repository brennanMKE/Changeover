import Foundation

/// #0171 — search terms for TMDB built out of a menu's own OCR text.
///
/// The on-device model is the first reader of these lines and it is not always
/// enough. Measured on joe 2026-09-29 against the Get Hard / The Campaign
/// disc, whose menu OCR reads:
///
///     KEVN MART / GET HARD / D°ÇAMPAIGN / PLAY / WITH ENGLISH SUBTITLES / …
///
///     asked as shipped:            GET HARD
///     asked with the count stated: GET HARD, DREAMSCAPE
///     asked again, told one film:  Get Hard, DREAMLAND
///
/// It reads the clean title and cannot repair the damaged one — and pressing
/// it by naming the expected count makes it *invent* a film, which is exactly
/// what `MultiTitleInference` warns about and why the count is kept out of the
/// prompt. A model that answers DREAMSCAPE is not a model to ask harder.
///
/// TMDB, on the other hand, is a fuzzy search over real film titles, and the
/// damage here is at the *front* of the word:
///
///     "D°ÇAMPAIGN"  -> a 1912 newsreel
///     "DCAMPAIGN"   -> nothing
///     "CAMPAIGN"    -> The Campaign (2012)   <- top hit
///
/// So the app tries several readings of each line rather than one. That is
/// only safe because nothing here decides anything: every term still has to
/// come back from TMDB with a runtime that lands within three minutes of one
/// of this disc's own features, one film per feature
/// (`FeatureMatching.bestSplit`). A term that means nothing finds nothing, and
/// a term that finds the wrong film is thrown out by the disc's own clock.
nonisolated enum OCRSearchTerms {

    /// How many characters may be shaved off each end of a line.
    ///
    /// Two. OCR damage on a DVD menu clusters at the edges of a word — a drop
    /// cap, a decorative flourish, the edge of a highlight rectangle — and
    /// `D°Ç` is three characters that collapse to two once the degree sign is
    /// dropped as punctuation. Going further starts matching the middles of
    /// words, which is how a search term stops being a reading of the line
    /// and becomes a fishing expedition.
    static let maximumTrim = 2

    /// A line must keep at least this many letters to be worth searching.
    /// Short strings match far too much.
    static let minimumLength = 4

    /// A bound on the whole pool, so a disc with forty menu pages cannot turn
    /// into hundreds of TMDB calls. Ordered best-first, so the cut falls on
    /// the least plausible readings.
    /// Raised from 12 for #0246.
    ///
    /// The cap exists so a damaged menu does not become hundreds of TMDB
    /// calls, and 18 is still nowhere near that. It had to move because the
    /// ordering did: with every whole line and every join ahead of the
    /// shavings, "CAMPAIGN" — the only term that finds the Get Hard disc's
    /// second film — lands at 16. 18 is that plus headroom, so the next disc
    /// with one more menu line does not silently lose a film.
    static let maximumTerms = 18

    /// Candidate search terms, best first and deduplicated.
    ///
    /// - Parameters:
    ///   - lines: the menu text, as `MultiTitleInference.Question` collects it.
    ///   - known: titles already proposed by a better source (the model).
    ///     They lead the pool and their own lines are not re-derived.
    static func terms(lines: [String], known: [String] = []) -> [String] {
        var pool: [String] = []
        var seen = Set<String>()

        func add(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= minimumLength else { return }
            guard seen.insert(trimmed.lowercased()).inserted else { return }
            pool.append(trimmed)
        }

        for title in known { add(title) }

        // Furniture last, not dropped.
        //
        // `PLAY` and `SUBTITLES` are in the lexicon, but the line the Get Hard
        // disc actually prints is `WITH ENGLISH SUBTITLES`, which matches no
        // entry exactly — so an exact-match filter lets it and every trimmed
        // variant of it into the pool, where they crowd real titles out of
        // `maximumTerms`.
        //
        // Dropping any line that *contains* a menu word would fix that and
        // cost more than it saves: `Child's Play`, `The Player`, `Cast Away`
        // are films. A wasted lookup finds nothing and is thrown out by the
        // runtime check anyway; a discarded title cannot be recovered. So a
        // line carrying menu vocabulary sinks to the back of the pool and the
        // cap falls on it first.
        var furniture: [(String, Bool)] = []
        for line in lines {
            guard !MenuLexicon.isKnownLabel(line) else { continue }
            let cleaned = fold(line)
            guard cleaned.count >= minimumLength else { continue }
            furniture.append((cleaned, looksLikeMenuFurniture(cleaned)))
        }

        let ranked = furniture.sorted(by: { !$0.1 && $1.1 })

        // #0246 — adjacent lines joined, before anything derived from a single
        // line.
        //
        // A menu sets a title across two lines whenever it is too long or the
        // designer liked it that way, and the OCR reports one observation per
        // line. The WILLIS triple feature's menu reads
        //
        //     Jackal | MERCURY | RISING | ALPHA DOG
        //
        // which is three films counted as four, and "MERCURY RISING" was never
        // searched for, because nothing here ever put two lines together. The
        // disc named its own films and the app could not read them.
        //
        // Early, because a join is strong evidence: two real words in order,
        // exactly as the menu set them. Pairs only and adjacent only — longer
        // combinations are a combinatorial pool of mostly nonsense that would
        // eat the cap.
        //
        // Furniture is not joined. "WITH ENGLISH SUBTITLES WITH SPANISH
        // SUBTITLES" is not a film, and a disc with several language lines
        // produces a run of them.
        // #0246 — ordered by how good the evidence is, not by which line it
        // came from.
        //
        // Four tiers, and furniture sinks to the back of every one of them,
        // which is what the note above always meant by "sinks to the back of
        // the pool".
        //
        //   1. whole lines that are not furniture — a real film's name, read
        //      undamaged, is the best thing here
        //   2. adjacent pairs of those lines joined
        //   3. shavings of those lines
        //   4. everything furniture, whole and shaved
        //
        // The old code walked the lines and emitted each one's shavings before
        // moving on. That cost the WILLIS triple feature a film: its menu names
        // three in four lines, and eight of the twelve slots went on shavings
        // of the first two ("ackal", "ckal", "ERCURY", "RCURY"…), so "ALPHA
        // DOG" — a whole line, a real film, sitting right there — never got a
        // slot. A damaged reading of one line must not outrank an undamaged
        // reading of another.
        //
        // The shavings still earn tier 3 rather than being dropped: the Get
        // Hard disc's second film is found only as "CAMPAIGN", a shaving of the
        // damaged line "D\u{00B0}\u{00C7}AMPAIGN". Front first, since a menu prints a title's
        // first letters decoratively more often than its last.
        func shavings(of cleaned: String) -> [String] {
            let characters = Array(cleaned)
            var out: [String] = []
            for drop in 1...maximumTrim where characters.count - drop >= minimumLength {
                out.append(String(characters.dropFirst(drop)))
            }
            for drop in 1...maximumTrim where characters.count - drop >= minimumLength {
                out.append(String(characters.dropLast(drop)))
            }
            return out
        }

        let real = ranked.filter { !$0.1 }.map(\.0)
        let menuWords = ranked.filter { $0.1 }.map(\.0)

        for line in real { add(line) }
        // Pairs only, adjacent only: longer combinations are a combinatorial
        // pool of mostly nonsense. Furniture is not joined at all — "WITH
        // ENGLISH SUBTITLES WITH SPANISH SUBTITLES" is not a film, and a disc
        // with several language lines produces a run of them.
        for pair in zip(real, real.dropFirst()) { add(pair.0 + " " + pair.1) }
        for line in real { for shaved in shavings(of: line) { add(shaved) } }
        for line in menuWords { add(line) }
        for line in menuWords { for shaved in shavings(of: line) { add(shaved) } }

        return Array(pool.prefix(maximumTerms))
    }

    /// Whether any word of a line is menu vocabulary the lexicon knows.
    ///
    /// A weaker test than `MenuLexicon.isKnownLabel`, which wants the whole
    /// caption: this catches `WITH ENGLISH SUBTITLES`, where only the last
    /// word is in the table. It ranks, it never rejects — see above.
    static func looksLikeMenuFurniture(_ line: String) -> Bool {
        line.split(separator: " ").contains { MenuLexicon.isKnownLabel(String($0)) }
    }

    /// One line, reduced to something a search engine can use: accents folded
    /// to their base letters (`Ç` is a cedilla over a `C`, and the menu did
    /// not print one), and everything that is not a letter, a digit or a
    /// space dropped.
    ///
    /// Not lowercased — TMDB does not care, and a term that reads the way the
    /// menu printed it is easier to recognise in a log.
    static func fold(_ line: String) -> String {
        let folded = line.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
        let kept = folded.map { character -> Character in
            if character.isLetter || character.isNumber || character == " " { return character }
            // A punctuation mark becomes a space rather than vanishing, so
            // "GET:HARD" does not become one word.
            return " "
        }
        return String(kept)
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
