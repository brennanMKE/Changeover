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

    static let instructions = """
    You identify films from the text printed on a DVD's menus.

    Reply with the film's title and nothing else — no year, no quotes, no
    explanation, no "The film is". The menus rarely print the title plainly:
    it is more often implied by a bonus feature ("Inside Enemy at the Gates"
    means the film is Enemy at the Gates), by scene names, or by cast names.

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
