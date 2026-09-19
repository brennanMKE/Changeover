import Foundation

/// Menu intelligence, tier 1 — the decoded shape of a DVD's menu domain.
///
/// This is the Swift side of `Tools/menudump`'s `structure.json`
/// (`docs/menu-intelligence.md` §8.3). The helper does no interpretation: it
/// copies the IFO tables and the NAV packs' button rectangles and raw 8-byte
/// VM commands out of the disc and writes them as text. Everything that
/// *means* something — which button starts which title, which menu is the
/// chapter menu — is decided here, by pure functions a test can pin against
/// the recorded bytes.
///
/// **Enrichment only.** Nothing in this file may feed `DiscTitleHeuristic`,
/// `EncodeSelection` or `StartGate`. A disc with no menus, a host with no
/// `libdvdread`, a helper that crashed — all produce "no menu data" and the
/// rip is byte-identical to what it is today.

// MARK: - Geometry

/// A rectangle on the menu frame, in **pixels with a top-left origin** —
/// the DVD's own convention for button rectangles (`x_start`…`y_end` in the
/// NAV pack's highlight information).
///
/// Vision reports normalised boxes with a *bottom-left* origin, so
/// `MenuOCR` flips them once on the way in (`PixelRect(visionBox:frame:)`).
/// Both halves of the geometry — buttons and text — are therefore in one
/// space, which is the whole reason a caption can be attached to a button
/// at all.
///
/// Encoded as `[minX, minY, maxX, maxY]` so `structure.json` and `ocr.json`
/// stay readable in a diff.
nonisolated struct PixelRect: Codable, Equatable, Hashable, Sendable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    var width: Int { max(0, maxX - minX) }
    var height: Int { max(0, maxY - minY) }
    var midX: Double { Double(minX + maxX) / 2 }
    var midY: Double { Double(minY + maxY) / 2 }
    var isEmpty: Bool { width == 0 || height == 0 }

    func contains(x: Double) -> Bool { x >= Double(minX) && x <= Double(maxX) }

    func intersectionArea(_ other: PixelRect) -> Int {
        let w = min(maxX, other.maxX) - max(minX, other.minX)
        let h = min(maxY, other.maxY) - max(minY, other.minY)
        guard w > 0, h > 0 else { return 0 }
        return w * h
    }

    /// How much of `other` lies inside this rectangle, 0...1 — "is this
    /// text inside that button?"
    ///
    /// A bare "do they touch at all" test is not enough, and the measured
    /// disc says by how much: on Bloodsport's root menu the four real
    /// labels lie 96-100% inside their buttons, while the title card clips
    /// the top button by 3% and is not a label at all. Anything in between
    /// separates them; the threshold used is 50%.
    func containsFraction(of other: PixelRect) -> Double {
        let area = other.width * other.height
        guard area > 0 else { return 0 }
        return Double(intersectionArea(other)) / Double(area)
    }

    /// The horizontal overlap of two rects as a fraction of the narrower
    /// one — how the chapter-caption attachment decides "this continuation
    /// sits under that column".
    func horizontalOverlapFraction(_ other: PixelRect) -> Double {
        let overlap = min(maxX, other.maxX) - max(minX, other.minX)
        guard overlap > 0 else { return 0 }
        let narrower = min(width, other.width)
        guard narrower > 0 else { return 0 }
        return Double(overlap) / Double(narrower)
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        minX = try container.decode(Int.self)
        minY = try container.decode(Int.self)
        maxX = try container.decode(Int.self)
        maxY = try container.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(minX)
        try container.encode(minY)
        try container.encode(maxX)
        try container.encode(maxY)
    }
}

// MARK: - The structure document

/// `menus/structure.json`, format `changeover-menu-structure/1`.
nonisolated struct MenuStructure: Codable, Equatable, Sendable {

    /// The helper's own report on what it could and could not use. Under the
    /// project's dependency rule (nothing Homebrew-installable is bundled),
    /// this is the machine-readable half of "why is there no menu data" —
    /// the app's Settings panel reads `missing` and shows the `brew install`
    /// line rather than guessing.
    nonisolated struct Helper: Codable, Equatable, Sendable {
        var name: String
        var version: String
        /// `"available"` when the menu video could be decrypted,
        /// `"unavailable"` when it could not. Tier 1 (buttons, targets,
        /// chapter counts) does not need it: NAV packs are never scrambled.
        var css: String?
        var libdvdread: String?
        /// Formula names the host is missing, e.g. `["libdvdcss"]`.
        var missing: [String]?
        /// The exact command that fixes `missing`, for the Settings panel.
        var install: [String]?
    }

    nonisolated struct Frame: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
        var standard: String?
    }

    /// One row of the VMG's `TT_SRPT` — the table that makes a `JumpTT`
    /// number mean the same thing HandBrake's title index means.
    nonisolated struct TitleEntry: Codable, Equatable, Sendable {
        var title: Int
        var vts: Int
        var vtsTTN: Int
        var ptts: Int
        var angles: Int?
    }

    nonisolated struct Cell: Codable, Equatable, Sendable {
        var firstSector: Int
        var lastSector: Int
        var durationMS: Int?
    }

    nonisolated struct Highlight: Codable, Equatable, Sendable {
        var start: Int?
        var buttons: Int
        var forcedSelect: Int?
    }

    /// What the helper found when it went looking for this menu's NAV pack,
    /// and how it checked itself.
    ///
    /// This block exists because the first version of the helper reported
    /// `"buttons": []` for all 29 menu PGCs of a disc carrying 151 NAV packs
    /// full of buttons, and said nothing whatever about why. An empty result
    /// with no cause is indistinguishable from a disc that genuinely has no
    /// buttons, and that is the shape of failure this whole design is
    /// supposed to make impossible. So every absence now names its reason,
    /// and the reader publishes its own self-checks beside the data.
    ///
    /// `lbnMatches` is the one check that is independent of the reader's
    /// own assumptions: `pci_gi.nv_pck_lbn` is the sector address the *disc*
    /// wrote into the pack, and it is compared with the sector the helper
    /// asked the IFO for. If the PCI data offset were wrong by even four
    /// bytes — which is exactly the bug that was here — the number read back
    /// would not be the sector number.
    nonisolated struct Nav: Codable, Equatable, Sendable {
        var sector: Int?
        /// Where the `00 00 01 BF` start code was found. `-1` if no PCI
        /// packet was located. Not a constant: the pack header may carry
        /// stuffing and the system header is optional.
        var pciOffset: Int?
        var lbn: Int?
        var lbnMatches: Bool?
        /// `hl_gi.btn_ns` — the button count **per group**, not the total.
        var buttonsPerGroup: Int?
        /// `btngr1/2/3_dsp_ty`: bit 0 4:3, bit 1 wide, bit 2 letterbox.
        var groupDisplayTypes: [Int]?
        /// Whether every button group carries the same commands. Groups are
        /// the same buttons laid out for different display aspects, so this
        /// should always be true; a disc where it is not means taking group
        /// 1 has lost something, and the archive says so.
        var groupsAgree: Bool?
        var rectsInsideFrame: Bool?
        var error: String?
    }

    nonisolated struct Commands: Codable, Equatable, Sendable {
        var pre: [String]?
        var post: [String]?
        var cell: [String]?

        /// Post first: a `LinkTailPGC` runs the post-commands, and that is
        /// the shape the measured disc uses.
        var all: [String] { (post ?? []) + (pre ?? []) + (cell ?? []) }
    }

    nonisolated struct Button: Codable, Equatable, Sendable {
        var number: Int
        var rect: PixelRect
        var autoAction: Bool
        /// The raw 8 bytes as 16 hex characters. Never lost, never
        /// interpreted by the helper — `VMCommand.decode` is the only
        /// thing that reads it, and every test pins exactly these strings.
        var command: String
        var up: Int?
        var down: Int?
        var left: Int?
        var right: Int?
    }

    /// One cell of a menu PGC, with the buttons that cell's own NAV pack
    /// carries.
    ///
    /// A multi-page scene index is not several menus — it is one PGC whose
    /// pages are its successive cells, and the "5-8"…"17-20" buttons are
    /// cell-less PGCs that set a register and link back into it. Oppenheimer's
    /// CHAPTERS menu is `pgc19` with five cells addressing chapters 1-4, 5-8,
    /// 9-12, 13-16 and 17-20. `Menu.buttons` is cell 0 alone, so a reader that
    /// stops there sees four chapters on a disc offering twenty, and
    /// `ChapterNames.markers` then discards the whole set for naming fewer
    /// than half of them.
    ///
    /// `still` is the id of the frame this page was rendered to, which is
    /// what an OCR document keys its observations by — so a name found on
    /// page 3 is paired with page 3's button rectangles and no other's.
    nonisolated struct Page: Codable, Equatable, Sendable {
        /// 1-based, as a viewer would count pages.
        var cell: Int
        var still: String
        /// Whether a frame was actually written for this cell. False when
        /// the byte budget ran out or `libdvdcss` was missing — the buttons
        /// are still here, there is just no picture to OCR.
        var rendered: Bool?
        var nav: Nav?
        var buttons: [Button]
    }

    nonisolated struct Menu: Codable, Equatable, Sendable {
        var id: String
        /// `"VMGM"` or `"VTSM"`.
        var domain: String
        var vts: Int?
        var languageUnit: Int
        var languageCode: String?
        var pgc: Int
        /// `title`, `root`, `subpicture`, `audio`, `angle`, `chapter`, `none`.
        var entryType: String
        var cells: [Cell]?
        var reachableFrom: [String]?
        var buttonGroups: Int?
        /// The PGC's own pre-, post- and cell-command tables, as raw hex.
        /// A `LinkTailPGC` button runs the post-commands, which is how
        /// Bloodsport's Play Movie button reaches its title — without this
        /// the disc's own answer to "which title is the feature" cannot be
        /// read at all.
        var commands: Commands?
        var nav: Nav?
        var highlight: Highlight?
        var buttons: [Button]
        /// Every cell's buttons, cell 0 included. Absent in a capture made
        /// before the helper read past the first cell, which is why
        /// `buttonPages` falls back to `buttons` rather than treating a
        /// missing array as a menu with no buttons.
        var pages: [Page]?
        var stills: [String]?
        var truncated: Bool?

        /// A menu the user can arrive at without pressing anything — the
        /// VMGM title menu and the VTSM root menu. The play button lives on
        /// one of these, and §6's title-text candidate may come from no
        /// other kind of page (the filmography trap).
        var isEntryMenu: Bool { entryType == "title" || entryType == "root" }

        /// The scene-selection menu and the pages it links to.
        var isChapterMenu: Bool { entryType == "chapter" }

        /// The stills rendered from this menu, or — when none were (no
        /// libdvdcss, or a structure read without cell dumping) — the menu's
        /// own id, which is what `Tools/menudump` names its stills after.
        var stillIDs: [String] {
            let rendered = stills ?? []
            return rendered.isEmpty ? [id] : rendered
        }

        /// This menu has video the helper could have read a NAV pack from.
        /// A menu with cells and no buttons is a claim that wants checking;
        /// a menu with no cells has nothing to read and is not evidence of
        /// anything.
        var hasCells: Bool { !(cells ?? []).isEmpty }

        /// The menu's pages, as `(stillID, buttons)` — one per cell that
        /// carries a button table.
        ///
        /// An older capture has no `pages`, so its single button table is
        /// reported as one page keyed by the menu's own id. That is exactly
        /// what cell 0's page is called, so every consumer reads one shape
        /// and a re-capture changes only how many pages come back.
        var buttonPages: [(still: String, buttons: [Button])] {
            guard let pages, !pages.isEmpty else {
                return buttons.isEmpty ? [] : [(id, buttons)]
            }
            return pages.map { ($0.still, $0.buttons) }
        }
    }

    var format: String
    var helper: Helper?
    var capturedAt: String?
    var frame: Frame?
    var titles: [TitleEntry]?
    var menus: [Menu]

    static func decode(_ data: Data) throws -> MenuStructure {
        try JSONDecoder().decode(MenuStructure.self, from: data)
    }
}

// MARK: - Button references and resolved targets

/// Identifies one button on one menu, so a label, a target and an OCR
/// observation can all name the same thing without carrying the menu around.
nonisolated struct MenuButtonRef: Codable, Equatable, Hashable, Sendable {
    var menu: String
    var number: Int
}

/// A button with its command decoded and, where the VMG title table allows
/// it, its VTS-relative target lifted into HandBrake's numbering.
nonisolated struct ResolvedButton: Equatable, Sendable {
    var ref: MenuButtonRef
    var rect: PixelRect
    var autoAction: Bool
    var command: VMCommand
    var target: ButtonTarget
    /// `true` when this button sits on a VMGM title menu or a VTSM root
    /// menu — the only menus §4.1 lets a play button come from.
    var onEntryMenu: Bool
    var entryType: String
}

extension MenuStructure {

    /// Decode every button on every menu, resolving VTS-relative jumps to
    /// VMG title numbers through `titles` (the `TT_SRPT` table) where it is
    /// present.
    ///
    /// Pure. A button whose command this build cannot name comes back
    /// `.unresolved(mnemonic:)` with its mnemonic, never dropped — §8.6's
    /// sweep counts them so a decoder regression is visible and a disc with
    /// genuinely opaque authoring stays honest.
    /// Every button of every **page** of every menu.
    ///
    /// `ref.menu` is the page's still id, not the menu's — they are the same
    /// string for cell 0, so nothing that resolved a play button before sees
    /// a different answer, while page 2 upward becomes addressable at all.
    /// Pairing a name with a button is a per-frame job, and the still id is
    /// what an OCR document keys its observations by.
    func resolvedButtons() -> [ResolvedButton] {
        menus.flatMap { menu in
            menu.buttonPages.flatMap { page in
                page.buttons.map { button in
                    let command = VMCommand(hex: button.command) ?? VMCommand(bytes: [0, 0, 0, 0, 0, 0, 0, 0])
                    let raw = command.target(inVTS: menu.vts)
                    return ResolvedButton(
                        ref: MenuButtonRef(menu: page.still, number: button.number),
                        rect: button.rect,
                        autoAction: button.autoAction,
                        command: command,
                        target: lift(raw, vts: menu.vts),
                        onEntryMenu: menu.isEntryMenu,
                        entryType: menu.entryType
                    )
                }
            }
        }
    }

    /// The scene-selection pages: menus whose buttons address chapters.
    ///
    /// **Entry type is not enough.** The design assumed the chapter menu is
    /// the PGC with entry type 0x86, but on the measured disc only the root
    /// menu is an entry PGC at all — its four scene pages are plain PGCs
    /// reached by `LinkPGCN`, so a rule keyed on entry type finds nothing
    /// and reads no chapter names. What actually identifies a scene page is
    /// what its buttons do: two or more of them jump to chapters.
    func chapterMenus() -> [Menu] {
        let qualifying = chapterPageIDs()
        return menus
            .filter { menu in menu.buttonPages.contains { qualifying.contains($0.still) } }
            .sorted { ($0.vts ?? 0, $0.pgc) < ($1.vts ?? 0, $1.pgc) }
    }

    /// The still ids of the scene pages — the granularity the names are
    /// actually read at.
    ///
    /// A five-page scene index is one menu, so `chapterMenus()` can only say
    /// "this menu is a scene index". Which *frame* a caption was printed on
    /// is what pairing needs, and each page carries its own two or more
    /// chapter-jumping buttons, so the test applies per page unchanged.
    func chapterPageIDs() -> Set<String> {
        let chapterButtons = Dictionary(
            grouping: resolvedButtons().filter { if case .chapter = $0.target { return true } else { return false } },
            by: { $0.ref.menu }
        )
        return Set(chapterButtons.filter { $0.value.count >= 2 }.keys)
    }

    /// The single title this menu PGC's own commands jump to, if there is
    /// exactly one.
    ///
    /// This is §4.1's **one** indirection and no more. A real disc's play
    /// button is often not a `JumpTT` at all: Bloodsport's is a
    /// `LinkTailPGC`, which means "run this PGC's post-commands", and those
    /// end with `JumpVTS_TT 1`. Following that one step is the difference
    /// between reading the disc's own answer and reading nothing.
    ///
    /// Conditional commands are skipped, not evaluated — their destination
    /// depends on registers this code does not model — and "exactly one"
    /// is required, so a PGC that branches to two titles resolves to
    /// neither. The VM is never emulated and chains are never followed.
    func soleTitleJump(of menu: Menu) -> Int? {
        let titles = Set(
            (menu.commands?.all ?? [])
                .compactMap { VMCommand(hex: $0) }
                .filter { !$0.isConditional }
                .map { lift($0.target(inVTS: menu.vts), vts: menu.vts) }
                .compactMap(\.titleNumber)
        )
        return titles.count == 1 ? titles.first : nil
    }

    func menu(withPGC pgc: Int, inVTS vts: Int?, domain: String?) -> Menu? {
        menus.first { candidate in
            candidate.pgc == pgc
                && candidate.vts == vts
                && (domain == nil || candidate.domain == domain)
        }
    }

    /// `JumpVTS_TT` and `JumpVTS_PTT` name a title *within the title set the
    /// menu belongs to*. HandBrake numbers titles by `TT_SRPT`, so the two
    /// only agree after this lookup. Without a `titles` table (an older
    /// capture) the VTS-relative form is kept as-is rather than guessed at.
    func lift(_ target: ButtonTarget, vts: Int?) -> ButtonTarget {
        guard let vts, let titles else { return target }
        func vmgTitle(forTTN ttn: Int) -> Int? {
            titles.first { $0.vts == vts && $0.vtsTTN == ttn }?.title
        }
        switch target {
        case .titleInVTS(let entryVTS, let ttn) where entryVTS == vts:
            if let title = vmgTitle(forTTN: ttn) { return .title(title) }
            return target
        case .chapterInVTS(let entryVTS, let ttn, let ptt) where entryVTS == vts:
            if let title = vmgTitle(forTTN: ttn) { return .chapter(title: title, ptt: ptt) }
            return target
        default:
            return target
        }
    }
}
