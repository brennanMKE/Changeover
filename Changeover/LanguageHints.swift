import Foundation

/// Menu intelligence, tier 2 — the language names a disc prints on its own
/// Languages menu (`docs/menu-intelligence.md` §5).
///
/// The problem this exists for is real and already in the corpus: Hornets'
/// Nest tags every audio stream on every title `und`, so the picker shows
/// "Track 1" and "Track 2" and the user cannot tell the Swedish original
/// from the English dub. The disc's own menu prints the answer.
///
/// **What this may and may not do.** It produces a caption and, in the one
/// shape that supports it, a per-row badge. It never changes
/// `AudioTrackOptions.preselection`, never sets a `languageCode` on an
/// untagged stream, and never merges tracks. An ordered list of names is not
/// a mapping, and this type is careful about which of the two it is holding.
nonisolated enum LanguageHints {

    /// How the menu attaches a language name to a stream, if it does at all.
    nonisolated enum Shape: String, Codable, Equatable, Sendable {
        /// Each language is a button whose command sets the stream number
        /// directly (`SetSTN`). The name is *structurally* attached to a
        /// DVD stream, so a mapping exists.
        case buttons
        /// The page prints a list and nothing more — either the buttons set
        /// a register the title's pre-commands read, or there are no
        /// per-language buttons at all. The order usually matches stream
        /// order, and "usually" is not a mapping.
        case listing
        /// No languages menu was found.
        case none
    }

    nonisolated struct Lists: Codable, Equatable, Sendable {
        var shape: Shape
        var spoken: [String]
        var subtitles: [String]
        /// DVD audio stream number → the menu's own word for it. Only ever
        /// non-empty in `.buttons` shape.
        var trackMapping: [String: String]?

        init(shape: Shape, spoken: [String], subtitles: [String], trackMapping: [String: String]? = nil) {
            self.shape = shape
            self.spoken = spoken
            self.subtitles = subtitles
            self.trackMapping = trackMapping
        }

        var isEmpty: Bool { spoken.isEmpty && subtitles.isEmpty }
    }

    // MARK: - Headings and names

    private static let spokenHeadings: Set<String> = [
        "spoken", "spoken languages", "languages", "language", "audio",
        "audio languages", "langues", "langue", "langues parlees", "audio langues",
        "idiomas", "idioma", "audio idiomas", "sprachen", "sprache", "ton",
        "lingue", "lingua", "audio lingue", "idiomas falados", "gesproken talen",
        "音声", "言語",
    ]

    private static let subtitleHeadings: Set<String> = [
        "subtitles", "subtitle", "sous-titres", "sous titres", "subtitulos",
        "untertitel", "sottotitoli", "legendas", "ondertiteling", "ondertitels",
        "字幕",
    ]

    /// Language names as menus print them — endonyms first, because that is
    /// what a disc authored in that language uses.
    private static let languageNames: Set<String> = [
        "english", "francais", "french", "espanol", "spanish", "castellano",
        "latin american spanish", "deutsch", "german", "italiano", "italian",
        "portugues", "portuguese", "nederlands", "dutch", "dansk", "danish",
        "svenska", "swedish", "norsk", "norwegian", "suomi", "finnish",
        "islenska", "icelandic", "polski", "polish", "magyar", "hungarian",
        "cestina", "czech", "slovencina", "turkce", "turkish", "romana",
        "russian", "русский", "ελληνικα", "greek", "עברית", "hebrew",
        "العربية", "arabic", "hindi", "हिन्दी", "japanese", "日本語",
        "korean", "한국어", "chinese", "中文", "mandarin", "cantonese",
        "thai", "ไทย", "quebecois", "catala", "euskara", "galego",
    ]

    /// "No subtitles" in the languages a menu is likely to print it in. Its
    /// presence is also the tell that a list is a *subtitle* list.
    private static let offNames: Set<String> = [
        "off", "none", "no subtitles", "aucun", "aucune", "sans", "ninguno",
        "ninguna", "sin subtitulos", "aus", "keine", "ohne", "nessuno",
        "nenhum", "geen", "なし", "オフ",
    ]

    static func isLanguageName(_ text: String) -> Bool {
        let key = MenuLexicon.normalize(text)
        return languageNames.contains(key) || offNames.contains(key)
    }

    // MARK: - Reading a languages still

    /// Read one languages menu's lists.
    ///
    /// Walks the still top to bottom. A heading switches the section the
    /// following names land in; anything that is not a known language name
    /// (the page title, the navigation buttons, a copyright line) is
    /// ignored. This is a closed vocabulary on purpose: an open one would
    /// turn "Main Menu" into a language on a disc whose heading OCR'd badly.
    ///
    /// `buttons` — when the capture has them — decide the *shape*: a
    /// language name sitting inside a button whose command is `SetSTN`
    /// gives a real stream mapping; anything else is a listing.
    static func lists(observations: [TextObservation], buttons: [ResolvedButton] = []) -> Lists {
        var spoken: [String] = []
        var subtitles: [String] = []
        /// No name counts until a heading has said which list it belongs
        /// to. A languages page with no readable heading yields nothing,
        /// which is the correct answer: a bare column of words could as
        /// easily be the subtitle list.
        var inSection = false
        var inSubtitles = false

        for observation in observations.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            let key = MenuLexicon.normalize(observation.text)
            if subtitleHeadings.contains(key) {
                inSection = true
                inSubtitles = true
                continue
            }
            if spokenHeadings.contains(key) {
                // A spoken heading only opens the spoken section *before*
                // the subtitle heading; "Languages" printed again as a page
                // title must never drag the subtitle list back.
                if !inSubtitles { inSection = true }
                continue
            }
            guard inSection, isLanguageName(observation.text) else { continue }
            let name = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inSubtitles {
                if !subtitles.contains(name) { subtitles.append(name) }
            } else {
                if !spoken.contains(name) { spoken.append(name) }
            }
        }

        let mapping = trackMapping(observations: observations, buttons: buttons)
        let shape: Shape
        if spoken.isEmpty && subtitles.isEmpty {
            shape = .none
        } else {
            shape = mapping.isEmpty ? .listing : .buttons
        }
        return Lists(
            shape: shape,
            spoken: spoken,
            subtitles: subtitles,
            trackMapping: mapping.isEmpty ? nil : mapping
        )
    }

    /// Shape 1 only: DVD audio stream number → the menu's word for it,
    /// built from buttons whose command is `SetSTN` and whose rectangle
    /// contains a language name.
    static func trackMapping(observations: [TextObservation], buttons: [ResolvedButton]) -> [String: String] {
        var mapping: [String: String] = [:]
        for button in buttons {
            guard case .streams(let audio, _) = button.target, let audio else { continue }
            let inside = observations
                .filter { isLanguageName($0.text) }
                .filter { $0.rect.intersectionArea(button.rect) > 0 }
                .max { $0.rect.intersectionArea(button.rect) < $1.rect.intersectionArea(button.rect) }
            guard let inside else { continue }
            mapping[String(audio)] = inside.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return mapping
    }

    /// The caption shown under the Audio heading, beside
    /// `AudioTrackOptions`' existing untagged notice. Deliberately says what
    /// the list is *not*.
    static func caption(_ lists: Lists) -> String? {
        guard !lists.spoken.isEmpty else { return nil }
        let names = lists.spoken.joined(separator: ", ")
        switch lists.shape {
        case .buttons:
            return "This disc's Languages menu lists: \(names)."
        case .listing, .none:
            return "This disc's Languages menu lists: \(names). The disc does not tag its tracks, so this is the menu's order, not a mapping."
        }
    }
}
