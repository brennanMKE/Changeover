import Foundation

/// Menu intelligence, tier 1 + tier 2 — which of the disc's own buttons
/// starts the feature (`docs/menu-intelligence.md` §4).
///
/// **This never decides what gets encoded.** `DiscTitleHeuristic` still owns
/// that, with HandBrake's `MainFeature`, the 45-minute rule, the Play All
/// guard and the TMDB runtime cross-check. What this produces is a
/// confirmation line on the Confirm step — "the disc's Play button starts
/// title 1 — matches", or the amber form when it does not — and a second
/// independent witness in the archive. If the disc and the scan disagree,
/// the user learns something they did not have before and Start is
/// unchanged.
///
/// The resolution ladder, stopping at the first rung that answers:
///
/// 1. **Structure.** Exactly one button on an entry menu jumps to a title.
///    No text, no model, no lexicon. This is the common shape and it is
///    Bloodsport's: four root-menu buttons, one `JumpTT`.
/// 2. **One link out.** No title-jumping button on the entry menus at all,
///    so the menus one `LinkPGCN`/`JumpSS` away are considered too. Exactly
///    one indirection, never a chain — the VM is not emulated.
/// 3. **Lexicon.** Two or more candidates, and exactly one carries a label
///    the static table (`MenuLexicon`) knows.
/// 4. **Nothing.** Two or more survive: the candidates are recorded and no
///    line is shown. Tier 3 (a Foundation Models call over the labels) is a
///    later slice and only ever picks *which label to name*, never which
///    title to encode.
nonisolated enum PlayButtonResolver {

    nonisolated enum ResolvedBy: String, Codable, Equatable, Sendable {
        case structure
        /// Through one indirection into a PGC's own command table — the
        /// `LinkTailPGC` shape a real disc turned out to use.
        case pgcCommands
        case linkedMenu
        case lexicon
        case model
    }

    nonisolated struct Resolution: Codable, Equatable, Sendable {
        var menu: String
        var number: Int
        var label: String?
        /// The VMG title this button starts — directly comparable with
        /// HandBrake's title index, which is the claim `DiscCorpusTests`
        /// exists to prove disc by disc.
        var title: Int
        var resolvedBy: ResolvedBy
        /// How many title-jumping buttons were in play. `1` means the
        /// structure answered on its own.
        var candidates: Int

        init(menu: String, number: Int, label: String?, title: Int, resolvedBy: ResolvedBy, candidates: Int) {
            self.menu = menu
            self.number = number
            self.label = label
            self.title = title
            self.resolvedBy = resolvedBy
            self.candidates = candidates
        }
    }

    /// The title a button starts, following at most **one** indirection.
    ///
    /// Most of the discs this was designed against were assumed to put a
    /// bare `JumpTT` on the play button. The first real disc does not:
    /// Bloodsport's Play Movie is a `LinkTailPGC`, which runs its own PGC's
    /// post-commands, and those end with `JumpVTS_TT 1`. So a button
    /// resolves to a title when
    ///
    /// * its own command is a title jump; or
    /// * it links to the tail/top of its **own** PGC, whose commands hold
    ///   exactly one title jump; or
    /// * it links to **another** PGC whose commands hold exactly one.
    ///
    /// One step, never a chain, and never a conditional command — those are
    /// recorded and left alone.
    static func title(of button: ResolvedButton, in structure: MenuStructure) -> Int? {
        if let direct = button.target.titleNumber { return direct }
        guard let menu = structure.menus.first(where: { $0.id == button.ref.menu }) else { return nil }

        switch button.target {
        case .unresolved(let mnemonic) where mnemonic.hasPrefix("Link"):
            // LinkTailPGC / LinkTopPGC and friends stay inside this PGC.
            return structure.soleTitleJump(of: menu)
        case .menu(let ref):
            guard let pgc = ref.pgc,
                  let destination = structure.menu(withPGC: pgc, inVTS: ref.vts ?? menu.vts, domain: ref.domain)
            else { return nil }
            return structure.soleTitleJump(of: destination)
        default:
            return nil
        }
    }

    /// Every button that could be the play button, before any tie-break.
    static func titleJumpingButtons(
        _ structure: MenuStructure,
        includingLinkedMenus: Bool = false
    ) -> [ResolvedButton] {
        let all = structure.resolvedButtons()
        let onEntry = all.filter { $0.onEntryMenu && title(of: $0, in: structure) != nil }
        guard onEntry.isEmpty, includingLinkedMenus else { return onEntry }

        // One indirection: the menus an entry menu links to.
        let linked: Set<String> = Set(
            all.filter(\.onEntryMenu).compactMap { button -> String? in
                guard case .menu(let ref) = button.target, let pgc = ref.pgc else { return nil }
                return structure.menus.first { $0.pgc == pgc && $0.domain == (ref.domain ?? $0.domain) }?.id
            }
        )
        return all.filter { linked.contains($0.ref.menu) && title(of: $0, in: structure) != nil }
    }

    /// Resolve, with whatever labels OCR attached to the buttons.
    ///
    /// `labels` is keyed by button so a caption can be absent without
    /// changing the structural answer — a picture-only menu still resolves
    /// through rung 1 and the app says "the Play button" instead of naming
    /// it.
    static func resolve(
        _ structure: MenuStructure,
        labels: [MenuButtonRef: String] = [:]
    ) -> Resolution? {
        var candidates = titleJumpingButtons(structure)
        var rung: ResolvedBy = .structure
        if candidates.isEmpty {
            candidates = titleJumpingButtons(structure, includingLinkedMenus: true)
            rung = .linkedMenu
        }
        guard !candidates.isEmpty else { return nil }

        // A button the lexicon knows is *not* the feature — "Theatrical
        // Trailer", "Cast & Crew" — is never the play button however real
        // its title jump is. Bloodsport's trailer is exactly this shape.
        let plausible = candidates.filter { button in
            guard let label = labels[button.ref] else { return true }
            return !MenuLexicon.isNonFeatureLabel(label)
        }
        let pool = plausible.isEmpty ? candidates : plausible

        if pool.count == 1, let only = pool.first, let title = title(of: only, in: structure) {
            return Resolution(
                menu: only.ref.menu,
                number: only.ref.number,
                label: labels[only.ref],
                title: title,
                resolvedBy: only.target.titleNumber == nil ? .pgcCommands : rung,
                candidates: pool.count
            )
        }

        // Two or more buttons that target the *same* title collapse: "Play"
        // and "Play with commentary" differ only by a SetSTN, and the VMGM
        // title menu often duplicates the VTSM root menu's play button. The
        // confirmation line is the same either way, so the only question is
        // which button to *name* — a lexicon hit first, so the caption reads
        // "Play Movie" rather than going unlabelled.
        let titles = Set(pool.compactMap { title(of: $0, in: structure) })
        if titles.count == 1, let title = titles.first {
            let named = pool.first { labels[$0.ref].map(MenuLexicon.isPlayLabel) ?? false }
            let chosen = named ?? pool.first { labels[$0.ref] != nil } ?? pool[0]
            return Resolution(
                menu: chosen.ref.menu,
                number: chosen.ref.number,
                label: labels[chosen.ref],
                title: title,
                resolvedBy: chosen.target.titleNumber == nil ? .pgcCommands : rung,
                candidates: pool.count
            )
        }

        let lexiconHits = pool.filter { button in
            guard let label = labels[button.ref] else { return false }
            return MenuLexicon.isPlayLabel(label)
        }
        if lexiconHits.count == 1, let only = lexiconHits.first, let title = title(of: only, in: structure) {
            return Resolution(
                menu: only.ref.menu,
                number: only.ref.number,
                label: labels[only.ref],
                title: title,
                resolvedBy: .lexicon,
                candidates: pool.count
            )
        }

        return nil
    }

    /// How much of an observation must lie inside a button rectangle before
    /// it counts as that button's label. Measured on Bloodsport's root
    /// menu: the four real labels are 96-100% inside, the title card clips
    /// the top button by 3%. Half is comfortably between the two.
    static let insideButtonFraction = 0.5

    /// Attach OCR text to buttons by geometry (§4.2).
    ///
    /// The observation with the largest intersection wins; failing any
    /// intersection, the nearest observation whose centre is within half a
    /// button height of the rectangle. **Text inside no button is
    /// decoration** — a filmography line, a copyright notice, a logo — and
    /// is never a label.
    static func labels(
        buttons: [ResolvedButton],
        observations: [TextObservation]
    ) -> [MenuButtonRef: String] {
        var out: [MenuButtonRef: String] = [:]
        for button in buttons {
            if let overlapping = observations
                .filter({ button.rect.containsFraction(of: $0.rect) >= Self.insideButtonFraction })
                .max(by: { $0.rect.intersectionArea(button.rect) < $1.rect.intersectionArea(button.rect) }) {
                out[button.ref] = overlapping.text.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            let reach = Double(max(button.rect.height, 1)) / 2
            let nearest = observations
                .filter { observation in
                    abs(observation.rect.midY - button.rect.midY) <= reach
                        && observation.rect.horizontalOverlapFraction(button.rect) > 0
                }
                .min { lhs, rhs in
                    abs(lhs.rect.midY - button.rect.midY) < abs(rhs.rect.midY - button.rect.midY)
                }
            if let nearest {
                out[button.ref] = nearest.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    /// The Confirm-step line, or `nil` when there is nothing to say.
    ///
    /// Three forms, exactly as §4.1 spells them, and all three are captions:
    /// none of them changes what Start does.
    static func confirmationLine(_ resolution: Resolution?, scanFeatureTitle: Int?) -> String? {
        guard let resolution else { return nil }
        let subject = resolution.label.map { "\"\($0)\"" } ?? "the Play button"
        guard let scanFeatureTitle else {
            return "Disc menu: \(subject) starts title \(resolution.title)."
        }
        if resolution.title == scanFeatureTitle {
            return "Disc menu: \(subject) starts title \(resolution.title) — matches."
        }
        return "Disc menu: \(subject) starts title \(resolution.title); the scan chose title \(scanFeatureTitle)."
    }
}
