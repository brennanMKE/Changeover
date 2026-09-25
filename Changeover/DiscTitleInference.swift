import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which film is this, given everything the disc printed on its menus.
///
/// The rules got a long way and then stopped. `DiscNameSearchTerm` reads word
/// boundaries out of a volume label and cannot invent them
/// (`ENEMYATTHEGATES`). `MenuTitleGuess` finds the tallest unattached text on
/// an entry menu and is helpless when every entry menu is a colour-bar leader
/// — as Enemy at the Gates' are — so it offered "CAPTIONS, INC. LOS ANGELES".
/// Each fix was another list: caption houses to ignore, "INSIDE " to strip.
/// That is a losing game, because the next disc has a different trick.
///
/// A person handed the same text — `SCENE SELECTION`, `THE WOLF HUNTER`,
/// `INSIDE ENEMY AT THE GATES`, `ENGLISH 5.1 SURROUND` — reads the film off it
/// immediately. That is the job, and it is a language job.
///
/// **What it may decide: the words in a search box.** It never picks a title
/// to encode, never names a file, and never selects a movie on its own. The
/// term it produces is searched; if TMDB knows no such film, nothing changes
/// and the user types as they do today. That is the whole risk.
nonisolated enum DiscTitleInference {

    /// What the model is shown. Only text the disc itself printed, plus the
    /// volume label — no runtime, no chapter count, nothing derived, so a
    /// wrong answer can always be traced to what was on screen.
    nonisolated struct Question: Equatable, Sendable, Codable {
        var volumeName: String
        /// Menu text, in the order it was read, deduplicated.
        var lines: [String]

        init(volumeName: String, lines: [String]) {
            self.volumeName = volumeName
            self.lines = lines
        }

        /// Bounded on purpose: a disc with forty menus would otherwise send a
        /// few thousand lines, and the answer is always on the first handful
        /// of pages. Long lines are legal text (copyright blocks) and are the
        /// first thing worth dropping.
        static let maximumLines = 60
        static let maximumLineLength = 80

        var prompt: String {
            let listed = lines.prefix(Self.maximumLines)
                .map { "- \($0)" }
                .joined(separator: "\n")
            return """
            A DVD's disc label is "\(volumeName)".

            This text was read off its menus:
            \(listed)

            What film is on this disc?
            """
        }
    }

    enum Answer: Equatable, Sendable {
        /// A title worth searching for.
        case title(String)
        /// No answer, and the reason, for the log and the archive.
        case unavailable(String)

        var title: String? {
            if case .title(let value) = self { return value }
            return nil
        }
    }

    /// The label leads. The previous wording opened with "the menus rarely
    /// print the title plainly", and on `THESECRETLIFEOFWALTERMITTY` — a
    /// label that *is* the title with the spaces knocked out — the model
    /// took that as licence to ignore it, read the menu noise instead and
    /// answered "The Caretaker". TMDB had a 2026 film of that name with the
    /// same 114-minute runtime, so auto-select took it.
    ///
    /// The corpus says the label is right far more often than not: on 23
    /// archived discs the label carries the film's title 18 times and names
    /// something else only 5 (`WILLIS` twice — the actor, on two different
    /// box-set discs — plus `BLUSBRO`, `DVD_VIDEO` and `DIE_HARD_3`, whose
    /// label is the popular name rather than the TMDB one). The menus print
    /// the title on only 11 of the 23.
    static let instructions = """
    You identify films from a DVD.

    Reply with the film's title and nothing else — no year, no quotes, no
    explanation, no "The film is".

    Start with the disc label. It is usually the film's own title with the
    spaces removed or replaced by underscores — THESECRETLIFEOFWALTERMITTY is
    The Secret Life of Walter Mitty, ENEMYATTHEGATES is Enemy at the Gates,
    THE_BREAKFAST_CLUB is The Breakfast Club. When the label reads as a title,
    answer with that title, spaced and capitalised properly, and do not let
    the menu text talk you out of it.

    Use the menus only when the label is not a title: when it names the disc's
    format (DVD_VIDEO, NO_NAME), an actor or a box set (WILLIS), or is an
    abbreviation with no words in it (BLUSBRO). Then the film is whichever
    film the menus name — sometimes printed plainly, sometimes only implied by
    a bonus feature ("Inside Enemy at the Gates" means the film is Enemy at
    the Gates).

    Ignore text about the disc rather than the film: caption houses, audio
    formats, region warnings, copyright notices, menu words like PLAY, SCENE
    SELECTION and SPECIAL FEATURES.

    If you cannot tell what the film is, reply with exactly NONE.
    """

    // MARK: - What comes back

    /// Everything a small model does to a one-line answer, undone.
    ///
    /// Quotes, a trailing year, a "The film is " preamble, `NONE` in its
    /// several spellings, and the occasional paragraph. A result that is not
    /// a plausible title is refused rather than searched.
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // A model that explains itself gives the title on the first line.
        if let firstLine = text.split(separator: "\n").first {
            text = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for preamble in ["the film is ", "the movie is ", "this is ", "title: ", "film: "] {
            if text.lowercased().hasPrefix(preamble) {
                text = String(text.dropFirst(preamble.count))
            }
        }

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’ ."))

        // "Enemy at the Gates (2001)" — the year is TMDB's job, not the
        // search box's, and it turns an exact title match into a miss.
        if let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let inner = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if inner.count == 4, inner.allSatisfy(\.isNumber) {
                text = String(text[text.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard !text.isEmpty else { return nil }
        guard text.lowercased() != "none" else { return nil }
        guard text.count <= 80 else { return nil }
        guard text.contains(where: \.isLetter) else { return nil }
        // A sentence is an explanation that slipped through, not a title.
        guard text.split(separator: " ").count <= 12 else { return nil }
        return text
    }

    // MARK: - The label rung

    /// Letters and digits only, lowercased — the one comparison that can see
    /// past a disc author's spacing.
    ///
    /// `THESECRETLIFEOFWALTERMITTY`, `The Secret Life of Walter Mitty` and
    /// `the.secret.life.of.walter.mitty` all condense to the same string,
    /// which is the whole point: the label's word boundaries are missing, not
    /// its letters, so a comparison that ignores boundaries can still tell
    /// the label and a proposed title apart.
    static func condensed(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// Condensed labels that name the disc's *format*, not its film. The
    /// menus are the only evidence on these, so nothing about the label may
    /// be used to judge an answer.
    ///
    /// Deliberately small and literal. It cannot be extended to cover the
    /// hard cases — `WILLIS` and `BLUSBRO` are just as uninformative but look
    /// exactly like titles — so the length rule below, not this set, is what
    /// keeps those discs working.
    static let uninformativeLabels: Set<String> = [
        "dvdvideo", "dvd", "dvdrom", "video", "videodvd", "noname", "nodisc",
        "untitled", "unnamed", "movie", "film", "disc", "disc1", "disc2",
        "default", "newvolume", "volume",
    ]

    /// The first rung: the volume label as a search term, or `nil` when the
    /// label is not one.
    ///
    /// Thin on purpose — `DiscNameSearchTerm.derive` already strips
    /// `_DISC_1`, `NTSC`, a trailing year and the generic names; this adds
    /// the wider uninformative-label set and the one case `derive` refuses
    /// on principle, so there is one place that answers "is the label worth
    /// searching?".
    static func labelAsSearchTerm(_ volumeName: String) -> String? {
        if let derived = DiscNameSearchTerm.derive(volumeName: volumeName) {
            guard !uninformativeLabels.contains(condensed(derived)) else { return nil }
            return derived
        }
        return yearTitle(volumeName)
    }

    /// A label that is nothing but a year, when that year is the film's
    /// whole title.
    ///
    /// `DiscNameSearchTerm.derive` refuses every letterless name, and is
    /// right to: `1234` is a serial number, and it pins that. But the
    /// archived disc `1917` is a film whose title is a bare year, and the
    /// label is the only place it appears — its menus name Sam Mendes and
    /// Roger Deakins and never the film. So this rung, and only this rung,
    /// accepts a single four-digit token inside the narrow range these
    /// titles actually occupy — `1900`, `1917`, `1941`, `1984`, `2012`,
    /// `2046` are all films; nothing below 1800 is. `1234` still gets
    /// nothing, and `DiscNameSearchTermTests` still pins that it never
    /// reaches the search box either.
    private static func yearTitle(_ volumeName: String) -> String? {
        let token = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 4, token.allSatisfy(\.isNumber), let year = Int(token) else { return nil }
        guard (1800...2100).contains(year) else { return nil }
        return token
    }

    // MARK: - Checking the answer against the label

    /// How many condensed characters a label needs before it is allowed to
    /// veto the model.
    ///
    /// Measured, not guessed. Over the 23 archived discs
    /// (`Fixtures/naming/corpus.json`) the labels whose correct film does
    /// *not* fit them are `WILLIS` (6 — the actor, not a title, on two
    /// different box-set discs), `BLUSBRO` (7) and `DIE_HARD_3_DISC1`
    /// (`diehard3`, 8 — the popular name, where TMDB's is "Die Hard: With a
    /// Vengeance"). So 9 is the lowest value with no false rejection
    /// anywhere in the corpus, and `DiscNamingCorpusTests` pins that.
    ///
    /// The shipped value is 12, three characters of margin above the
    /// measured floor, because the floor's nearest miss is one character
    /// away and the veto buys nothing below it: a label of 9–11 characters
    /// that really is the title (`LIMITLESS`, `THE_BIG_SHORT`) already
    /// resolves on the label rung, so the model's answer is never needed
    /// there. Every label the fix exists for is far above 12 —
    /// `THESECRETLIFEOFWALTERMITTY` is 26, `ENEMYATTHEGATES` 15.
    static let labelVetoMinimumLength = 12

    /// Is this label long and specific enough to judge an answer by?
    static func labelCanJudgeAnswer(_ volumeName: String) -> Bool {
        guard let term = labelAsSearchTerm(volumeName) else { return false }
        return condensed(term).count >= labelVetoMinimumLength
    }

    /// What the disc label has to say about a proposed title.
    ///
    /// #0072. `answerFitsLabel` collapses two different answers into `true`:
    /// "the label agrees" and "the label has no standing to judge". That is
    /// correct for a *veto* — neither is grounds to reject — but wrong for
    /// deciding whether to act on the answer without asking anyone.
    ///
    /// `USUALLB`, 2026-09-25: the model answered "THE USUAL SUSPECTS" and the
    /// app auto-selected it as label-backed. The label is seven characters
    /// and cannot spell anything; it backed nothing. The answer was right,
    /// and the reasoning was the same shape as the one that produced "The
    /// Caretaker" — the model said so and nothing else was consulted.
    nonisolated enum LabelVerdict: Equatable, Sendable {
        /// The label spells this title. Real corroboration.
        case agrees
        /// The label spells a different title. Reject the answer.
        case disagrees
        /// Too short, absent, or a format name like `DVD_VIDEO`. No opinion —
        /// which is not the same as approval.
        case cannotJudge
    }

    static func labelVerdict(on answer: String, volumeName: String) -> LabelVerdict {
        guard labelCanJudgeAnswer(volumeName),
              let term = labelAsSearchTerm(volumeName) else { return .cannotJudge }
        let label = condensed(term)
        let proposed = condensed(answer)
        guard !proposed.isEmpty else { return .disagrees }
        return label.contains(proposed) || proposed.contains(label) ? .agrees : .disagrees
    }

    /// Does a proposed title agree with the disc label?
    ///
    /// `true` means "no objection" — which includes every case where the
    /// label has no standing to object. A short label, an absent one, or one
    /// of the format names is not evidence against anything, and treating it
    /// as evidence is the failure that matters: `answerFitsLabel("The Whole
    /// Nine Yards", volumeName: "WILLIS")` must be `true`, because that disc
    /// is a Bruce Willis box-set disc whose menus — not its label — name the
    /// film, and it is filed correctly in the library today.
    ///
    /// The agreement test is containment in *either* direction, because real
    /// labels sit on both sides of their title: `SECRET_OF_MY_SUCCESS` drops
    /// the leading "The" (label inside title) while
    /// `LIVEFREE_OR_DIEHARD_BRANCH` carries an authoring suffix (title
    /// inside label). A one-directional test breaks one group or the other.
    static func answerFitsLabel(_ answer: String, volumeName: String) -> Bool {
        labelVerdict(on: answer, volumeName: volumeName) != .disagrees
    }

    // MARK: - Asking it

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @concurrent
    static func ask(_ question: Question) async -> Answer {
        guard case .available = SystemLanguageModel.default.availability else {
            return .unavailable("Apple Intelligence is not available on this Mac")
        }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: question.prompt,
                options: GenerationOptions(sampling: .greedy)
            )
            guard let title = sanitize(response.content) else {
                return .unavailable("the model named no film")
            }
            return .title(title)
        } catch {
            return .unavailable(String(describing: error))
        }
    }
#endif

    /// The production entry point, available whatever the SDK offers.
    @concurrent
    static func answer(for question: Question) async -> Answer {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await ask(question)
        }
        return .unavailable("this macOS has no on-device model")
#else
        return .unavailable("this build has no Foundation Models framework")
#endif
    }

    // MARK: - Building the question

    /// Every line of menu text the disc printed, cleaned and deduplicated.
    ///
    /// Order matters a little — entry menus first, so the most likely place
    /// for a title card leads — but the model is not told which page each
    /// line came from, because that is structure it should not have to reason
    /// about.
    static func question(volumeName: String, ocr: MenuOCRDocument?) -> Question? {
        guard let ocr else { return nil }
        var seen = Set<String>()
        var lines: [String] = []
        for still in ocr.stills {
            for observation in still.observations {
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= Question.maximumLineLength else { continue }
                guard text.contains(where: \.isLetter) else { continue }
                let key = text.lowercased()
                guard seen.insert(key).inserted else { continue }
                lines.append(text)
            }
        }
        guard !lines.isEmpty else { return nil }
        return Question(volumeName: volumeName, lines: lines)
    }
}
