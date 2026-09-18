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

    /// The stills the chapter names were read from, in page order.
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
            let ids = Set(structure.menus.filter(\.isChapterMenu).flatMap { menu in
                menu.stills ?? [menu.id]
            })
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
        }

        return result
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
