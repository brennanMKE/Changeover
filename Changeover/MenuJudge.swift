import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Menu intelligence, tier 3 — the model, asked one linguistic question and
/// constrained so its answer is always checkable
/// (`docs/menu-intelligence.md` §4.3).
///
/// **What it may decide: nothing.** The result is a *caption* naming which of
/// the disc's own buttons reads like "play the movie". `DiscTitleHeuristic`,
/// the 45-minute rule, the Play All guard, the TMDB runtime check and the
/// user's Start remain the only things that choose what gets encoded. A wrong
/// answer here is a wrong sentence on a screen the user is already reading.
///
/// Four constraints, each one structural rather than a promise:
///
/// 1. **It is asked at all only when two or more title-jumping buttons
///    survive the lexicon.** One candidate is answered by the structure; zero
///    is answered by silence.
/// 2. **The output schema is the closed set of the disc's own labels, plus
///    "none of these".** Guided generation cannot emit a string that is not
///    in it, and `interpret(pick:question:)` maps the answer back by exact
///    match — a label that is not there is not a failure mode this design
///    can have.
/// 3. **The chosen label must map to a button whose command resolves to a
///    title the scan actually found.** That check is tier 1's, not the
///    model's, and it runs after every answer.
/// 4. **Unavailable, refusal, guardrail, locale, any thrown error and "none
///    of these" all mean the same thing: no answer, no caption, no retry.**
nonisolated enum MenuJudge {

    /// The string the model picks when none of the disc's labels is the play
    /// button. A first-class answer, not a failure.
    static let noneLabel = "none of these"

    /// What the model is asked. Labels of the **candidate buttons only** —
    /// text attached to real buttons whose target is a real title — never
    /// free text off the still.
    nonisolated struct Question: Equatable, Sendable, Codable {
        var labels: [String]
        /// The VMG title each label's button starts, positionally. This is
        /// what makes constraint 3 checkable without going back to the
        /// structure.
        var titles: [Int]
        /// The page heading, for context ("Special Features").
        var menuTitleText: String?

        init(labels: [String], titles: [Int], menuTitleText: String? = nil) {
            self.labels = labels
            self.titles = titles
            self.menuTitleText = menuTitleText
        }

        /// The closed set the schema is built from — the labels, then the
        /// escape hatch, in that order.
        var choices: [String] { labels + [MenuJudge.noneLabel] }

        var prompt: String {
            let list = choices.map { "\"\($0)\"" }.joined(separator: ", ")
            let heading = menuTitleText.map { " The menu is headed \"\($0)\"." } ?? ""
            return "Menu buttons: \(list).\(heading) Which one starts the main feature?"
        }
    }

    nonisolated enum Answer: Equatable, Sendable {
        /// An index into `Question.labels` — never a title index.
        case chose(labelIndex: Int)
        /// The model picked "none of these". An acceptable answer.
        case none
        /// Availability, a refusal, a guardrail, a locale it does not speak,
        /// a thrown error, or a string that was not in the closed set.
        case unavailable(String)
    }

    /// The instructions. Four lines: the task, the closed set, the escape
    /// hatch, and no reasoning to read back.
    static let instructions = """
    You are labelling the buttons of a DVD's main menu.
    Exactly one answer must be chosen from the list you are given.
    Choose the button that starts playing the main feature film itself — not a trailer, not the bonus features, not a scene index, not a language or setup menu.
    If no button in the list starts the main feature, choose "\(noneLabel)".
    """

    // MARK: - When to ask (pure)

    /// The question, or `nil` when the model must not be asked.
    ///
    /// Asked only when **two or more** labelled title-jumping buttons survive
    /// the lexicon: one candidate is the structure's own answer, and an
    /// unlabelled button gives the model nothing to read. Buttons that target
    /// the same title collapse — "Play" and "Play with commentary" differ by
    /// a stream command and the caption would be identical — and a button
    /// pointing at a title the scan never found is dropped before the model
    /// ever sees it.
    static func question(
        candidates: [ResolvedButton],
        labels: [MenuButtonRef: String],
        scanTitles: Set<Int> = [],
        menuTitleText: String? = nil
    ) -> Question? {
        var seenTitles = Set<Int>()
        var chosenLabels: [String] = []
        var chosenTitles: [Int] = []
        for button in candidates {
            guard let title = button.target.titleNumber else { continue }
            guard scanTitles.isEmpty || scanTitles.contains(title) else { continue }
            guard let label = labels[button.ref]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { continue }
            guard seenTitles.insert(title).inserted else { continue }
            guard !chosenLabels.contains(label) else { continue }
            chosenLabels.append(label)
            chosenTitles.append(title)
        }
        // The lexicon answers a disc it knows: exactly one play label among
        // the candidates needs no model at all.
        let lexiconHits = chosenLabels.filter(MenuLexicon.isPlayLabel)
        guard lexiconHits.count != 1 else { return nil }
        guard chosenLabels.count >= 2 else { return nil }
        return Question(labels: chosenLabels, titles: chosenTitles, menuTitleText: menuTitleText)
    }

    // MARK: - Reading the answer (pure)

    /// Maps whatever came back onto the closed set. Anything that is not one
    /// of the exact strings we sent — a paraphrase, a translation, an empty
    /// string, a title index, a sentence — is `.unavailable`, never a guess
    /// at what was meant.
    static func interpret(pick: String, question: Question) -> Answer {
        guard let index = question.choices.firstIndex(of: pick) else {
            return .unavailable("the model answered with a label that was not offered")
        }
        return index == question.labels.count ? .none : .chose(labelIndex: index)
    }

    /// The caption, or `nil`. Tier 1 has the final word: the chosen label has
    /// to name a button whose command resolves to a title the scan found, or
    /// there is nothing to say.
    static func caption(_ answer: Answer, question: Question, scanTitles: Set<Int>) -> String? {
        guard case .chose(let index) = answer else { return nil }
        guard question.labels.indices.contains(index), question.titles.indices.contains(index) else { return nil }
        let title = question.titles[index]
        guard scanTitles.isEmpty || scanTitles.contains(title) else { return nil }
        return "This disc has \(question.labels.count) buttons that start a title; \"\(question.labels[index])\" reads as the feature (title \(title)). The scan still chooses what is encoded."
    }

    // MARK: - Asking it

#if canImport(FoundationModels)
    /// One call, a few tokens, greedy sampling, no retry. Runs off the main
    /// actor and nothing waits for it.
    @available(macOS 26.0, *)
    @concurrent
    static func ask(_ question: Question) async -> Answer {
        guard case .available = SystemLanguageModel.default.availability else {
            return .unavailable("Apple Intelligence is not available on this Mac")
        }
        do {
            let schema = try GenerationSchema(
                root: DynamicGenerationSchema(
                    name: "PlayButton",
                    description: "The DVD menu button that starts playback of the main feature film",
                    anyOf: question.choices
                ),
                dependencies: []
            )
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: question.prompt,
                schema: schema,
                options: GenerationOptions(sampling: .greedy)
            )
            guard let pick = try? response.content.value(String.self) else {
                return .unavailable("the model returned no label")
            }
            return interpret(pick: pick, question: question)
        } catch {
            // A refusal, a guardrail violation, an unsupported locale, a
            // context-window error: all the same outcome as no OCR at all.
            return .unavailable(String(describing: error))
        }
    }
#endif

    /// The production entry point, available whatever the SDK offers. Returns
    /// `.unavailable` rather than failing when Foundation Models is not
    /// there, which is the same outcome every other absence produces.
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
}
