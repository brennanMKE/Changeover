import Foundation

/// What the disc in the drive can **supply** to a file that is already in the
/// library (`docs/menu-intelligence.md` §7.3).
///
/// The other half of `LibraryFileGaps`. That one is answerable from the
/// library alone; this one needs the disc, because the names come off its own
/// scene-selection pages and the language words off its own Languages page.
/// Splitting them this way is what lets a future library sweep list what every
/// file is missing with no disc present, and resolve only the matched disc's
/// offer when one is inserted.
///
/// Everything here is already-gated menu output — `MenuIntelligence` has
/// applied `ChapterNames`' attachment rules and `LanguageHints`' heading rules
/// before this value exists. Nothing new is read from the disc here.
nonisolated struct DiscUpgradeOffer: Equatable, Sendable, Codable {

    /// The disc's chapter names, one row per chapter it named. **Not** yet
    /// checked against the file: the count equality is `UpgradeProposal`'s
    /// job, because only the file knows how many chapters it has.
    var chapterNames: [MarkerRow]

    /// The Languages page's own words. `.buttons` shape carries a real
    /// per-stream mapping; `.listing` carries an ordered list and nothing
    /// more, which is a caption and never an assignment (§5.2).
    var languages: LanguageHints.Lists?

    var isEmpty: Bool { chapterNames.isEmpty && (languages?.isEmpty ?? true) }

    init(chapterNames: [MarkerRow] = [], languages: LanguageHints.Lists? = nil) {
        self.chapterNames = chapterNames
        self.languages = languages
    }

    /// What one finished menu read offers.
    ///
    /// The chapter names are taken from the raw candidates, **not** from
    /// `markerPlan`: that decision was made against the count of the title
    /// being *encoded*, and an upgrade is checked against the count of the
    /// file already in the library, which is a different number on exactly the
    /// disc this feature exists for (Oppenheimer: 21 on the disc, 20 in the
    /// file). Refusing here would hide the mismatch instead of stating it.
    static func make(menu: MenuIntelligence) -> DiscUpgradeOffer {
        var rows: [MarkerRow] = []
        var seen = Set<Int>()
        for candidate in menu.chapterNames.sorted(by: { $0.chapter < $1.chapter }) {
            // §3.2 rule 4: a candidate whose printed number disagrees with its
            // button's own target is dropped here exactly as it is dropped
            // from the encode's CSV. It stays in the archive either way.
            guard !candidate.disputed else { continue }
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, candidate.chapter >= 1, seen.insert(candidate.chapter).inserted else { continue }
            rows.append(MarkerRow(number: candidate.chapter, name: name))
        }
        return DiscUpgradeOffer(chapterNames: rows, languages: menu.languages)
    }

    /// The disc's per-track language mapping, as `(track, word)` pairs in
    /// track order — only ever non-empty in `.buttons` shape. The keys the
    /// helper writes are DVD audio stream numbers as strings; they are read
    /// back as 0-based track indices, which is what `-metadata:s:a:<n>`
    /// addresses and what `AudioSummary.track` is.
    var audioMapping: [(track: Int, word: String)] {
        guard let languages, languages.shape == .buttons, let mapping = languages.trackMapping else { return [] }
        return mapping
            .compactMap { key, value -> (track: Int, word: String)? in
                guard let track = Int(key) else { return nil }
                let word = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { return nil }
                return (track: track, word: word)
            }
            .sorted { $0.track < $1.track }
    }
}
