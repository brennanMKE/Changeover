import Foundation

/// `menus/derived.json`, format `changeover-menu-derived/1` — tiers 1 and 2
/// resolved over one disc's captured structure and OCR
/// (`docs/menu-intelligence.md` §8.3).
///
/// Written by `Tools/menu-derive` during a capture and by the app at rip
/// time from the same functions, so what the archive records and what the
/// user is shown cannot drift apart. Nothing here is an input to the rip;
/// it is the record a human review reads and the sweep asserts against.
nonisolated struct MenuDerived: Codable, Equatable, Sendable {

    nonisolated struct Resolver: Codable, Equatable, Sendable {
        var app: String
        var lexicon: Int
    }

    nonisolated struct ButtonRecord: Codable, Equatable, Sendable {
        var menu: String
        var number: Int
        /// The decoded target, as a short string — `title:1`,
        /// `chapter:1.4`, `menu:3`, `streams`, or the mnemonic of a command
        /// this build could not name.
        var target: String
        var label: String?
        var labelConfidence: Float?
    }

    nonisolated struct ChapterMenu: Codable, Equatable, Sendable {
        var title: Int?
        var buttons: Int
        var pages: [String]
        var names: [ChapterNames.Candidate]
        var csvRows: Int
    }

    nonisolated struct TVSignal: Codable, Equatable, Sendable {
        var value: Bool
        var reason: String
    }

    var format: String
    var resolver: Resolver
    var buttons: [ButtonRecord]
    var playButton: PlayButtonResolver.Resolution?
    var chapterMenu: ChapterMenu?
    var languages: LanguageHints.Lists?
    var tvSignal: TVSignal
    var titleText: MenuTitleGuess.Candidate?
    /// The tier-3 record. Always `nil` in this slice — the model is not
    /// called yet — and `null` in the archive means "never asked", not
    /// "asked and got nothing".
    var judge: String?

    static func decode(_ data: Data) throws -> MenuDerived {
        try JSONDecoder().decode(MenuDerived.self, from: data)
    }
}

extension MenuDerived {

    /// The archive record for one disc, built from the same
    /// `MenuIntelligence` the user was shown.
    ///
    /// `Tools/menu-derive` computes this offline from a capture; this builds
    /// it at rip time from the answers already in hand. Deriving it a second
    /// time here would be the drift the archive exists to rule out — if what
    /// is recorded and what was acted on can disagree, the archive stops
    /// being evidence.
    static func make(structure: MenuStructure, intelligence: MenuIntelligence) -> MenuDerived {
        let buttons = structure.resolvedButtons()
        let chapterButtons = buttons.filter {
            if case .chapter = $0.target { return true } else { return false }
        }
        return MenuDerived(
            format: "changeover-menu-derived/1",
            resolver: Resolver(app: "app", lexicon: MenuLexicon.entries.count),
            buttons: buttons.map { button in
                ButtonRecord(
                    menu: button.ref.menu,
                    number: button.ref.number,
                    target: button.target.archiveDescription,
                    label: intelligence.buttonLabels[button.ref],
                    labelConfidence: nil
                )
            },
            playButton: intelligence.playButton,
            chapterMenu: intelligence.chapterPages.isEmpty ? nil : ChapterMenu(
                title: intelligence.playButton?.title,
                buttons: chapterButtons.count,
                pages: intelligence.chapterPages,
                names: intelligence.chapterNames.sorted { $0.chapter < $1.chapter },
                csvRows: intelligence.markerRows.count
            ),
            languages: intelligence.languages,
            tvSignal: MenuTVSignal.evaluate(structure),
            titleText: intelligence.titleText,
            // The caption the model gave, or nil when it was never asked —
            // and those two must stay distinguishable in the archive.
            judge: intelligence.judgeCaption
        )
    }
}

extension ButtonTarget {
    /// The short form `derived.json` records. Lossless enough to read in a
    /// diff, and never the source of truth — `structure.json`'s raw 16 hex
    /// characters are.
    var archiveDescription: String {
        switch self {
        case .title(let n): return "title:\(n)"
        case .titleInVTS(let vts, let ttn): return "vtsTitle:\(vts).\(ttn)"
        case .chapter(let title, let ptt): return "chapter:\(title).\(ptt)"
        case .chapterInVTS(let vts, let ttn, let ptt): return "vtsChapter:\(vts).\(ttn).\(ptt)"
        case .menu(let ref):
            let parts = [ref.domain, ref.vts.map(String.init), ref.pgc.map { "pgc\($0)" }, ref.menuID.map { "menu\($0)" }]
            return "menu:" + parts.compactMap { $0 }.joined(separator: ".")
        case .streams(let audio, let subpicture):
            return "streams:a\(audio.map(String.init) ?? "-")s\(subpicture.map(String.init) ?? "-")"
        case .unresolved(let mnemonic): return "unresolved:\(mnemonic)"
        }
    }
}

/// The menu's opinion on whether this is a TV disc.
///
/// A season disc's "chapter" menu is usually an **episode** menu: its
/// buttons jump to three or more distinct *titles* rather than to chapters
/// within one. That is a second witness for `docs/tv-seasons-plan.md`'s
/// episode cluster, and — per the principle — it is only ever a warning when
/// the two disagree or a row label when they agree. It is never an input to
/// the proposal.
nonisolated enum MenuTVSignal {

    static func evaluate(_ structure: MenuStructure) -> MenuDerived.TVSignal {
        let buttons = structure.resolvedButtons()
        var perMenu: [String: Set<Int>] = [:]
        for button in buttons {
            guard let title = button.target.titleNumber else { continue }
            perMenu[button.ref.menu, default: []].insert(title)
        }
        if let (menu, titles) = perMenu.sorted(by: { $0.key < $1.key }).first(where: { $0.value.count >= 3 }) {
            return MenuDerived.TVSignal(
                value: true,
                reason: "\(menu) has \(titles.count) buttons jumping to distinct titles"
            )
        }
        return MenuDerived.TVSignal(value: false, reason: "no menu with ≥3 title-jumping buttons")
    }
}
