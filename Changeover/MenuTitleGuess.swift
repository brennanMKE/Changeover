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

    /// Cards a disc prints that are about the *disc*, not the film: the
    /// caption house, the audio licensor, the region warning. They sit on
    /// entry menus in large type with no button attached, which is exactly
    /// the shape this looks for, so without this list they win.
    ///
    /// Enemy at the Gates is the disc that proved it. Every one of its entry
    /// menus is a colour-bar or black leader with no text on it at all,
    /// except one carrying the closed-caption card — so the field of
    /// candidates was a field of one, and "CAPTIONS, INC. LOS ANGELES" was
    /// duly offered as the film's title.
    private static let nonTitlePhrases: [String] = [
        "captions, inc", "caption center", "closed captioned", "cc",
        "for the hearing impaired", "subtitled for the",
        "dolby", "dts", "thx", "digital surround",
        "this player is incompatible", "region", "all rights reserved",
        "the contents of this video", "interpol", "fbi warning",
        "distributed by", "manufactured", "uphe.com",
    ]

    /// Whether this line is about the disc rather than the film.
    static func isNonTitleCard(_ text: String) -> Bool {
        let folded = text.lowercased()
        return nonTitlePhrases.contains { folded.contains($0) }
    }

    /// Bonus features are named after the film: "Inside Enemy at the Gates",
    /// "The Making of Alien". The prefix is the giveaway, and what follows it
    /// is the title — so a disc whose own title card is unreadable can still
    /// say what it is, from the special-features page.
    ///
    /// Narrow on purpose. Only these openers, only when something substantial
    /// follows, and the result still has to pass every rule a title card's
    /// text does. It ranks **below** a real title card and is never consulted
    /// while one is available.
    /// Each opener with the shortest remainder it will accept.
    ///
    /// "The Making of Alien" is unambiguous at one word — nothing else on a
    /// menu reads like that. "Inside" is not: it is an ordinary English word
    /// and a film called *Inside Out* would otherwise be offered as "Out". So
    /// the vaguer the opener, the more has to follow it.
    private static let featurettePrefixes: [(prefix: String, minimumWords: Int)] = [
        ("the making of the ", 1),
        ("behind the scenes of ", 1),
        ("the making of ", 1),
        ("making of ", 1),
        ("inside ", 2),
    ]

    /// The film's name lifted out of a bonus feature's name, or `nil`.
    static func titleInsideFeaturette(_ text: String) -> String? {
        // Menus decorate their rows with bullets and asterisks; strip those
        // before matching, or "* INSIDE ENEMY AT THE GATES" never matches.
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "*• \t"))
        let folded = stripped.lowercased()
        // Longest opener first, so "the making of the " is not matched as
        // "the making of " and made to yield a title beginning "the".
        for (prefix, minimumWords) in featurettePrefixes.sorted(by: { $0.prefix.count > $1.prefix.count }) {
            guard folded.hasPrefix(prefix) else { continue }
            let remainder = String(stripped.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard remainder.split(separator: " ").count >= minimumWords else { return nil }
            guard !isNonTitleCard(remainder) else { return nil }
            return remainder
        }
        return nil
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
                // Attached to a button: that is a label, not a title. The
                // test is how much of the text lies inside — Bloodsport's
                // title card clips the top button by 3% and would otherwise
                // be thrown away as a label, which is the one thing on the
                // page this rule exists to find.
                guard !still.buttons.contains(where: {
                    $0.containsFraction(of: observation.rect) >= PlayButtonResolver.insideButtonFraction
                }) else { continue }
                // A word the lexicon knows is a button word even when the
                // capture has no button rectangles to prove it.
                guard !MenuLexicon.isKnownLabel(text) else { continue }
                guard !looksLikeFilmographyCredit(text) else { continue }
                guard !isNonTitleCard(text) else { continue }
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

extension MenuTitleGuess {

    /// The title lifted from a bonus feature's name, searched across every
    /// still rather than only the entry menus.
    ///
    /// Reaching past the entry menus is what the filmography trap warns
    /// against, so this is allowed only because the shape is so much
    /// narrower: a line has to begin "Inside", "The Making of" or "Behind the
    /// Scenes of" *and* the remainder has to survive every rule a title card's
    /// text does. A cast page's credits match none of that.
    ///
    /// Ties break on the tallest text, as the entry-menu rule does.
    static func featuretteCandidate(stills: [MenuOCRDocument.Still]) -> Candidate? {
        var best: (candidate: Candidate, height: Int)?
        for still in stills {
            for observation in still.observations {
                guard let title = titleInsideFeaturette(observation.text) else { continue }
                guard !looksLikeFilmographyCredit(title) else { continue }
                guard let term = DiscNameSearchTerm.derive(volumeName: title) else { continue }
                let height = observation.rect.height
                if best == nil || height > best!.height {
                    best = (Candidate(text: term, still: still.id, confidence: observation.confidence), height)
                }
            }
        }
        return best?.candidate
    }
}
