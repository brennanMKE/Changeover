import Foundation

/// Everything one disc's menus produced, as one plain value
/// (`docs/menu-intelligence.md` §1's `MenuIntelligence`).
///
/// **It enriches; it never decides what gets encoded.** `MainFeature`, the
/// 45-minute rule, the Play All guard, the TMDB runtime check and the user's
/// Start remain the only things that choose a title. What is here is a
/// confirmation line, a set of chapter names, a language hint and a search
/// term — every one of them visible, and every one of them optional.
nonisolated struct MenuIntelligence: Equatable, Sendable {
    var frame: MenuStructure.Frame?
    var menuCount: Int = 0
    var stillCount: Int = 0

    /// Tier 1 (+ the lexicon): which button starts the feature, when the
    /// structure says so unambiguously. `nil` is a normal answer.
    var playButton: PlayButtonResolver.Resolution?

    /// Every caption OCR attached to a **real button**, keyed by button.
    ///
    /// The resolver has always computed this and thrown it away once it had
    /// picked a play button. It is kept because it is the archive's
    /// vocabulary column (`MenuAgreement.Signals.labels`): the words real
    /// discs actually print, which is how `MenuLexicon` learns a language
    /// without anyone guessing at it. Text attached to no button is never in
    /// here — that is decoration, and admitting it is the filmography trap.
    var buttonLabels: [MenuButtonRef: String] = [:]

    /// The stills the chapter names were read from, in page order.
    /// The OCR document the rest of this was derived from, kept so a later
    /// stage can ask a question of the disc's own words without re-reading
    /// the disc — `DiscTitleInference` needs every line, not the handful the
    /// rules picked out.
    var ocr: MenuOCRDocument?

    var chapterPages: [String] = []
    var chapterNames: [ChapterNames.Candidate] = []
    /// The rows that will be written as `--markers=<file>`, or empty when the
    /// set was refused. `ChapterMarkerPlan` is the refusal.
    var markerPlan: ChapterMarkerPlan.Decision = .refused(reason: "no chapter names were read")

    /// The disc's own Languages page, as an advisory list. Never a mapping
    /// unless the buttons gave one, and never a track assignment.
    var languages: LanguageHints.Lists?

    /// §6's search-term candidate — only ever offered when the volume name
    /// gave nothing.
    var titleText: MenuTitleGuess.Candidate?

    /// Tier 3's question: set only when two or more title-jumping buttons
    /// survived the lexicon. `nil` means the model is not asked at all.
    var judgeQuestion: MenuJudge.Question?
    /// What the model answered, once it has. A **caption**, never a
    /// selection.
    var judgeCaption: String?

    var markerRows: [MarkerRow] { markerPlan.rows }

    /// Whether anything at all came out of the disc.
    var isEmpty: Bool {
        playButton == nil && chapterNames.isEmpty && (languages?.isEmpty ?? true) && titleText == nil
    }
}

// MARK: - Where the menu read stands

/// A sibling of `ScanState` on `JobController`: cleared on `removeDisc()` and
/// on a fresh `startScan`, so a caption from one disc can never show under
/// another. Start never waits on it.
nonisolated enum MenuState: Equatable, Sendable {
    case idle
    case reading
    case ready(MenuIntelligence)
    case unavailable(MenuUnavailable)

    var intelligence: MenuIntelligence? {
        if case .ready(let value) = self { return value }
        return nil
    }
}

// Lives here, beside `MenuState`, rather than in `MenuHelper`: the state and
// its reasons are one value, and keeping them together is what lets the pure
// menu sources compile on their own for `Tools/menu-agreement` and
// `Tools/menu-derive` without dragging `ProcessRunner` in behind them.
/// Why there is no menu intelligence for the disc in the drive.
///
/// Every case is a caption, never a failure: the rip is byte-identical to
/// what it is today in all of them (`docs/menu-intelligence.md` §9).
nonisolated enum MenuUnavailable: Error, Equatable, Sendable {
    /// No `changeover-menudump` on this Mac.
    case helperMissing(path: String)
    /// The helper ran but could not decrypt the menu video, so there are no
    /// stills: buttons and targets are still known, names and hints are not.
    case librariesMissing([String])
    /// The disc has menus the helper could read and there is nothing in them
    /// — or no menus at all.
    case noMenus
    /// Anything else: a crash, a timeout, an unreadable VIDEO_TS.
    case failed(String)

    /// The one line the Confirm step shows. Always says what is missing *and*
    /// that the rip is unaffected, because that is the only thing the user
    /// has to decide about it: nothing.
    var caption: String {
        switch self {
        case .helperMissing:
            return "Disc menus: not read — changeover-menudump isn't installed (Settings ▸ Dependencies). The rip is unaffected."
        case .librariesMissing(let formulae):
            let list = formulae.joined(separator: ", ")
            return "Disc menus: buttons only — \(list) isn't installed, so the menu text can't be read (Settings ▸ Dependencies). The rip is unaffected."
        case .noMenus:
            return "Disc menus: nothing readable on this disc. The rip is unaffected."
        case .failed(let reason):
            return "Disc menus: not read — \(reason). The rip is unaffected."
        }
    }
}

// MARK: - Choosing the pages to read

/// Which stills are the chapter menu, which is the languages page, and which
/// are entry menus — decided from what the capture actually has.
///
/// **Why this is not just `entryType`.** On the first real disc the helper
/// read (Bloodsport, 2026-09-18) every VTSM PGC came back `entryType: "none"`
/// with an empty button table: the menu PGCI's entry bits and the NAV packs'
/// highlight information were not where a still menu was expected to keep
/// them. Tier 1 therefore produced nothing on the one disc the corpus has,
/// and a chapter-name path that depended on it would produce nothing too.
/// So the structural route is used when it is there, and a text route —
/// which reads the numbers the disc prints beside its own captions — when it
/// is not. Both are pure, both are pinned against the same capture.
nonisolated enum MenuPages {

    /// The stills that look like chapter pages.
    ///
    /// Structure first: the PGCs whose entry type is `chapter`, plus any
    /// still they name. Failing that, a still qualifies when it prints at
    /// least three distinct chapter numbers, all of them inside
    /// `1...chapterCount`, each with a name beside it. A cast page's
    /// filmography years are four digits and never match; a page-range
    /// button ("7-12") is dropped before this sees it.
    static func chapterPages(
        ocr: MenuOCRDocument,
        structure: MenuStructure?,
        chapterCount: Int
    ) -> [MenuOCRDocument.Still] {
        if let structure {
            // Two structural routes, and the buttons are the stronger one.
            // `entryType` says what the author tagged the PGC; the buttons say
            // what it does. A five-page scene index tagged "none" — which is
            // what a real disc turned out to be — is found only by the second,
            // and it names the individual pages, which is the granularity a
            // caption has to be paired at.
            var ids = structure.chapterPageIDs()
            ids.formUnion(structure.menus.filter(\.isChapterMenu).flatMap(\.stillIDs))
            let matched = ocr.stills.filter { ids.contains($0.id) }
            if !matched.isEmpty { return matched.sorted { $0.id < $1.id } }
        }
        guard chapterCount > 0 else { return [] }
        let matched = ocr.stills.filter { still in
            let numbers = ChapterNames
                .candidates(observations: still.observations)
                .map(\.chapter)
            guard numbers.count >= 3 else { return false }
            guard Set(numbers).count == numbers.count else { return false }
            return numbers.allSatisfy { $0 >= 1 && $0 <= chapterCount }
        }
        return matched.sorted { $0.id < $1.id }
    }

    /// The still that carries the Languages page, if any: the one whose text
    /// yields the most language names. `LanguageHints.lists` already refuses
    /// to read a name that no heading introduced, so a page with no headings
    /// scores zero and is never chosen.
    static func languagesPage(ocr: MenuOCRDocument) -> (still: MenuOCRDocument.Still, lists: LanguageHints.Lists)? {
        var best: (still: MenuOCRDocument.Still, lists: LanguageHints.Lists, score: Int)?
        for still in ocr.stills {
            let lists = LanguageHints.lists(observations: still.observations)
            let score = lists.spoken.count + lists.subtitles.count
            guard score > 0 else { continue }
            if best == nil || score > best!.score {
                best = (still, lists, score)
            }
        }
        guard let best else { return nil }
        return (best.still, best.lists)
    }

    /// §6's entry stills — the VMGM title menu and the VTSM root menu, and
    /// nothing else. With no structure there is no way to tell an entry menu
    /// from a bio page, so the answer is **none**: a wrong search term is
    /// cheap, but the filmography trap is exactly what guessing produces.
    static func entryStills(ocr: MenuOCRDocument, structure: MenuStructure?) -> [MenuTitleGuess.EntryStill] {
        guard let structure else { return [] }
        return structure.menus.filter(\.isEntryMenu).compactMap { menu in
            let ids = menu.stills ?? [menu.id]
            guard let still = ids.compactMap({ ocr.still($0) }).first else { return nil }
            return MenuTitleGuess.EntryStill(
                id: still.id,
                observations: still.observations,
                buttons: menu.buttons.map(\.rect)
            )
        }
    }
}

// MARK: - Deriving it

extension MenuIntelligence {

    /// Everything tiers 1 and 2 can say about one disc, from its recorded
    /// structure and OCR. Pure: the archive's `Tools/menu-derive` and the
    /// running app call the same function over the same two documents, so
    /// what a review reads and what the user is shown cannot drift apart.
    ///
    /// - Parameters:
    ///   - featureChapterCount: `DiscTitle.chapterCount` for the title the
    ///     scan settled on. The chapter names are matched against it and
    ///     refused on any disagreement — never padded, never trimmed.
    ///   - scanTitles: the title indices the scan actually found, so a play
    ///     button pointing at a title HandBrake does not have is dropped
    ///     rather than captioned.
    static func derive(
        structure: MenuStructure?,
        ocr: MenuOCRDocument?,
        featureChapterCount: Int?,
        scanTitles: Set<Int> = []
    ) -> MenuIntelligence {
        var result = MenuIntelligence()
        result.frame = structure?.frame
        result.menuCount = structure?.menus.count ?? 0
        result.stillCount = ocr?.stills.count ?? 0

        let buttons = structure?.resolvedButtons() ?? []
        let observationsByStill = Dictionary(
            uniqueKeysWithValues: (ocr?.stills ?? []).map { ($0.id, $0.observations) }
        )
        var labels: [MenuButtonRef: String] = [:]
        for (id, observations) in observationsByStill {
            let onThisStill = buttons.filter { $0.ref.menu == id }
            guard !onThisStill.isEmpty else { continue }
            labels.merge(PlayButtonResolver.labels(buttons: onThisStill, observations: observations)) { current, _ in current }
        }
        result.buttonLabels = labels

        if let structure {
            if let resolution = PlayButtonResolver.resolve(structure, labels: labels),
               scanTitles.isEmpty || scanTitles.contains(resolution.title) {
                result.playButton = resolution
            }
            result.judgeQuestion = MenuJudge.question(
                candidates: PlayButtonResolver.titleJumpingButtons(structure),
                labels: labels,
                scanTitles: scanTitles
            )
        }

        if let ocr {
            result.ocr = ocr
            let pages = MenuPages.chapterPages(
                ocr: ocr,
                structure: structure,
                chapterCount: featureChapterCount ?? 0
            )
            result.chapterPages = pages.map(\.id)
            result.chapterNames = pages.flatMap { page in
                let onThisPage = buttons.filter { $0.ref.menu == page.id }
                return onThisPage.isEmpty
                    ? ChapterNames.candidates(observations: page.observations)
                    : ChapterNames.candidates(buttons: onThisPage, observations: page.observations)
            }
            result.markerPlan = ChapterMarkerPlan.decide(
                candidates: result.chapterNames,
                chapterCount: featureChapterCount
            )
            if let page = MenuPages.languagesPage(ocr: ocr) {
                let onThisPage = buttons.filter { $0.ref.menu == page.still.id }
                result.languages = onThisPage.isEmpty
                    ? page.lists
                    : LanguageHints.lists(observations: page.still.observations, buttons: onThisPage)
            }
            result.titleText = MenuTitleGuess.candidate(
                entryStills: MenuPages.entryStills(ocr: ocr, structure: structure)
            )
            // Last resort: the film's name lifted out of a bonus feature's
            // name, from any page. Only when the entry menus gave nothing at
            // all — Enemy at the Gates opens every one of them on a colour-bar
            // leader, so its title card is never readable, while its special
            // features page prints "INSIDE ENEMY AT THE GATES" in plain type.
            if result.titleText == nil {
                result.titleText = MenuTitleGuess.featuretteCandidate(stills: ocr.stills)
            }
        }

        return result
    }
}

// MARK: - The audio picker's hint

/// What the disc's Languages menu says, shown beside the audio picker
/// (`docs/menu-intelligence.md` §5.3).
///
/// **Advisory, always.** It never changes `AudioTrackOptions.preselection`,
/// never sets a `languageCode` on an untagged stream and never merges tracks.
/// Even where the menu's buttons do give a structural stream mapping, the
/// line stays a line: the list is only as complete as one OCR pass over one
/// still, and on the measured disc it demonstrably is not complete — the
/// languages page prints four subtitle entries and no single Vision
/// configuration read all four (the recommended language list reads 日本語 and
/// drops "Off"; the defaults do the opposite). So nothing downstream may
/// treat this as the disc's inventory of anything.
nonisolated enum MenuAudioHint {

    static func line(_ lists: LanguageHints.Lists?) -> String? {
        guard let lists, let caption = LanguageHints.caption(lists) else { return nil }
        switch lists.shape {
        case .buttons:
            return caption + " That is what the menu shows; the tracks themselves are untouched."
        case .listing, .none:
            return caption
        }
    }
}

// MARK: - What the user reads

/// The Confirm step's menu captions. One pure function per line, so the
/// wording is pinned by tests and the view only lays them out.
nonisolated enum MenuStatusLine {

    /// While the helper is running.
    static let readingCaption = "Reading the disc's menus…"

    /// Every line to show for `state`, in order. Empty when there is nothing
    /// to say — which is the common case on a disc whose menus gave nothing,
    /// and which must never read as a problem.
    ///
    /// - Parameter markerPlan: the chapter decision for the title the user
    ///   currently has selected, which can differ from the one the names were
    ///   read against. When given it wins, so the caption always describes
    ///   what Start would actually do.
    static func lines(
        _ state: MenuState,
        scanFeatureTitle: Int?,
        markerPlan: ChapterMarkerPlan.Decision? = nil
    ) -> [String] {
        switch state {
        case .ready(var menu):
            if let markerPlan { menu.markerPlan = markerPlan }
            return readyLines(menu, scanFeatureTitle: scanFeatureTitle)
        default:
            return baseLines(state, scanFeatureTitle: scanFeatureTitle)
        }
    }

    private static func baseLines(_ state: MenuState, scanFeatureTitle: Int?) -> [String] {
        switch state {
        case .idle:
            return []
        case .reading:
            return [readingCaption]
        case .unavailable(let reason):
            return [reason.caption]
        case .ready(let menu):
            return readyLines(menu, scanFeatureTitle: scanFeatureTitle)
        }
    }

    private static func readyLines(_ menu: MenuIntelligence, scanFeatureTitle: Int?) -> [String] {
        var lines: [String] = []
        if let line = PlayButtonResolver.confirmationLine(menu.playButton, scanFeatureTitle: scanFeatureTitle) {
            lines.append(line)
        }
        if let caption = menu.judgeCaption {
            lines.append(caption)
        }
        if let chapters = chapterLine(menu) {
            lines.append(chapters)
        }
        return lines
    }

    /// `docs/plain-language-ui.md` §3.6 — the lines the **plain** register
    /// shows, which is almost none of them.
    ///
    /// Every `MenuUnavailable` caption says the same two things: a tool is
    /// missing, and the rip is unaffected. The second half is why the first
    /// half is not the person's problem, so with Details off there is nothing
    /// to say at all — and an empty list is the right answer, not a gap.
    /// `.reading` likewise: a menu read the rip never waits on is not news.
    ///
    /// What survives is the pair that can change what someone does: the disc
    /// disagreeing with the scan about which part is the movie, and the
    /// promise that the disc's chapter names will be in the file.
    ///
    /// The **refusal** line does not survive. `ChapterMarkerPlan`'s comment
    /// says a refusal the user cannot see is indistinguishable from a bug;
    /// this design's answer is that the owner, who has Details open, sees it,
    /// and that a person who does not know what a chapter marker is should
    /// not be told one was refused.
    static func plainLines(
        _ state: MenuState,
        scanFeatureTitle: Int?,
        markerPlan: ChapterMarkerPlan.Decision? = nil
    ) -> [String] {
        guard case .ready(var menu) = state else { return [] }
        if let markerPlan { menu.markerPlan = markerPlan }

        var lines: [String] = []
        if let line = PlayButtonResolver.plainConfirmationLine(menu.playButton, scanFeatureTitle: scanFeatureTitle) {
            lines.append(line)
        }
        if case .write = menu.markerPlan {
            lines.append("Chapter names from the disc will be included.")
        }
        return lines
    }

    /// What will happen to the chapter names at Start — including, in plain
    /// words, when they will *not* be written. A refusal the user cannot see
    /// is indistinguishable from a bug.
    static func chapterLine(_ menu: MenuIntelligence) -> String? {
        switch menu.markerPlan {
        case .write(let rows):
            return "\(rows.count) chapter names from the disc menu will be written into the file."
        case .refused(let reason):
            guard !menu.chapterNames.isEmpty else { return nil }
            return "Chapter names from the disc menu are not being used — \(reason)."
        }
    }
}
