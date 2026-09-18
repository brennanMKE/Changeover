import Foundation

/// Menu intelligence, tier 2 — the static table of "this button plays the
/// film", in the languages the user's shelf actually holds
/// (`docs/menu-intelligence.md` §4.2).
///
/// This is the deterministic answer *before* any model is asked. The table
/// is seeded from the observed discs and grows only from verified archive
/// entries: a label a model proposed enters it after a human review of that
/// disc's manifest, never automatically. The model is how the table learns
/// words; the table is what makes the next disc in that language need no
/// model at all.
///
/// Matching is case-insensitive and diacritic-folded, so `LECTURE`,
/// `Lecture` and `lecture` are one entry and `Ver película` matches
/// `Ver pelicula` — which matters because OCR drops accents on stylised
/// type more often than it drops letters.
nonisolated enum MenuLexicon {

    /// Labels that mean "start the main feature", by language tag. Order is
    /// irrelevant; membership is the whole contract.
    static let playLabels: [String: [String]] = [
        "en": ["play", "play movie", "play film", "play feature", "play the movie",
               "start", "start movie", "start film", "play all", "play main feature",
               "watch movie", "watch the movie", "feature film", "main feature"],
        "fr": ["lecture", "lire le film", "lecture du film", "film", "jouer",
               "tout lire", "voir le film"],
        "es": ["reproducir", "ver pelicula", "ver la pelicula", "pelicula",
               "reproducir todo", "reproducir pelicula"],
        "de": ["film starten", "abspielen", "film abspielen", "hauptfilm",
               "alle abspielen", "film"],
        "it": ["riproduci", "riproduci film", "film", "riproduci tutto",
               "guarda il film"],
        "pt": ["reproduzir", "ver filme", "filme", "reproduzir tudo"],
        "nl": ["film afspelen", "afspelen", "speel film"],
        "ja": ["本編再生", "再生", "本編"],
    ]

    /// Every play label, in its authored spelling — what
    /// `MenuOCR.Settings.customWords` seeds Vision with.
    static let allPlayLabels: [String] = {
        var out: Set<String> = []
        for labels in playLabels.values { out.formUnion(labels) }
        // The diacritic-folded table above is for matching; give Vision the
        // accented spellings it will actually see on a disc.
        out.formUnion(["Lecture", "Ver película", "Película", "Reproducir"])
        return out.sorted()
    }()

    /// Labels that are emphatically *not* the feature, so a title-jumping
    /// button carrying one is never the play button however plausible its
    /// command looks. A trailer is a real title jump (§4.1's Bloodsport
    /// "Theatrical Trailer"), which is exactly why this list exists.
    static let nonFeatureLabels: [String: [String]] = [
        "en": ["theatrical trailer", "trailer", "trailers", "preview", "previews",
               "cast & crew", "cast and crew", "special features", "bonus features",
               "scene selections", "scene selection", "chapters", "languages",
               "language", "subtitles", "setup", "main menu", "end credits",
               "behind the scenes", "making of", "commentary", "play with commentary"],
        "fr": ["bande-annonce", "bandes-annonces", "menu principal", "langues",
               "sous-titres", "chapitres", "suppléments"],
        "es": ["trailer", "avance", "menu principal", "idiomas", "subtitulos",
               "capitulos", "extras"],
        "de": ["trailer", "hauptmenu", "sprachen", "untertitel", "kapitel", "extras"],
        "it": ["trailer", "menu principale", "lingue", "sottotitoli", "capitoli"],
        "pt": ["trailer", "menu principal", "idiomas", "legendas", "capitulos"],
        "ja": ["予告編", "特典映像", "字幕", "チャプター"],
    ]

    /// Case-insensitive, diacritic-folded, punctuation-trimmed.
    static func normalize(_ label: String) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let stripped = folded.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || scalar == "&" || scalar == "-" || scalar == "'"
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// The language tag whose play-label table this label is in, or `nil`.
    /// The tag is recorded in the archive so a review can see which
    /// languages the shelf is actually exercising.
    static func playLanguage(of label: String) -> String? {
        let key = normalize(label)
        guard !key.isEmpty else { return nil }
        for (language, labels) in playLabels.sorted(by: { $0.key < $1.key }) where labels.contains(key) {
            return language
        }
        return nil
    }

    static func isPlayLabel(_ label: String) -> Bool { playLanguage(of: label) != nil }

    static func isNonFeatureLabel(_ label: String) -> Bool {
        let key = normalize(label)
        guard !key.isEmpty else { return false }
        return nonFeatureLabels.values.contains { $0.contains(key) }
    }

    /// Any label the lexicon recognises at all — what §6 uses to keep a
    /// button word out of the search-term candidates.
    static func isKnownLabel(_ label: String) -> Bool {
        isPlayLabel(label) || isNonFeatureLabel(label)
    }
}
