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
        var highlight: Highlight?
        var buttons: [Button]
        var stills: [String]?
        var truncated: Bool?

        /// A menu the user can arrive at without pressing anything — the
        /// VMGM title menu and the VTSM root menu. The play button lives on
        /// one of these, and §6's title-text candidate may come from no
        /// other kind of page (the filmography trap).
        var isEntryMenu: Bool { entryType == "title" || entryType == "root" }

        /// The scene-selection menu and the pages it links to.
        var isChapterMenu: Bool { entryType == "chapter" }
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
    func resolvedButtons() -> [ResolvedButton] {
        menus.flatMap { menu in
            menu.buttons.map { button in
                let command = VMCommand(hex: button.command) ?? VMCommand(bytes: [0, 0, 0, 0, 0, 0, 0, 0])
                let raw = command.target(inVTS: menu.vts)
                return ResolvedButton(
                    ref: MenuButtonRef(menu: menu.id, number: button.number),
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

    /// `JumpVTS_TT` and `JumpVTS_PTT` name a title *within the title set the
    /// menu belongs to*. HandBrake numbers titles by `TT_SRPT`, so the two
    /// only agree after this lookup. Without a `titles` table (an older
    /// capture) the VTS-relative form is kept as-is rather than guessed at.
    private func lift(_ target: ButtonTarget, vts: Int?) -> ButtonTarget {
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
