import Foundation

/// #0175 — asking the disc a sequence of questions instead of one.
///
/// The app asked the on-device model exactly one thing: "which films are on
/// this disc?". That is a single shot at a disc that has a great deal more to
/// say, and it is the wrong shape for what people actually own. A DVD bought
/// for its film usually carries a making-of, a commentary reel, deleted
/// scenes, sometimes an entire second feature — and a Plex library built by
/// ripping the main title leaves all of it on the shelf.
///
/// So: several focused questions over one `DiscEvidence`, each cheap, each
/// answerable on its own, and — the part that matters — **each verified
/// against the disc before it counts.**
///
/// ## The model never decides anything
///
/// Every question here returns a *claim*. A claim becomes a finding only when
/// the disc's own facts corroborate it, and the corroboration is always a
/// runtime: the model says "the making-of runs 22:33", the scan says title 11
/// runs 22:37, and those agreeing to four seconds is not a coincidence a
/// hallucination can produce. Measured on this very disc, pressing the model
/// without that check produced DREAMSCAPE and DREAMLAND — confident, fluent
/// and entirely invented. The check is the whole safety story, and it is why
/// more questions can be asked without more risk.
///
/// Anything claimed and not corroborated is kept, marked, and shown to the
/// user as *unverified* rather than acted on or silently dropped. A disc that
/// says something the app cannot confirm is still telling us something.
nonisolated enum DiscInterrogation {

    // MARK: - What is asked

    nonisolated enum Question: String, CaseIterable, Equatable, Sendable, Codable {
        /// Does this disc hold more than one film, and what are they called?
        case films
        /// Is there a long title that is bonus material rather than a film —
        /// a making-of, a concert, a documentary — and what is it called?
        case bonusFeature
        /// What is each of the shorter titles, by the names the menus print?
        case extras

        /// Asked in this order, because each answer narrows the next: the
        /// films are identified first so the bonus question is not offered a
        /// film to mislabel, and the extras last so neither is offered to
        /// them.
        static var inOrder: [Question] { [.films, .bonusFeature, .extras] }
    }

    // MARK: - What comes back

    /// Something the model said, before the disc has been consulted.
    nonisolated struct Claim: Equatable, Sendable {
        var question: Question
        /// What it is called.
        var label: String
        /// The runtime it claimed, when it offered one. The corroboration.
        var seconds: Int?

        init(question: Question, label: String, seconds: Int? = nil) {
            self.question = question
            self.label = label
            self.seconds = seconds
        }
    }

    /// A claim the disc corroborated.
    nonisolated struct Finding: Equatable, Sendable {
        var question: Question
        var titleIndex: Int
        var label: String
        /// How far the claimed runtime sat from the scanned one, in seconds.
        /// `nil` when the finding was bound by something other than a runtime
        /// (the app's own classification, say).
        var offBySeconds: Int?

        init(question: Question, titleIndex: Int, label: String, offBySeconds: Int? = nil) {
            self.question = question
            self.titleIndex = titleIndex
            self.label = label
            self.offBySeconds = offBySeconds
        }
    }

    /// Everything the disc was able to say about itself.
    nonisolated struct Understanding: Equatable, Sendable {
        /// Films, bound to the titles that carry them.
        var films: [Finding] = []
        /// Bonus features — long, not films, worth importing beside the film.
        var bonusFeatures: [Finding] = []
        /// Named short titles.
        var extras: [Finding] = []
        /// Claims the disc could not corroborate. Kept because a disc saying
        /// something unconfirmable is still evidence, and because silently
        /// dropping it is how the app spent four days looking like it had
        /// read nothing.
        var unverified: [Claim] = []

        var allFindings: [Finding] { films + bonusFeatures + extras }

        /// Titles this pass accounted for, so a later rung does not re-offer
        /// one that already has a name.
        var claimedTitles: Set<Int> { Set(allFindings.map(\.titleIndex)) }

        var isEmpty: Bool { allFindings.isEmpty && unverified.isEmpty }
    }

    // MARK: - The prompts

    /// Shared framing. Every question gets this plus its own instruction, so
    /// the model is told once what it is looking at and never has to infer it
    /// from the question.
    static let framing = """
    You are reading the menus of a DVD to work out what is on it.

    The text comes from OCR of low-resolution menu screens, so letters are
    dropped, doubled, split and misread, and accents appear where there are
    none. When a line is plainly a mangled title, give it spelled properly.

    Menu words are not content: PLAY, PLAY ALL, SUBTITLES, LANGUAGES, SCENES,
    SCENE SELECTION, SET UP, SETUP, MAIN MENU, SPECIAL FEATURES, BONUS. Actor
    names, studio names and copyright notices are not content either.

    Answer with the lines asked for and nothing else: no numbering, no
    preamble, no explanation, no heading. If you cannot answer, reply with
    exactly NONE.
    """

    static func instructions(for question: Question) -> String {
        switch question {
        case .films:
            return framing + "\n\n" + """
            Name the FEATURE FILMS on this disc, one title per line.

            Most discs hold one. Some are double features sold together, and
            their menus say so — the entry menu repeats the same block of
            choices once per film, or prints PLEASE SELECT FEATURE TO VIEW.
            A documentary about the film, a making-of, a concert or a
            commentary reel is NOT a feature film, however long it runs.

            The disc label is sometimes a film's title and sometimes a stock
            number. Never answer with a stock number.
            """
        case .bonusFeature:
            return framing + "\n\n" + """
            This disc holds one or more long pieces of BONUS material: a
            making-of documentary, a behind-the-scenes film, a concert, a
            retrospective. They are not the feature film and not a second
            feature film.

            Name each one, one per line, and put its running time in brackets
            after it if the menu printed one, in this shape:

                <the name the menu prints> (58:54)

            Give only pieces that run longer than about forty minutes. Shorter
            ones are asked about separately.

            Use the names the menu prints, corrected for OCR damage. Do not
            invent a piece the menu does not name, and never answer with the
            example above — it shows the shape of a line, not a title.
            """
        case .extras:
            return framing + "\n\n" + """
            List the EXTRAS this disc offers — featurettes, deleted scenes,
            interviews, trailers, short documentaries — one per line, with the
            running time in brackets after each one if the menu printed it:

                <the name the menu prints> (6:11)

            Use the names the menu prints, corrected for OCR damage. Do not
            invent an extra that the menu does not name, and never answer with
            the example above — it shows the shape of a line, not a title.
            """
        }
    }

    /// The question put to the model: its framing, then the evidence it needs.
    ///
    /// Each question is shown only what it can use. The films question gets
    /// the menu pages with their repetition intact, because that repetition is
    /// the double-feature signal; the extras question gets the runtimes too,
    /// because matching a printed time is how its answer will be checked.
    static func prompt(_ question: Question, evidence: DiscEvidence) -> String {
        let pages = evidence.menuPages.enumerated().map { index, page in
            "Menu screen \(index + 1):\n" + page.map { "- \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")

        var parts = ["The disc label is \"\(evidence.volumeName)\"."]
        if !pages.isEmpty { parts.append("Text read off its menus:\n\n\(pages)") }

        switch question {
        case .films:
            parts.append("Which feature films are on this disc?")
        case .bonusFeature, .extras:
            if !evidence.titleTableForPrompt.isEmpty {
                parts.append("The disc's video tracks and how long each runs:\n\n"
                             + evidence.titleTableForPrompt)
            }
            parts.append(question == .bonusFeature
                         ? "Which long pieces of bonus material are on this disc?"
                         : "Which extras are on this disc?")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Reading the reply

    /// One line per answer, with an optional trailing runtime.
    ///
    /// Reuses `MultiTitleInference`'s sanitiser — the judgement about what a
    /// title looks like already lives there — and `MenuExtraLabels`' runtime
    /// parser, so "The Making of Signs (58:54)" splits the same way the menu
    /// text does.
    static func claims(from raw: String, question: Question) -> [Claim] {
        var found: [Claim] = []
        var seen = Set<String>()
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = MultiTitleInference.stripListMarker(
                String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
            guard !line.isEmpty, !MultiTitleInference.isCommentary(line) else { continue }

            // A trailing "(6:11)" is a runtime, and it is what makes the claim
            // checkable — pulled off before the title is sanitised, because
            // `sanitize` strips a trailing bracket as a year.
            var label = line
            var seconds: Int?
            if let printed = MenuExtraLabels.printed(from: line) {
                label = printed.label
                seconds = printed.seconds
            }
            guard let title = DiscTitleInference.sanitize(label) else { continue }
            // #0209 — never accept the prompt's own example back as an answer.
            guard !isPromptEcho(title) else { continue }
            guard seen.insert(title.lowercased()).inserted else { continue }
            found.append(Claim(question: question, label: title, seconds: seconds))
            if found.count == maximumClaimsPerQuestion { break }
        }
        return found
    }

    /// A reply longer than this is a malfunction, not an answer — a model that
    /// has started listing the menu rather than reading it.
    static let maximumClaimsPerQuestion = 12

    /// #0209 — drop every claim the disc's own menu text does not support.
    ///
    /// The model answered a disc labelled NEXT with five pieces of bonus
    /// material: "The Making of Signs", "Behind the Scenes", "A Concert",
    /// "A Retrospective" and "LOOKING FOR SIGNS". None of them is on that disc,
    /// and all five are **this file's own prompt read back**: two are the
    /// format examples, and the other three are the category list — "a
    /// making-of documentary, a behind-the-scenes film, a concert, a
    /// retrospective". They were shown to the user on the evidence panel, which
    /// is the one screen a person consults when a wrong film gets filed.
    ///
    /// It was first read as stale data from an earlier disc leaking through,
    /// which would have sent a real diagnosis hunting a cache that does not
    /// exist: `RipFlowController` clears `discUnderstanding` on every disc
    /// change, and this appeared on a fresh launch.
    ///
    /// Rewording the prompt is the first fix and this is the one that holds.
    /// Any wording can be echoed, and a model asked to name things will
    /// sometimes name the things it was just shown. The disc is the authority
    /// on what is printed on the disc: a claim whose words appear nowhere in
    /// the OCR is not a claim about this disc, whatever produced it.
    ///
    /// Deliberately generous about *how* the words appear. OCR damage is the
    /// norm — `MenuExtraLabels` exists because of it — so this asks only that
    /// most of a claim's words are somewhere in the menu text, not that the
    /// label matches a line. A real label mangled by Vision keeps its words;
    /// an invented one has none of them.
    static func corroborated(_ claims: [Claim], by evidence: DiscEvidence) -> [Claim] {
        let haystack = evidence.menuPages
            .flatMap { $0 }
            .joined(separator: " ")
        guard !haystack.trimmingCharacters(in: .whitespaces).isEmpty else { return claims }
        return claims.filter { isSupported($0.label, by: haystack) }
    }

    /// Whether most of `label`'s words appear in the disc's menu text.
    ///
    /// Words of three letters or fewer are ignored: "the", "of" and "a" are on
    /// every menu ever printed and would corroborate anything.
    ///
    /// Matching is per word and tolerant of one wrong character, because OCR
    /// damage is the normal case rather than the exception — Vision read NEXT's
    /// own menu as "MAKIMG THE BEST NEXT THIMG" on one pass. Requiring exact
    /// words would make a bad scan look like an invented title, which is the
    /// failure this whole check exists to avoid making in the other direction.
    static func isSupported(_ label: String, by haystack: String) -> Bool {
        let words = tokens(label)
        guard !words.isEmpty else {
            // A label of nothing but short words. There is nothing here to
            // check, so let the runtime cross-check downstream be the judge
            // rather than guessing from two letters.
            return true
        }
        let printed = tokens(haystack)
        guard !printed.isEmpty else { return true }

        let hits = words.filter { word in
            printed.contains { isNearlyEqual(word, $0) }
        }.count
        // A strict majority. One word in common is a coincidence — "The Making
        // of Signs" shares "making" with this very disc, and that is how it got
        // on screen — while most of them is the same phrase badly read.
        return hits * 2 > words.count
    }

    /// The words worth matching on, folded.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 3 }
            .map(String.init)
    }

    /// Equal, or one edit apart. Bounded on purpose: two edits starts matching
    /// genuinely different words, and this is deciding whether to believe a
    /// sentence the user will read as fact.
    static func isNearlyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        // Short words have too little left after one edit to mean anything:
        // "sign" and "sing" are one apart and unrelated.
        if min(x.count, y.count) < 5 { return false }

        var i = 0, j = 0, edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count == y.count { i += 1; j += 1 }      // substitution
            else if x.count > y.count { i += 1 }          // deletion from a
            else { j += 1 }                               // insertion into a
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }

    /// #0209 — a placeholder read back as an answer.
    ///
    /// The prompts illustrate their line format with `<the name the menu
    /// prints>`, and a model can echo a placeholder as readily as a title.
    /// Angle brackets never appear in a real menu label, so this is a cheap
    /// certainty rather than a judgement.
    ///
    /// There is deliberately **no list of banned titles** here. An earlier cut
    /// of this fix refused "The Making of Signs" by name, because that was the
    /// example the model echoed onto a disc labelled NEXT — and it broke the
    /// Signs disc, where the very same words are a real label its own menus
    /// print. The echo is not a property of the words; it is a property of
    /// words that are not on the disc in hand. `corroborated(_:by:)` is the
    /// check that knows the difference.
    static func isPromptEcho(_ title: String) -> Bool {
        title.contains("<") || title.contains(">")
    }

    // MARK: - Checking it against the disc

    /// Binds claims to titles by runtime, one to one, over the titles still
    /// unaccounted for.
    ///
    /// `MenuExtraLabels.match` does the assignment, globally optimal, so a
    /// claim is never bound to the title that merely fits it best in isolation
    /// — the Signs extras swap two ways under a greedy rule.
    ///
    /// A claim with no runtime cannot be checked this way and comes back
    /// unverified. That is correct and deliberate: the films question is
    /// answered by name alone, and names are bound to titles by TMDB runtimes
    /// in `FeatureMatching`, which knows things this does not.
    static func verify(
        _ claims: [Claim],
        against titles: [DiscTitle],
        question: Question
    ) -> (findings: [Finding], unverified: [Claim]) {
        let timed = claims.filter { $0.seconds != nil }
        guard !timed.isEmpty, !titles.isEmpty else { return ([], claims) }

        let printed = timed.map { MenuExtraLabels.Printed(label: $0.label, seconds: $0.seconds!) }
        let matches = MenuExtraLabels.match(printed: printed, to: titles)

        let matchedLabels = Set(matches.map(\.label))
        let findings = matches.map {
            Finding(question: question, titleIndex: $0.titleIndex,
                    label: $0.label, offBySeconds: $0.offBySeconds)
        }
        let unverified = claims.filter { !matchedLabels.contains($0.label) }
        return (findings, unverified)
    }
}

// MARK: - Running the whole interrogation

extension DiscInterrogation {

    /// How a question reaches a model. Injected so the sequence is testable
    /// with no model, no disc and no network — the only coverage available in
    /// this project, where UI tests are forbidden.
    typealias Asking = @Sendable (_ instructions: String, _ prompt: String) async -> String?

    /// The production asker: the on-device model, same session shape as
    /// `MultiTitleInference.ask`.
    @concurrent
    static func onDeviceAsking(_ instructions: String, _ prompt: String) async -> String? {
        await FoundationModelAsk.respond(instructions: instructions, prompt: prompt)
    }

    /// Ask every question, in order, and keep only what the disc corroborates.
    ///
    /// Each question is told which titles are already spoken for, so the
    /// extras pass is not offered the film and the bonus pass is not offered
    /// an extra. That is the whole reason this is a sequence rather than three
    /// independent calls: the answers narrow each other.
    static func run(
        evidence: DiscEvidence,
        questions: [Question] = Question.inOrder,
        ask: Asking
    ) async -> Understanding {
        var understanding = Understanding()

        for question in questions {
            guard let reply = await ask(instructions(for: question),
                                        prompt(question, evidence: evidence)),
                  !reply.isEmpty
            else { continue }

            // #0209 — only claims the disc's own menus support.
            let claims = corroborated(
                claims(from: reply, question: question), by: evidence)
            guard !claims.isEmpty else { continue }

            // Only titles nothing has claimed yet, and only the ones this
            // question could plausibly be about.
            let available = evidence.titles.filter {
                !understanding.claimedTitles.contains($0.index) && inScope($0, of: question, evidence: evidence)
            }
            let (findings, unverified) = verify(claims, against: available, question: question)

            switch question {
            case .films: understanding.films += findings
            case .bonusFeature: understanding.bonusFeatures += findings
            case .extras: understanding.extras += findings
            }
            understanding.unverified += unverified
        }
        return understanding
    }

    /// Which titles a question may bind to.
    ///
    /// A bonus feature is long; an extra is short. Without this the extras
    /// pass can name the 58-minute bonus reel as a featurette purely because
    /// some printed runtime happened to land near it, and the film itself is
    /// fair game for anything.
    static func inScope(_ title: DiscTitle, of question: Question, evidence: DiscEvidence) -> Bool {
        if let main = evidence.mainFeatureIndex, title.index == main, question != .films {
            return false
        }
        switch question {
        case .films:
            return title.durationSeconds >= DiscTitleHeuristic.featureMinimumSeconds
        case .bonusFeature:
            return title.durationSeconds >= BonusFeature.minimumSeconds
        case .extras:
            return title.durationSeconds < BonusFeature.minimumSeconds
                && title.durationSeconds >= shortestWorthNaming
        }
    }

    /// Below this a title is a logo sting, a copyright card or a menu loop,
    /// and naming it is noise. Thirty seconds.
    static let shortestWorthNaming = 30
}
