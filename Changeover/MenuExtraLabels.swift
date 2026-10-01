import Foundation

/// #0174 — naming a disc's bonus titles from the labels its own menu printed.
///
/// Signs' bonus menu lists every extra *with its runtime*, and the OCR reads
/// them cleanly:
///
///     looking for Signs (6:11)          scanned title  9 — 6:15
///     building Signs (8:02)                           10 — 8:05
///     making Signs: a commentary (22:33)              11 — 22:37
///     the effects of Signs (8:31)                     12 — 8:36
///     last voices: the music of Signs (8:26)          13 — 8:30
///     full circle (4:48)                              14 — 4:51
///
/// One to one, every pairing inside five seconds, no collisions. The disc has
/// told us what each title is; nothing has to be guessed and no DVD virtual
/// machine has to be emulated to find out.
///
/// **This is why it is a runtime match and not a command walk.** Signs' menu
/// buttons do not name titles: each is a `Set` instruction writing a different
/// value into a register, and one shared post-command links to a dispatcher
/// that reads the register and jumps. `PlayButtonResolver` deliberately
/// refuses to follow that — it would mean evaluating conditionals on registers
/// the app does not model — so on this disc it resolves zero buttons to zero
/// titles. The printed runtimes are the disc's own answer, in plain sight.
///
/// Same shape as `FeatureMatching`, and for the same reason: a runtime is a
/// fact two independent sources agree on, and agreement across sources is far
/// harder to hit by accident than any single reading.
nonisolated enum MenuExtraLabels {

    /// A label the menu printed, with the runtime printed beside it.
    nonisolated struct Printed: Equatable, Sendable {
        /// The text with the runtime removed — what the extra is called.
        var label: String
        var seconds: Int

        init(label: String, seconds: Int) {
            self.label = label
            self.seconds = seconds
        }
    }

    /// One printed label bound to one scanned title.
    nonisolated struct Match: Equatable, Sendable {
        var titleIndex: Int
        var label: String
        /// How far the printed runtime sits from the scanned one.
        var offBySeconds: Int
    }

    /// How far a printed runtime may sit from the scanned title's.
    ///
    /// Twelve seconds. Measured errors on Signs run 3 to 5, all in the same
    /// direction — the menu rounds down and the scan counts the tail — and
    /// twelve leaves room for a disc that rounds to the nearest minute on a
    /// short extra without admitting a neighbouring title. The extras on that
    /// disc are 4 to 22 minutes apart from each other, so the gap between
    /// right and wrong here is enormous.
    static let toleranceSeconds = 12

    /// Reads `looking for Signs (6:11)` into a label and a runtime.
    ///
    /// Only a *trailing* parenthesised time counts. A title with a bracket in
    /// it ("Alien (Director's Cut)") has no digits-and-colon inside, so it is
    /// left whole, and a year in brackets has no colon either.
    static func printed(from line: String) -> Printed? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard let seconds = duration(String(inside)) else { return nil }
        let label = String(text[text.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Printed(label: label, seconds: seconds)
    }

    /// `6:11`, `1:22:33` — and `59m`, `1h 46m`, `22 min`.
    ///
    /// A bare number is still refused: a chapter count, a year or a disc
    /// number far more often than a duration.
    ///
    /// #0183 — the spelled forms were missing and it cost the Signs disc its
    /// bonus feature. Title 8 runs 58:54; the model answered
    /// "Behind-the-scenes film (59m)", which is right, and this returned `nil`
    /// for it, so the claim could not be corroborated and the finding was
    /// dropped. The app had already nominated title 8 from the runtimes alone
    /// and then discarded the name that would have made it importable.
    ///
    /// The model used `59m` because that is the format the prompt showed it:
    /// `DiscEvidence.titleTableForPrompt` renders `- title 8: 59m` while the
    /// instructions ask for `(58:54)`. Shown one shape and parsed for another.
    /// Both ends are fixed — the table now speaks in the shape it asks for —
    /// and this accepts the spelled forms anyway, because a model told one
    /// thing and asked for another will reasonably produce either.
    static func duration(_ text: String) -> Int? {
        if let spelled = spelledDuration(text) { return spelled }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0
        for (position, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            // Minutes and seconds are two digits and under sixty; the leading
            // field is hours (or minutes) and may be anything.
            if position > 0 { guard part.count == 2, value < 60 else { return nil } }
            total = total * 60 + value
        }
        return total
    }

    /// `1h 46m`, `59m`, `22 min`, `1 hr 46 min` — the way a person writes a
    /// runtime, and the way this app itself prints one
    /// (`DiscTitleFormatting.runtime`).
    ///
    /// Requires a unit letter, so `2002` stays a year and `21` stays a
    /// chapter count. Minutes alone are capped at a DVD's reach: nothing on a
    /// disc runs a thousand minutes, and a four-digit number followed by an
    /// `m` is a misread, not a film.
    static func spelledDuration(_ text: String) -> Int? {
        let lowered = text.lowercased()
        guard lowered.contains(where: \.isLetter) else { return nil }

        var hours: Int?
        var minutes: Int?
        var digits = ""
        var index = lowered.startIndex

        while index < lowered.endIndex {
            let character = lowered[index]
            if character.isNumber {
                digits.append(character)
                index = lowered.index(after: index)
                continue
            }
            if character.isWhitespace { index = lowered.index(after: index); continue }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            let rest = lowered[index...]
            if rest.hasPrefix("hr") || rest.hasPrefix("hour") || rest.hasPrefix("h") {
                guard hours == nil, value < 24 else { return nil }
                hours = value
            } else if rest.hasPrefix("min") || rest.hasPrefix("m") {
                guard minutes == nil else { return nil }
                minutes = value
            } else {
                return nil
            }
            digits = ""
            // Skip the rest of the unit word.
            while index < lowered.endIndex, lowered[index].isLetter {
                index = lowered.index(after: index)
            }
        }
        // Trailing digits with no unit are not a duration.
        guard digits.isEmpty else { return nil }
        guard hours != nil || minutes != nil else { return nil }
        if hours == nil, let only = minutes, only >= 1_000 { return nil }
        guard (minutes ?? 0) < 60 || hours == nil else { return nil }
        return (hours ?? 0) * 3600 + (minutes ?? 0) * 60
    }

    /// Every printed label on a menu page, in the order it was printed.
    static func printedLabels(in lines: [String]) -> [Printed] {
        lines.compactMap(printed(from:))
    }

    /// Binds printed labels to scanned titles by runtime, one to one.
    ///
    /// A label is matched to the closest title inside `toleranceSeconds`, and
    /// a title already taken is never taken twice — the same one-to-one rule
    /// `FeatureMatching.assign` applies to films, for the same reason: two
    /// extras are two different videos. A label matching nothing is dropped
    /// rather than forced; naming a title wrongly is worse than not naming it.
    static func match(printed labels: [Printed], to titles: [DiscTitle]) -> [Match] {
        guard !labels.isEmpty, !titles.isEmpty else { return [] }

        // **Globally optimal, not greedy.** Signs is the disc that settles
        // this: "the effects of Signs" is printed at 8:31 (511s) and
        // "last voices" at 8:26 (506s), against scanned titles of 516s and
        // 510s. Taking the tightest pairing first binds 511 to the 510 title
        // — off by one, and the best single pairing available — which then
        // forces 506 onto the 516 title, ten seconds out and the wrong video.
        // Minimising the TOTAL error picks the right answer instead: 23
        // seconds across six extras against the greedy 25.
        //
        // Same rule as `FeatureMatching.assign`, and the same reason it is
        // affordable: a bonus menu lists a handful of items, not hundreds.

        // #0179 — narrow BOTH sides to what could possibly pair, before any
        // searching.
        //
        // The first version capped the raw counts and refused outright above
        // eight. A disc with nine short titles therefore got no labels at all
        // and every extra silently stayed a clip — and most of those titles
        // were never candidates, being nowhere near a printed runtime. Keeping
        // only what is within tolerance of something on the other side shrinks
        // the search to the pairs that were ever possible, and the cap then
        // falls on a genuinely ambiguous disc rather than on an ordinary one.
        let ranked = labels
            .filter { label in titles.contains { abs($0.durationSeconds - label.seconds) <= toleranceSeconds } }
            .sorted { $0.seconds < $1.seconds }
        let sortedTitles = titles
            .filter { title in labels.contains { abs(title.durationSeconds - $0.seconds) <= toleranceSeconds } }
            .sorted { $0.durationSeconds < $1.durationSeconds }
        guard !ranked.isEmpty, !sortedTitles.isEmpty else { return [] }
        guard ranked.count <= maximumLabels, sortedTitles.count <= maximumLabels else { return [] }

        // #0179 — choose a subset on WHICHEVER side is larger.
        //
        // The first version only ever chose a subset of titles, then paired it
        // against `ranked.prefix(count)` — the shortest labels. With six
        // printed labels and one candidate title it tried the shortest label
        // against that title and gave up if it did not fit, never trying the
        // other five. Reported by a review of this function, 2026-09-30.
        let pairs = min(ranked.count, sortedTitles.count)
        let labelSets = combinations(of: ranked, choose: pairs)
        let titleSets = combinations(of: sortedTitles, choose: pairs)

        var best: (error: Int, matches: [Match])?
        for chosenLabels in labelSets {
            for chosenTitles in titleSets {
                for order in permutations(of: Array(chosenTitles.indices)) {
                    var total = 0
                    var matches: [Match] = []
                    var fits = true
                    for (position, label) in chosenLabels.enumerated() {
                        let title = chosenTitles[order[position]]
                        let error = abs(title.durationSeconds - label.seconds)
                        guard error <= toleranceSeconds else { fits = false; break }
                        total += error
                        matches.append(Match(titleIndex: title.index, label: label.label,
                                             offBySeconds: error))
                    }
                    guard fits, matches.count == pairs else { continue }
                    if best == nil || total < best!.error { best = (total, matches) }
                }
            }
        }
        return (best?.matches ?? []).sorted { $0.titleIndex < $1.titleIndex }
    }

    /// The most labels the search will take. Eight, matching
    /// `MultiTitleInference.maximumTitles`: 8! is 40,320 orderings, which is
    /// instant, and a longer bonus menu is better left unnamed than guessed.
    static let maximumLabels = 8

    private static func combinations<T>(of items: [T], choose count: Int) -> [[T]] {
        guard count > 0, items.count >= count else { return [] }
        guard items.count > count else { return [items] }
        var result: [[T]] = []
        var current: [T] = []
        func walk(_ index: Int) {
            if current.count == count { result.append(current); return }
            guard index < items.count,
                  items.count - index >= count - current.count else { return }
            current.append(items[index]); walk(index + 1); current.removeLast()
            walk(index + 1)
        }
        walk(0)
        return result
    }

    private static func permutations(of items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        var result: [[Int]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            for tail in permutations(of: rest) { result.append([item] + tail) }
        }
        return result
    }
}
