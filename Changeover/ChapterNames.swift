import Foundation

/// One `--markers=<file.csv>` row: a chapter number and the name HandBrake
/// should write into the MP4 at the marker it already placed.
///
/// The number is HandBrake's chapter number, never an index into anything
/// here. A row never moves, adds or removes a marker — the timings come from
/// HandBrake's own scan, which is why a wrong *name* is cheap and a wrong
/// *count* is not (`docs/menu-intelligence.md` §3.3).
nonisolated struct MarkerRow: Codable, Equatable, Sendable {
    var number: Int
    var name: String

    init(number: Int, name: String) {
        self.number = number
        self.name = name
    }
}

/// Menu intelligence, tier 2 — the disc's own chapter names, read off its
/// scene-selection pages and attached to chapters by geometry
/// (`docs/menu-intelligence.md` §3.2).
///
/// **Why geometry and not line parsing.** Vision merges a whole row of
/// captions into one observation and wraps a long caption onto a second one.
/// On Bloodsport's four chapter pages that happens three times — chapter 3's
/// "A mentor:" continues as "Tanaka.", 11's "Fight to Survive" as
/// "montage.", 12's "Hong Kong" as "chase." — and a line-by-line regex
/// therefore reads 21 of the 23 names and silently mis-assigns two more. The
/// fix is not a better regex: the *only* thing that says which column a
/// wrapped word belongs to is where it sits on the frame. So every
/// observation is split into fragments at its chapter-number boundaries,
/// each fragment gets an x-span, and an unnumbered observation joins the
/// fragment directly above whose x-span contains its centre.
///
/// **And when that fails, it refuses.** A wrong name is a wrong caption at
/// the right timestamp in Plex. A wrong count is a malformed CSV against
/// markers HandBrake has already placed. `markers(_:chapterCount:)`
/// therefore never emits a number above the chapter count, never emits a
/// duplicate, never emits an empty name, and returns `nil` — bare
/// `--markers`, exactly as today — rather than a partial set.
nonisolated enum ChapterNames {

    /// One chapter's name as read from the menu, before the CSV rules run.
    nonisolated struct Candidate: Codable, Equatable, Sendable {
        /// The chapter this name belongs to. From the button's
        /// `JumpVTS_PTT` when the disc's structure is available, otherwise
        /// from the number printed beside the caption.
        var chapter: Int
        /// The "4" in "4 Training." — `nil` when the menu prints no numbers.
        var printedNumber: Int?
        var name: String
        /// The lowest confidence of the observations that went into `name`.
        var confidence: Float
        /// The printed number disagrees with the button's own chapter
        /// target. The name stays in the archive; the CSV never gets it.
        var disputed: Bool

        init(chapter: Int, printedNumber: Int?, name: String, confidence: Float, disputed: Bool = false) {
            self.chapter = chapter
            self.printedNumber = printedNumber
            self.name = name
            self.confidence = confidence
            self.disputed = disputed
        }
    }

    // MARK: - Fragments

    /// A piece of a still's text with a place on the frame: either a caption
    /// that begins with a chapter number, or a continuation that does not.
    nonisolated struct Fragment: Equatable, Sendable {
        var printedNumber: Int?
        var text: String
        var rect: PixelRect
        var confidence: Float
    }

    /// Split every observation at its chapter-number boundaries and give
    /// each piece an x-span, interpolated across the observation's own
    /// rectangle by character position.
    ///
    /// The interpolation is approximate — proportional spacing means a
    /// fragment boundary is a few pixels out — and it does not need to be
    /// better than that: it decides only *which of three columns* a wrapped
    /// word sits under, and the columns are ~130 px apart. When the disc's
    /// button rectangles are available they replace it entirely
    /// (`candidates(buttons:observations:)`).
    static func fragments(_ observations: [TextObservation]) -> [Fragment] {
        observations.flatMap { fragments(of: $0) }
    }

    static func fragments(of observation: TextObservation) -> [Fragment] {
        let characters = Array(observation.text)
        let starts = numberTokenStarts(characters)
        guard !starts.isEmpty else {
            return [Fragment(
                printedNumber: nil,
                text: observation.text,
                rect: observation.rect,
                confidence: observation.confidence
            )]
        }

        var boundaries = starts
        if boundaries.first != 0 { boundaries.insert(0, at: 0) }
        boundaries.append(characters.count)

        var out: [Fragment] = []
        for index in 0..<(boundaries.count - 1) {
            let lower = boundaries[index]
            let upper = boundaries[index + 1]
            guard upper > lower else { continue }
            let piece = String(characters[lower..<upper])
            let rect = interpolate(observation.rect, from: lower, to: upper, of: characters.count)
            if starts.contains(lower) {
                let (number, rest) = splitLeadingNumber(piece)
                // A page-range button ("1-6", "7-12") splits into a number
                // followed by "-6". It is navigation, not a caption, and it
                // must not come back as a continuation either.
                if rest.trimmingCharacters(in: .whitespaces).hasPrefix("-") { continue }
                out.append(Fragment(
                    printedNumber: number,
                    text: rest,
                    rect: rect,
                    confidence: observation.confidence
                ))
            } else {
                out.append(Fragment(
                    printedNumber: nil,
                    text: piece,
                    rect: rect,
                    confidence: observation.confidence
                ))
            }
        }
        return out
    }

    /// Character offsets where a 1- or 2-digit chapter number begins.
    ///
    /// A run of three or more digits is a year or a film title, never a
    /// chapter ("Rambo 111 (1988)" on Bloodsport's own crew page), and a
    /// digit run that follows a letter is part of a word.
    private static func numberTokenStarts(_ characters: [Character]) -> [Int] {
        var starts: [Int] = []
        var index = 0
        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end].isNumber { end += 1 }
            let length = end - index
            let precededByLetter = index > 0 && characters[index - 1].isLetter
            if length <= 2, !precededByLetter {
                starts.append(index)
            }
            index = end
        }
        return starts
    }

    private static func splitLeadingNumber(_ piece: String) -> (Int?, String) {
        var digits = ""
        var rest = Substring(piece)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        return (Int(digits), String(rest))
    }

    private static func interpolate(_ rect: PixelRect, from lower: Int, to upper: Int, of total: Int) -> PixelRect {
        guard total > 0 else { return rect }
        let width = Double(rect.width)
        let x0 = Double(rect.minX) + width * Double(lower) / Double(total)
        let x1 = Double(rect.minX) + width * Double(upper) / Double(total)
        return PixelRect(minX: Int(x0.rounded()), minY: rect.minY, maxX: Int(x1.rounded()), maxY: rect.maxY)
    }

    // MARK: - Attachment

    /// How far below a caption a wrapped continuation may sit, as a multiple
    /// of its own height. On the measured disc the real continuations are
    /// 0–2 px below their caption and the nearest false positive (the
    /// "Main Menu" button) is 52 px below, so this threshold has ~20 px of
    /// margin at both ends.
    private static let continuationGapFactor = 1.5

    /// Join every unnumbered fragment to the numbered fragment above it
    /// whose x-span contains its centre.
    static func join(_ fragments: [Fragment]) -> [Fragment] {
        let numbered = fragments.filter { $0.printedNumber != nil }
        let loose = fragments.filter { $0.printedNumber == nil }
        guard !numbered.isEmpty else { return [] }

        var joined = numbered
        for continuation in loose.sorted(by: { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }) {
            guard let owner = ownerIndex(for: continuation, in: joined) else { continue }
            joined[owner].text += " " + continuation.text
            joined[owner].confidence = min(joined[owner].confidence, continuation.confidence)
        }
        return joined
    }

    private static func ownerIndex(for continuation: Fragment, in numbered: [Fragment]) -> Int? {
        let centre = continuation.rect.midX
        let height = max(continuation.rect.height, 1)
        let limit = Double(height) * continuationGapFactor

        var best: (index: Int, distance: Double)?
        for (index, candidate) in numbered.enumerated() {
            guard candidate.rect.contains(x: centre) else { continue }
            // Strictly above: a continuation always starts lower on the
            // frame than the caption it continues.
            guard candidate.rect.minY < continuation.rect.minY else { continue }
            let gap = Double(continuation.rect.minY - candidate.rect.maxY)
            guard gap <= limit else { continue }
            // "Nearest above" is measured from the caption's own top, so a
            // caption two rows up never wins over the one directly above.
            let distance = Double(continuation.rect.minY - candidate.rect.minY)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    // MARK: - Candidates

    /// Every chapter page's candidates, in page order.
    ///
    /// **One still at a time is not an implementation detail.** Geometry is
    /// per frame: the four Bloodsport pages put their captions at the same
    /// two y bands, so pooling their observations first would let page 3's
    /// "Chong Li." continue page 1's "A mentor:". Each still is resolved
    /// against its own frame and only the results are merged.
    static func candidates(stills: [[TextObservation]]) -> [Candidate] {
        stills.flatMap { candidates(observations: $0) }
    }

    /// Structure-free, **one still**: the chapter number is the one printed
    /// beside the caption. This is what a capture made before
    /// `Tools/menudump` existed can do, and it is what the Bloodsport
    /// fixture pins.
    ///
    /// `observations` must be one chapter page. Running it over a
    /// cast-and-crew page would read filmography years as chapter numbers —
    /// which the count and range rules in `markers(_:chapterCount:)` would
    /// then throw away, but there is no reason to ask them to.
    static func candidates(observations: [TextObservation]) -> [Candidate] {
        join(fragments(observations)).compactMap { fragment in
            guard let number = fragment.printedNumber else { return nil }
            let name = clean(fragment.text)
            guard !name.isEmpty else { return nil }
            return Candidate(
                chapter: number,
                printedNumber: number,
                name: name,
                confidence: fragment.confidence,
                disputed: false
            )
        }
    }

    /// Structural: the chapter number comes from the button's own
    /// `JumpVTS_PTT` command, and the printed number is only a cross-check.
    ///
    /// A caption belongs to the button whose x-span contains its centre and
    /// whose bottom edge is the nearest one above it — the same rule the
    /// continuations use, one level up. A printed number that disagrees with
    /// the button's chapter marks the candidate `disputed`: the name stays
    /// for the archive, the CSV never sees it.
    static func candidates(buttons: [ResolvedButton], observations: [TextObservation]) -> [Candidate] {
        let chapterButtons: [(chapter: Int, rect: PixelRect)] = buttons.compactMap { button in
            if case .chapter(_, let ptt) = button.target { return (ptt, button.rect) }
            return nil
        }
        guard !chapterButtons.isEmpty else { return candidates(observations: observations) }

        var out: [Candidate] = []
        for fragment in join(fragments(observations)) {
            let name = clean(fragment.text)
            guard !name.isEmpty else { continue }
            guard let owner = chapterButtons
                .filter({ $0.rect.contains(x: fragment.rect.midX) && $0.rect.maxY <= fragment.rect.minY })
                .min(by: { fragment.rect.minY - $0.rect.maxY < fragment.rect.minY - $1.rect.maxY })
            else { continue }
            out.append(Candidate(
                chapter: owner.chapter,
                printedNumber: fragment.printedNumber,
                name: name,
                confidence: fragment.confidence,
                disputed: fragment.printedNumber != nil && fragment.printedNumber != owner.chapter
            ))
        }
        return out
    }

    /// Trim the whitespace and the decorative trailing punctuation a menu
    /// caption carries; keep everything inside the name ("Ray vs. Chong Li",
    /// "A mentor: Tanaka").
    static func clean(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") { value = value.replacingOccurrences(of: "  ", with: " ") }
        let trailing: Set<Character> = [".", ",", "*", "•", "·", ":", ";", "-", "—", " "]
        while let last = value.last, trailing.contains(last) { value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The CSV

    /// The rows for `--markers=<file>`, or `nil` when the set is not
    /// trustworthy (§3.3).
    ///
    /// The rules, in order, and each one is a refusal rather than a repair:
    ///
    /// - a `disputed` candidate is dropped (its printed number disagreed
    ///   with the button's own chapter);
    /// - a number outside `1...chapterCount` is dropped — HandBrake applies
    ///   rows by number to markers it has already placed, so a row it has no
    ///   marker for is the one thing here that can break an encode;
    /// - two candidates for one chapter keep the one with a printed number,
    ///   and if both have one (or neither does) the chapter is left unnamed;
    /// - fewer than half the chapters named returns `nil` — a scene index
    ///   with highlights only gets bare `--markers`, as today.
    static func markers(_ candidates: [Candidate], chapterCount: Int) -> [MarkerRow]? {
        guard chapterCount > 0 else { return nil }

        var byChapter: [Int: Candidate] = [:]
        var contested: Set<Int> = []
        for candidate in candidates {
            guard !candidate.disputed else { continue }
            guard candidate.chapter >= 1, candidate.chapter <= chapterCount else { continue }
            let name = clean(candidate.name)
            guard !name.isEmpty else { continue }
            var normalized = candidate
            normalized.name = name
            guard let existing = byChapter[candidate.chapter] else {
                byChapter[candidate.chapter] = normalized
                continue
            }
            switch (existing.printedNumber != nil, normalized.printedNumber != nil) {
            case (true, false):
                break                                   // keep the numbered one
            case (false, true):
                byChapter[candidate.chapter] = normalized
            default:
                contested.insert(candidate.chapter)     // both, or neither — name nothing
            }
        }
        for chapter in contested { byChapter.removeValue(forKey: chapter) }

        guard byChapter.count * 2 >= chapterCount else { return nil }
        return byChapter
            .sorted { $0.key < $1.key }
            .map { MarkerRow(number: $0.key, name: $0.value.name) }
    }

    /// HandBrake's chapter CSV: `<number>,<name>`, one row per line.
    ///
    /// The first comma is the separator, so a comma inside a name is written
    /// as ` -` — Bloodsport's "Under covers, undercover" becomes "Under
    /// covers - undercover". If the verification encode on joe shows
    /// HandBrake accepts a quoted field, this is where that changes, and
    /// `MarkerRow.name` keeps the real name either way.
    static func csv(_ rows: [MarkerRow]) -> String {
        rows
            .map { "\($0.number),\(csvSafe($0.name))" }
            .joined(separator: "\n") + "\n"
    }

    static func csvSafe(_ name: String) -> String {
        var value = name.replacingOccurrences(of: ",", with: " -")
        value = value.replacingOccurrences(of: "\n", with: " ")
        while value.contains("  ") { value = value.replacingOccurrences(of: "  ", with: " ") }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
