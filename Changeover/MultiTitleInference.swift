import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// #0159 — how many films, and which, when a disc holds more than one.
///
/// `DiscTitleInference` asks for "the film's title and nothing else". That is
/// singular by construction: on a double feature the right answer is not
/// merely hard to reach, it is unreachable, and the model obliges by naming
/// one film and never mentioning the other. Measured on real hardware
/// 2026-09-27 against the Get Hard / The Campaign disc's own OCR:
///
///     asking for one title:      GET HARD
///     asking for several:        Get Hard
///                                Decampagne
///
/// Two films where one was structurally possible. The second answer is still
/// OCR-damaged — the menu prints `DEÇAMPAGNI`, and the model did not repair
/// it — and that is written down here rather than papered over. This type
/// makes the second film *reachable*; it does not make it correct.
///
/// This is a second mode, not a replacement. `DiscTitleInference` and every
/// caller of it are untouched, and a single-feature disc — almost every disc
/// — never comes here. The caller asks `DiscTitleHeuristic.severalFeatures`
/// first; only a disc that structurally holds more than one feature is worth
/// asking about.
///
/// **What it may decide: the words in a search box**, exactly as the
/// single-title path. It names no file, encodes nothing, and selects no
/// movie on its own.
nonisolated enum MultiTitleInference {

    // MARK: - What the model is shown

    /// The same evidence the single-title path uses — menu text plus the
    /// volume label — with one deliberate difference: **repetition is
    /// preserved within a menu page.**
    ///
    /// `DiscTitleInference.question(volumeName:ocr:)` deduplicates every line
    /// across the whole disc, and on the Get Hard / The Campaign entry menu
    /// that is exactly the wrong thing to do. Its single still prints
    ///
    ///     PLAY / WITH ENGLISH SUBTITLES / WITH SPANISH SUBTITLES
    ///     PLAY / WITH ENGLISH SUBTITLES / WITH SPANISH SUBTITLES
    ///
    /// — one block per film, which is the strongest evidence on that disc
    /// that it holds two. A global dedupe collapses it to one block and
    /// destroys the only structural signal, so the instructions below would
    /// be telling the model to look for something the prompt had already
    /// thrown away. Here a line is dropped only when an *earlier still*
    /// already printed it; within a still every line survives, in order.
    nonisolated struct Question: Equatable, Sendable, Codable {
        var volumeName: String
        /// Menu text, in the order it was read. Repeats within one menu page
        /// are kept on purpose (see above).
        var lines: [String]

        init(volumeName: String, lines: [String]) {
            self.volumeName = volumeName
            self.lines = lines
        }

        /// Same bounds as the single-title question, and for the same
        /// reason: a disc with forty menus would otherwise send a few
        /// thousand lines, and a long line is legal text.
        static let maximumLines = 60
        static let maximumLineLength = 80

        var prompt: String {
            let listed = lines.prefix(Self.maximumLines)
                .map { "- \($0)" }
                .joined(separator: "\n")
            return """
            A DVD's disc label is "\(volumeName)".

            This text was read off its menus, in the order it was printed:
            \(listed)

            Which films are on this disc? One title per line.
            """
        }
    }

    /// The structural feature count is **not** in the prompt, on purpose.
    ///
    /// The measured comparison at the top of this file was run without it,
    /// and a count handed to the model is an invitation to pad: told "this
    /// disc has two films", a small model that can only read one has every
    /// incentive to invent a second. The count's job is to *check* the
    /// answer, not to shape it — so it arrives at `reading(from:expecting:)`
    /// after the model has spoken, where a disagreement is information
    /// rather than something the prompt quietly arranged away.
    ///
    /// The evidence the model *is* given — the repeated menu block — is the
    /// disc's own, and it is what a person reads off the same screen.
    static let instructions = """
    You identify the feature films on a DVD from the text printed on its menus.

    A disc may hold more than one film. Double features are sold that way, and
    their menus say so. The entry menu repeats the same block of choices once
    per film — PLAY, WITH ENGLISH SUBTITLES, WITH SPANISH SUBTITLES, and then
    PLAY, WITH ENGLISH SUBTITLES, WITH SPANISH SUBTITLES a second time — and
    some discs print it outright: PLEASE SELECT FEATURE TO VIEW. When the menu
    repeats itself like that, there is a film behind each repeat, and each one
    has a title somewhere on the page.

    Reply with one film title per line, and one line per film. Nothing else: no
    numbering, no bullets, no year, no quotes, no explanation, no heading. If
    the disc holds one film, reply with one line.

    The menu text was read by OCR off a low-resolution DVD menu, so letters are
    dropped, doubled, split and misread, and accents appear where there are
    none. A title can arrive badly misspelled. When a line is plainly a mangled
    film title, reply with the title spelled properly.

    Ignore everything on the menu that is not a film's title: actor names,
    which are printed above the title on most covers; studio, label and caption
    house names; audio formats; region, rating and copyright notices; and menu
    words such as PLAY, SUBTITLES, LANGUAGES, SCENES, SCENE SELECTION, SPECIAL
    FEATURES and SETUP.

    The disc label sometimes carries a film's title, but on a disc holding
    several films it is often a catalogue number — 7000078778_1 is a stock
    number, not a title. Never answer with one.

    If you cannot name any film, reply with exactly NONE.
    """

    // MARK: - What comes back

    /// How many titles a reply may contain before it is a malfunction rather
    /// than an answer.
    ///
    /// `DiscTitleHeuristic.maximumFeaturesPerDisc` is 4, measured over 26
    /// captures: a genuine triple feature exists, eight does not. This cap is
    /// twice that, deliberately — it is not a second opinion on how many
    /// films a disc can hold, it is a stop on a model that has started
    /// listing the menu. Leaving the slack means a real disagreement with the
    /// structural count (two expected, three named) stays visible to the
    /// caller instead of being trimmed into agreement.
    static let maximumTitles = 8

    /// The reply, turned into titles — and nothing else done to it.
    ///
    /// Each line is passed through `DiscTitleInference.sanitize`, which is
    /// where the judgement about what a title looks like already lives:
    /// preambles, quotes, a trailing `(2015)`, `NONE`, letterless strings
    /// (which is what disqualifies a catalogue number such as `7000078778_1`)
    /// and anything sentence-shaped. That function takes the first line of
    /// what it is given, which is a no-op here because it is handed exactly
    /// one line at a time — the splitting is this function's job, not its.
    static func titles(from raw: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripListMarker(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
            guard !line.isEmpty, !isCommentary(line) else { continue }
            guard let title = DiscTitleInference.sanitize(line) else { continue }
            // Case-insensitively, because a model that names the same film
            // twice capitalises it differently the second time as often as not.
            guard seen.insert(title.lowercased()).inserted else { continue }
            found.append(title)
            if found.count == maximumTitles { break }
        }
        return found
    }

    /// `1.`, `2)`, `(3)`, `-`, `*`, `•` — the model was told not to number
    /// its lines and numbers them anyway. Stripped rather than rejected: the
    /// title after the marker is the answer, and refusing the line would
    /// throw away a correct film over punctuation.
    static func stripListMarker(_ line: String) -> String {
        let text = Substring(line)

        // A bullet, or a dash used as one. A leading dash is not a shape any
        // film title uses; a leading dash from a list is ordinary.
        if let first = text.first, "-–—*•·".contains(first) {
            return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // "(3) Title"
        if text.first == "(" {
            let digits = text.dropFirst().prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 2 else { return line }
            let after = text.dropFirst(1 + digits.count)
            guard after.first == ")" else { return line }
            let remainder = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
            return remainder.isEmpty ? line : remainder
        }

        // "1. Title", "2) Title" — at most two digits, then one separator.
        // `1917` is a film whose whole title is a number, so a run of digits
        // with no separator after it is left exactly as it arrived.
        let digits = text.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2 else { return line }
        let after = text.dropFirst(digits.count)
        guard let separator = after.first, ".):".contains(separator) else { return line }
        let remainder = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
        // A bare "1." is not a title with its marker stripped, it is a stray
        // line; hand it back unchanged and let `sanitize` refuse it.
        return remainder.isEmpty ? line : remainder
    }

    /// The two shapes of prose that get past `sanitize` and must not become
    /// titles.
    ///
    /// A heading — "The films on this disc are:" — ends in a colon, which
    /// `sanitize` does not strip and no film title carries at its end.
    ///
    /// A closing remark — "Both are comedies starring Will Ferrell." — ends
    /// in sentence punctuation. A word count comes with it because a model
    /// punctuates a title it is proud of ("Get Hard.") and a few real titles
    /// end in a full stop ("Adaptation."); five words is above every such
    /// title and below every sentence a model has offered here. `sanitize`
    /// already refuses anything over twelve words, so this closes the gap
    /// between two words and twelve.
    static func isCommentary(_ line: String) -> Bool {
        if line.hasSuffix(":") { return true }
        guard let last = line.last, ".!?".contains(last) else { return false }
        return line.split(separator: " ").count >= 5
    }

    /// What the structural count and the model's answer say about each other
    /// — reported, never reconciled.
    ///
    /// The caller knows how many features the disc holds
    /// (`DiscTitleHeuristic.severalFeatures`) and it is tempting to trim the
    /// reply to that number. That would be a lie in both directions: a model
    /// that named one film on a two-film disc has failed and a person must be
    /// asked, and a model that named three on a two-film disc has read
    /// something the structure did not see. Truncating produces a confident
    /// wrong answer in the first case and hides a real disagreement in the
    /// second — the same mistake #0157 fixed in the heuristic, where a single
    /// answer arriving from outside short-circuited the check that would have
    /// caught it.
    nonisolated enum CountAgreement: Equatable, Sendable {
        /// One title per structural feature. Safe to act on.
        case asExpected
        /// Fewer titles than the disc has features: a film is unaccounted
        /// for. Ask a person.
        case fewer(found: Int, expected: Int)
        /// More titles than the disc has features: the model read a menu
        /// word, an actor or a bonus feature as a film. Ask a person.
        case more(found: Int, expected: Int)
        /// No structural count was supplied, so there is nothing to compare.
        /// Not the same as agreement.
        case unknown
    }

    nonisolated struct Reading: Equatable, Sendable {
        /// Every title the reply contained, in the order it named them.
        var titles: [String]
        /// How many features the disc structurally holds, when known.
        var expected: Int?
        var agreement: CountAgreement

        init(titles: [String], expected: Int?) {
            self.titles = titles
            self.expected = expected
            guard let expected else {
                self.agreement = .unknown
                return
            }
            if titles.count == expected {
                self.agreement = .asExpected
            } else if titles.count < expected {
                self.agreement = .fewer(found: titles.count, expected: expected)
            } else {
                self.agreement = .more(found: titles.count, expected: expected)
            }
        }
    }

    /// The reply, parsed, with the structural count held alongside it.
    /// `expecting` is `DiscTitleHeuristic.severalFeatures(disc)?.count`.
    static func reading(from raw: String, expecting expected: Int?) -> Reading {
        Reading(titles: titles(from: raw), expected: expected)
    }

    enum Answer: Equatable, Sendable {
        /// At least one title worth searching for, with the count comparison
        /// attached.
        case titles(Reading)
        /// No answer, and the reason, for the log and the archive.
        case unavailable(String)

        var reading: Reading? {
            if case .titles(let value) = self { return value }
            return nil
        }
    }

    // MARK: - Asking it

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @concurrent
    static func ask(_ question: Question, expecting expected: Int?) async -> Answer {
        guard case .available = SystemLanguageModel.default.availability else {
            return .unavailable("Apple Intelligence is not available on this Mac")
        }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: question.prompt,
                options: GenerationOptions(sampling: .greedy)
            )
            let result = reading(from: response.content, expecting: expected)
            guard !result.titles.isEmpty else {
                return .unavailable("the model named no film")
            }
            return .titles(result)
        } catch {
            return .unavailable(String(describing: error))
        }
    }
#endif

    /// The production entry point, available whatever the SDK offers.
    @concurrent
    static func answer(for question: Question, expecting expected: Int?) async -> Answer {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await ask(question, expecting: expected)
        }
        return .unavailable("this macOS has no on-device model")
#else
        return .unavailable("this build has no Foundation Models framework")
#endif
    }

    // MARK: - Building the question

    /// Every line of menu text the disc printed, in order, with repeats
    /// inside one menu page kept and repeats across pages dropped.
    static func question(volumeName: String, ocr: MenuOCRDocument?) -> Question? {
        guard let ocr else { return nil }
        var seenInEarlierStills = Set<String>()
        var lines: [String] = []
        for still in ocr.stills {
            var fromThisStill: [String] = []
            for observation in still.observations {
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= Question.maximumLineLength else { continue }
                guard text.contains(where: \.isLetter) else { continue }
                guard !seenInEarlierStills.contains(text.lowercased()) else { continue }
                fromThisStill.append(text)
            }
            for text in fromThisStill { seenInEarlierStills.insert(text.lowercased()) }
            lines.append(contentsOf: fromThisStill)
        }
        guard !lines.isEmpty else { return nil }
        return Question(volumeName: volumeName, lines: lines)
    }
}
