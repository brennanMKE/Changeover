import Foundation

/// One disc's answer to the only question the archive exists to settle:
/// **does the disc's own menu pick the same title the heuristic does?**
///
/// `docs/menu-intelligence.md` §8.6 made that an invariant hidden inside a
/// corpus assertion — it either passed or it failed, and a disc that had no
/// menus, or menus that said nothing, produced silence indistinguishable
/// from agreement. This type makes the answer a *recorded value* instead:
/// four independent readings side by side, plus a verdict that is stored
/// rather than inferred, plus the signals a future rule would be built from.
///
/// **It changes nothing.** `DiscTitleHeuristic` remains the only thing that
/// picks a title (#0025's principle, restated in the design's opening
/// paragraph): `MainFeature`, the 45-minute fallback (#0056), the Play All
/// guard, the TMDB runtime cross-check and the user's Start. Nothing here is
/// read by `EncodeSelection`, `StartGate` or `RipRequest`. It is evidence,
/// gathered so that the question "is the menu answer trustworthy enough to
/// ever preselect a title?" can one day be answered from more than one disc.
nonisolated struct MenuAgreement: Codable, Equatable, Sendable {

    /// How `DiscTitleHeuristic` arrived at today's answer.
    nonisolated enum HeuristicRoute: String, Codable, Equatable, Sendable {
        /// HandBrake's `MainFeature` named a title and the guard let it through.
        case scanner
        /// #0056's 45-minute fallback promoted the only long title.
        case length
        /// The Play All guard fired: a title was named and then refused.
        case playAllGuard
        /// #0039 — the scan read zero titles.
        case noTitles
        /// Titles, but no feature: no scanner answer and zero or two-plus
        /// titles over the threshold. The picker, and a reason.
        case noCandidate

        /// Routes that name a title the app would actually rip. `playAllGuard`
        /// names a title and then refuses it, which is exactly why it is not
        /// in here.
        var selectsATitle: Bool { self == .scanner || self == .length }
    }

    /// How the disc's own menu arrived at its answer — the resolver's rungs,
    /// plus the four ways there is no answer to have.
    nonisolated enum MenuRoute: String, Codable, Equatable, Sendable {
        case structure
        case pgcCommands
        case linkedMenu
        case lexicon
        case model
        /// This disc has no `menus/` directory: captured before the helper
        /// existed, or never read. **Not a disagreement** — the single most
        /// important distinction in this file.
        case notCaptured
        /// `menus/` exists but carries no `structure.json` (no helper, or a
        /// helper that failed), so tier 1 has nothing to resolve.
        case noStructure
        /// A structure was read and no button resolved to a title: picture
        /// menus, GPRM-driven authoring, a disc whose play path this build
        /// cannot follow.
        case unresolved
        /// A button resolved to a title the scan does not list. Recorded as
        /// its own case rather than as an answer: it is a fact about the
        /// reader, not about the film.
        case outsideScan

        var isAnswer: Bool {
            switch self {
            case .structure, .pgcCommands, .linkedMenu, .lexicon, .model: return true
            case .notCaptured, .noStructure, .unresolved, .outsideScan: return false
            }
        }
    }

    /// The recorded verdict. Stored in `disc.json`, compared by the sweep,
    /// counted by the report — never re-derived by a reader squinting at two
    /// numbers.
    nonisolated enum Verdict: String, Codable, Equatable, Sendable {
        /// Both named a title and it is the same title.
        case agree
        /// Both named a title and they differ. The interesting row.
        case disagree
        /// The heuristic named a title; the menu had nothing to say.
        case menuAbstained
        /// The menu named a title; the heuristic did not (`.none`/`.noTitles`).
        case heuristicAbstained
        /// Neither named a title.
        case bothAbstained
        /// This disc's menus were never captured. Absence of evidence.
        case notCaptured
    }

    // MARK: - What each source said

    var slug: String

    /// HandBrake's `MainFeature`, as a usable title index — `nil` when the
    /// scanner gave no answer at all.
    var scannerTitle: Int?
    /// What `MainFeature` literally reported, kept even when it is useless:
    /// Hornet's Nest says `-1`, and "-1" and "absent" are different stories
    /// about the same disc.
    var scannerRaw: Int?

    var heuristicRoute: HeuristicRoute
    /// The title the outcome names. Non-`nil` on `playAllGuard` too — the
    /// guard names the offending title and then refuses it, and the route is
    /// what says which happened.
    var heuristicTitle: Int?

    var menuRoute: MenuRoute
    var menuTitle: Int?
    /// The OCR'd caption on the button, when there was one. `nil` is normal:
    /// a picture-only menu still resolves structurally.
    var menuLabel: String?

    var verdict: Verdict

    var signals: Signals

    // MARK: - The signals a future rule would be built from

    /// Everything the disc offered that is not itself an answer. None of it
    /// is used by anything today; it is recorded so that a rule proposed
    /// after ten discs can be checked against ten discs rather than argued
    /// about.
    nonisolated struct Signals: Codable, Equatable, Sendable {
        var menuCount: Int = 0
        /// Menus that yielded at least one button. The gap between this and
        /// `menuCount` is how much of a disc's menu domain the reader is
        /// actually seeing.
        var menusWithButtons: Int = 0
        var buttonCount: Int = 0
        /// The busiest single menu. A season disc's episode page and a
        /// film's scene index are both large; the difference is what the
        /// buttons *do*, which is the next two fields.
        var largestMenuButtons: Int = 0
        /// Buttons that start a title, following the one permitted
        /// indirection.
        var titleJumpingButtons: Int = 0
        /// The distinct titles those buttons reach, ascending.
        var titlesJumpedTo: [Int] = []
        /// Buttons whose command addresses a chapter (`JumpVTS_PTT`).
        var chapterButtons: Int = 0
        /// Stills identified as scene-selection pages.
        var chapterPages: Int = 0
        /// Chapter names read, and the subset the marker plan would write.
        var chapterNamesRead: Int = 0
        var chapterNamesEmitted: Int = 0
        /// `MenuTVSignal` — ≥3 buttons on one menu jumping to distinct
        /// titles. A second witness for `docs/tv-seasons-plan.md`, never an
        /// input to it.
        var tvSignal: Bool?
        var tvSignalReason: String?
        var spokenLanguages: [String] = []
        var subtitleLanguages: [String] = []
        /// Every caption OCR attached to a real button, with what the
        /// lexicon makes of it. **This is the vocabulary column**: the list
        /// of words real discs actually print, and — through `role == nil` —
        /// the list of words the lexicon still has to learn.
        var labels: [Label] = []

        /// Captions the lexicon has no row for. The report's call to action.
        var unknownLabels: [String] { labels.filter { $0.role == nil }.map(\.text) }
    }

    nonisolated struct Label: Codable, Equatable, Sendable {
        var text: String
        /// `MenuLexicon.Role`'s raw value, or `nil` when the table has never
        /// seen this word.
        var role: String?
        /// What the button does, in `MenuDerived`'s short form (`title:1`,
        /// `menu:pgc3`, `unresolved:LinkTailPGC`).
        var target: String

        init(text: String, role: MenuLexicon.Role?, target: String) {
            self.text = text
            self.role = role?.rawValue
            self.target = target
        }
    }

    // MARK: - Deciding the verdict (pure)

    /// The verdict, from the two answers alone. Separated out so the rule is
    /// one readable expression and so a test can drive every branch without
    /// a disc.
    ///
    /// The asymmetry that matters: **a disc whose menus were never captured
    /// is `notCaptured`, never `disagree`.** Most of the corpus is in that
    /// state today, and a report that counted those as disagreements would
    /// say the menu answer is untrustworthy when what it means is that
    /// nobody has looked.
    static func verdict(heuristicTitle: Int?, menuRoute: MenuRoute, menuTitle: Int?) -> Verdict {
        guard menuRoute != .notCaptured else { return .notCaptured }
        switch (heuristicTitle, menuRoute.isAnswer ? menuTitle : nil) {
        case (nil, nil): return .bothAbstained
        case (_?, nil): return .menuAbstained
        case (nil, _?): return .heuristicAbstained
        case (let heuristic?, let menu?): return heuristic == menu ? .agree : .disagree
        }
    }

    // MARK: - Reading it off one captured disc (pure)

    /// Everything above, computed from what a capture holds.
    ///
    /// - Parameters:
    ///   - disc: the parsed scan.
    ///   - mainFeatureIndex: HandBrake's `MainFeature`, exactly as reported.
    ///   - structure: `menus/structure.json`, or `nil`.
    ///   - ocr: `menus/ocr.json`, or `nil`.
    ///   - menusCaptured: whether the disc has a `menus/` directory at all.
    ///     This is what separates `notCaptured` from `noStructure`, and it
    ///     cannot be inferred from the two documents being `nil`.
    static func evaluate(
        slug: String,
        disc: DiscInfo,
        mainFeatureIndex: Int?,
        structure: MenuStructure?,
        ocr: MenuOCRDocument?,
        menusCaptured: Bool
    ) -> MenuAgreement {
        let outcome = DiscTitleHeuristic.classify(disc, mainFeatureIndex: mainFeatureIndex)
        let (route, heuristicTitle) = read(outcome)

        let scanTitles = Set(disc.titles.map(\.index))
        let featureChapterCount = heuristicTitle
            .flatMap { index in disc.titles.first { $0.index == index } }?
            .chapterCount

        let intelligence = MenuIntelligence.derive(
            structure: structure,
            ocr: ocr,
            featureChapterCount: featureChapterCount,
            scanTitles: scanTitles
        )

        let (menuRoute, menuTitle, menuLabel) = readMenu(
            intelligence: intelligence,
            structure: structure,
            menusCaptured: menusCaptured,
            scanTitles: scanTitles
        )

        return MenuAgreement(
            slug: slug,
            scannerTitle: usableScannerAnswer(mainFeatureIndex, titles: scanTitles),
            scannerRaw: mainFeatureIndex,
            heuristicRoute: route,
            heuristicTitle: heuristicTitle,
            menuRoute: menuRoute,
            menuTitle: menuTitle,
            menuLabel: menuLabel,
            verdict: verdict(heuristicTitle: heuristicTitle, menuRoute: menuRoute, menuTitle: menuTitle),
            signals: signals(intelligence: intelligence, structure: structure)
        )
    }

    /// `MainFeature` as a title index, applying exactly `DiscTitleHeuristic`'s
    /// own reading of it: absent, `<= 0`, or naming a title the list does not
    /// contain are all "no answer".
    private static func usableScannerAnswer(_ index: Int?, titles: Set<Int>) -> Int? {
        guard let index, index > 0, titles.contains(index) else { return nil }
        return index
    }

    private static func read(_ outcome: DiscTitleHeuristic.Outcome) -> (HeuristicRoute, Int?) {
        switch outcome {
        case .single(let index, .scanner): return (.scanner, index)
        case .single(let index, .length): return (.length, index)
        case .playAll(let index, _): return (.playAllGuard, index)
        case .noTitles: return (.noTitles, nil)
        case .none: return (.noCandidate, nil)
        }
    }

    private static func readMenu(
        intelligence: MenuIntelligence,
        structure: MenuStructure?,
        menusCaptured: Bool,
        scanTitles: Set<Int>
    ) -> (MenuRoute, Int?, String?) {
        guard menusCaptured else { return (.notCaptured, nil, nil) }
        guard let structure else { return (.noStructure, nil, nil) }
        if let play = intelligence.playButton {
            return (MenuRoute(rawValue: play.resolvedBy.rawValue) ?? .structure, play.title, play.label)
        }
        // `MenuIntelligence.derive` drops a resolution whose title the scan
        // never found. That is the right thing for a caption and the wrong
        // thing for an archive, so the fact is kept here under its own name.
        if let dropped = PlayButtonResolver.resolve(structure), !scanTitles.contains(dropped.title) {
            return (.outsideScan, dropped.title, dropped.label)
        }
        return (.unresolved, nil, nil)
    }

    private static func signals(intelligence: MenuIntelligence, structure: MenuStructure?) -> Signals {
        var signals = Signals()
        signals.menuCount = intelligence.menuCount
        signals.chapterPages = intelligence.chapterPages.count
        signals.chapterNamesRead = intelligence.chapterNames.count
        signals.chapterNamesEmitted = intelligence.markerRows.count
        signals.spokenLanguages = intelligence.languages?.spoken ?? []
        signals.subtitleLanguages = intelligence.languages?.subtitles ?? []

        guard let structure else { return signals }
        let buttons = structure.resolvedButtons()
        signals.menusWithButtons = structure.menus.filter { !$0.buttons.isEmpty }.count
        signals.buttonCount = buttons.count
        signals.largestMenuButtons = structure.menus.map(\.buttons.count).max() ?? 0

        let titled = buttons.compactMap { PlayButtonResolver.title(of: $0, in: structure) }
        signals.titleJumpingButtons = titled.count
        signals.titlesJumpedTo = Set(titled).sorted()
        signals.chapterButtons = buttons.filter {
            if case .chapter = $0.target { return true } else { return false }
        }.count

        let tv = MenuTVSignal.evaluate(structure)
        signals.tvSignal = tv.value
        signals.tvSignalReason = tv.reason
        signals.labels = vocabulary(structure: structure, intelligence: intelligence)
        return signals
    }

    /// The captions OCR attached to real **navigation** buttons,
    /// deduplicated by text and sorted, with what the lexicon makes of each.
    ///
    /// Three exclusions, each because the words it drops belong to something
    /// else that already records them:
    ///
    /// * Text attached to **no button** is decoration — a filmography line, a
    ///   copyright notice, a logo — and letting it in here is §6's
    ///   filmography trap wearing a different hat.
    /// * A **chapter** button's caption is a chapter *name*
    ///   (`ChapterNames`), not a button word. Bloodsport's scene pages alone
    ///   would otherwise put twenty-three film beats into the lexicon's work
    ///   list.
    /// * A **`SetSTN`** button's caption is a language name
    ///   (`LanguageHints`, recorded beside this as `spokenLanguages` /
    ///   `subtitleLanguages`). "English" is not a word the play-button table
    ///   should ever learn.
    ///
    /// What is left is filtered by `looksLikeAButtonWord`, because a button
    /// rectangle on a cast page encloses a sentence and OCR merges a row of
    /// captions into one observation. The survivors of that are still
    /// recorded when they are junk — `"Start Movie Main Menu"` is two buttons
    /// read as one, and seeing it in the report is how that gets noticed.
    private static func vocabulary(structure: MenuStructure, intelligence: MenuIntelligence) -> [Label] {
        var seen: [String: Label] = [:]
        for button in structure.resolvedButtons() {
            switch button.target {
            case .chapter, .chapterInVTS, .streams: continue
            default: break
            }
            guard let text = intelligence.buttonLabels[button.ref]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            guard looksLikeAButtonWord(text), seen[text] == nil else { continue }
            seen[text] = Label(
                text: text,
                role: MenuLexicon.role(of: text),
                target: button.target.archiveDescription
            )
        }
        return seen.values.sorted { $0.text < $1.text }
    }

    /// Does this caption read like a button word rather than like a sentence
    /// that happens to sit inside a button rectangle?
    ///
    /// Deliberately crude, and deliberately generous: its only job is to keep
    /// the report's "unknown to the lexicon" list short enough to act on. A
    /// word it wrongly drops costs a lexicon row that nobody was prompted to
    /// add; a sentence it wrongly keeps costs one line of noise.
    static func looksLikeAButtonWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 28 else { return false }
        guard trimmed.split(separator: " ").count <= 4 else { return false }
        guard let first = trimmed.unicodeScalars.first,
              !CharacterSet.decimalDigits.contains(first) else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        return !MenuTitleGuess.looksLikeFilmographyCredit(trimmed)
    }
}
