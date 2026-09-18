import Foundation

/// Menu intelligence, tier 2 — a search term for a disc whose volume label
/// is useless (`docs/menu-intelligence.md` §6).
///
/// `DiscNameSearchTerm.derive` returns `nil` for `DVD_VIDEO`, `UNTITLED`,
/// `NO_NAME` and the like, and nothing then prefills the search box. The
/// disc's own title card can fill that gap — at the cost of a wrong word in
/// a box the user immediately types over, which is the cheapest failure in
/// this whole document.
///
/// **The filmography trap is why the rules are this narrow.** Bloodsport
/// prints `Bloodsport (1987)` on *five* cast-and-crew pages, as a credit
/// beside `Universal Soldier (1992)` and `Kickboxer (1989)`, and prints its
/// actual logo once — where OCR reads it as `Bloodiport`. The film's own
/// title therefore appears far more often on the pages that have nothing to
/// do with playing it than on the page that does, and a rule that counted
/// recurrence would pick a Van Damme film at random. Recurrence is not
/// identity, so:
///
/// 1. only when the volume name gave nothing;
/// 2. only from **entry** menus (VMGM title, VTSM root);
/// 3. never a `Title (Year)` string from any other page;
/// 4. only the largest text that is attached to no button and is not a
///    known button word, and only if it survives `DiscNameSearchTerm`'s own
///    plausibility rules.
nonisolated enum MenuTitleGuess {

    nonisolated struct Candidate: Codable, Equatable, Sendable {
        var text: String
        var still: String
        var confidence: Float

        init(text: String, still: String, confidence: Float) {
            self.text = text
            self.still = still
            self.confidence = confidence
        }
    }

    /// One entry menu's still, with the buttons on it.
    nonisolated struct EntryStill: Equatable, Sendable {
        var id: String
        var observations: [TextObservation]
        var buttons: [PixelRect]

        init(id: String, observations: [TextObservation], buttons: [PixelRect]) {
            self.id = id
            self.observations = observations
            self.buttons = buttons
        }
    }

    /// `Title (Year)` — the filmography shape. Never a candidate, whatever
    /// page it is on; on an entry menu it would be a credit line, and on any
    /// other page it is the trap itself.
    static func looksLikeFilmographyCredit(_ text: String) -> Bool {
        guard let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else {
            return false
        }
        let inner = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        guard inner.count == 4, inner.allSatisfy(\.isNumber), let year = Int(inner) else { return false }
        return year >= 1900 && year <= 2100
    }

    /// The candidate, or `nil` when the disc offers nothing worth typing.
    ///
    /// Pure. `entryStills` must already be filtered to entry menus by the
    /// caller — this function has no way to tell a root menu from a bio page
    /// and must not guess.
    static func candidate(entryStills: [EntryStill]) -> Candidate? {
        var best: (candidate: Candidate, height: Int)?
        for still in entryStills {
            for observation in still.observations {
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // Attached to a button: that is a label, not a title.
                guard !still.buttons.contains(where: { observation.rect.intersectionArea($0) > 0 }) else { continue }
                // A word the lexicon knows is a button word even when the
                // capture has no button rectangles to prove it.
                guard !MenuLexicon.isKnownLabel(text) else { continue }
                guard !looksLikeFilmographyCredit(text) else { continue }
                guard DiscNameSearchTerm.derive(volumeName: text) != nil else { continue }
                let height = observation.rect.height
                if best == nil || height > best!.height {
                    best = (Candidate(text: text, still: still.id, confidence: observation.confidence), height)
                }
            }
        }
        return best?.candidate
    }

    /// The search term to offer, already through `DiscNameSearchTerm`'s
    /// normalisation and title-casing — or `nil` when the volume name
    /// already gave one, which always wins.
    static func searchTerm(entryStills: [EntryStill], volumeName: String) -> String? {
        guard DiscNameSearchTerm.derive(volumeName: volumeName) == nil else { return nil }
        guard let candidate = candidate(entryStills: entryStills) else { return nil }
        return DiscNameSearchTerm.derive(volumeName: candidate.text)
    }
}
