import Foundation

/// Menu intelligence, tier 2 — **the one table of button words**
/// (`docs/menu-intelligence.md` §4.2).
///
/// Everything that needs to know what a DVD button's caption means reads
/// `entries` and nothing else: `PlayButtonResolver`'s lexicon rung, the
/// gate that decides whether `MenuJudge` is asked at all, `MenuOCR`'s
/// `customWords`, `MenuTitleGuess`'s "that word is a button, not a title",
/// and the archive's vocabulary column. Before this file was a table the
/// same words were spelled out in three places and had already drifted —
/// `MenuOCR` was seeding Vision with "Continue" and "Main Menu" that the
/// matcher had never heard of.
///
/// **Adding a disc's vocabulary is adding rows.** A capture whose review
/// turns up a label the table does not know (the report in
/// `MenuAgreementReport` prints them under "unknown to the lexicon") is
/// absorbed by appending an `Entry` with the language it is in, what it
/// does, and the disc slug it was read off. No function below changes, and
/// nothing about the rip changes: the whole table only ever decides which
/// *caption* to show.
///
/// Matching is case-insensitive and diacritic-folded, so `LECTURE`,
/// `Lecture` and `lecture` are one entry and `Ver película` matches
/// `Ver pelicula` — which matters because OCR drops accents on stylised
/// type more often than it drops letters. Rows therefore carry the
/// **authored** spelling (what is printed on the disc, accents and all);
/// folding happens once, here.
nonisolated enum MenuLexicon {

    /// What a button with this caption does. Only two answers matter to any
    /// caller: "this one starts the film" and "this one emphatically does
    /// not, however real its title jump looks".
    nonisolated enum Role: String, Codable, Equatable, Sendable, CaseIterable {
        /// Starts the main feature.
        case play
        /// A real button that is never the feature — a trailer, a scene
        /// index, a language page, a navigation word.
        case nonFeature
    }

    /// One button word, as it is printed on a disc.
    nonisolated struct Entry: Equatable, Sendable {
        /// The authored spelling, accents included.
        var text: String
        /// BCP-47-ish language tag. `playLanguage(of:)` reports it so a
        /// review can see which languages the shelf is actually exercising.
        var language: String
        var role: Role
        /// Corpus slugs this exact caption has been OCR'd off, or empty for
        /// a word seeded from the design rather than from a disc. This is
        /// the provenance column the archive review reads: a row with no
        /// disc behind it is a guess, and the report says so.
        var seenOn: [String]

        init(_ text: String, _ language: String, _ role: Role, seenOn: [String] = []) {
            self.text = text
            self.language = language
            self.role = role
            self.seenOn = seenOn
        }

        /// The folded key this row matches on.
        var key: String { MenuLexicon.normalize(text) }
    }

    // MARK: - The table

    /// The whole lexicon. Rows only; no logic. Sorted by language then role
    /// then text so a new word lands in an obvious place in a diff.
    static let entries: [Entry] = [

        // ---- English
        .init("Play", "en", .play),
        .init("Play Movie", "en", .play, seenOn: ["bloodsport"]),
        .init("Play Film", "en", .play),
        .init("Play Feature", "en", .play),
        .init("Play the Movie", "en", .play),
        .init("Play Main Feature", "en", .play),
        .init("Play All", "en", .play),
        .init("Start", "en", .play),
        .init("Start Movie", "en", .play, seenOn: ["bloodsport"]),
        .init("Start Film", "en", .play),
        .init("Watch Movie", "en", .play),
        .init("Watch the Movie", "en", .play),
        .init("Feature Film", "en", .play),
        .init("Main Feature", "en", .play),

        .init("Theatrical Trailer", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("Trailer", "en", .nonFeature),
        .init("Trailers", "en", .nonFeature),
        .init("Preview", "en", .nonFeature),
        .init("Previews", "en", .nonFeature),
        .init("Cast & Crew", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("Cast and Crew", "en", .nonFeature),
        .init("Special Features", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("Bonus Features", "en", .nonFeature),
        .init("Scene Selections", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("Scene Selection", "en", .nonFeature),
        .init("Chapters", "en", .nonFeature),
        .init("Languages", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("Language", "en", .nonFeature),
        .init("Subtitles", "en", .nonFeature),
        .init("Setup", "en", .nonFeature),
        .init("Main Menu", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("End Credits", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("Behind the Scenes", "en", .nonFeature),
        .init("Making Of", "en", .nonFeature),
        .init("Commentary", "en", .nonFeature),
        .init("Play with Commentary", "en", .nonFeature),
        // Navigation words. Read off Bloodsport's scene pages, where they
        // sit on buttons exactly like the rest — and where, before they were
        // in the table, "Continue" was a plausible-looking play label the
        // lexicon had no opinion about.
        .init("Back", "en", .nonFeature, seenOn: ["bloodsport"]),
        .init("Continue", "en", .nonFeature, seenOn: ["bloodsport"]),

        // ---- French
        .init("Lecture", "fr", .play),
        .init("Lecture du film", "fr", .play),
        .init("Lire le film", "fr", .play),
        .init("Voir le film", "fr", .play),
        .init("Jouer", "fr", .play),
        .init("Tout lire", "fr", .play),
        .init("Film", "fr", .play),

        .init("Bande-annonce", "fr", .nonFeature),
        .init("Bandes-annonces", "fr", .nonFeature),
        .init("Menu principal", "fr", .nonFeature),
        .init("Langues", "fr", .nonFeature),
        .init("Sous-titres", "fr", .nonFeature),
        .init("Chapitres", "fr", .nonFeature),
        .init("Suppléments", "fr", .nonFeature),

        // ---- Spanish
        .init("Reproducir", "es", .play),
        .init("Reproducir película", "es", .play),
        .init("Reproducir todo", "es", .play),
        .init("Ver película", "es", .play),
        .init("Ver la película", "es", .play),
        .init("Película", "es", .play),

        .init("Tráiler", "es", .nonFeature),
        .init("Avance", "es", .nonFeature),
        .init("Menú principal", "es", .nonFeature),
        .init("Idiomas", "es", .nonFeature),
        .init("Subtítulos", "es", .nonFeature),
        .init("Capítulos", "es", .nonFeature),
        .init("Extras", "es", .nonFeature),

        // ---- German
        .init("Film starten", "de", .play),
        .init("Film abspielen", "de", .play),
        .init("Abspielen", "de", .play),
        .init("Alle abspielen", "de", .play),
        .init("Hauptfilm", "de", .play),
        .init("Film", "de", .play),

        .init("Trailer", "de", .nonFeature),
        .init("Hauptmenü", "de", .nonFeature),
        .init("Sprachen", "de", .nonFeature),
        .init("Untertitel", "de", .nonFeature),
        .init("Kapitel", "de", .nonFeature),
        .init("Extras", "de", .nonFeature),

        // ---- Italian
        .init("Riproduci", "it", .play),
        .init("Riproduci film", "it", .play),
        .init("Riproduci tutto", "it", .play),
        .init("Guarda il film", "it", .play),
        .init("Film", "it", .play),

        .init("Trailer", "it", .nonFeature),
        .init("Menu principale", "it", .nonFeature),
        .init("Lingue", "it", .nonFeature),
        .init("Sottotitoli", "it", .nonFeature),
        .init("Capitoli", "it", .nonFeature),

        // ---- Portuguese
        .init("Reproduzir", "pt", .play),
        .init("Reproduzir tudo", "pt", .play),
        .init("Ver filme", "pt", .play),
        .init("Filme", "pt", .play),

        .init("Trailer", "pt", .nonFeature),
        .init("Menu principal", "pt", .nonFeature),
        .init("Idiomas", "pt", .nonFeature),
        .init("Legendas", "pt", .nonFeature),
        .init("Capítulos", "pt", .nonFeature),

        // ---- Dutch
        .init("Film afspelen", "nl", .play),
        .init("Afspelen", "nl", .play),
        .init("Speel film", "nl", .play),

        // ---- Japanese
        .init("本編再生", "ja", .play),
        .init("再生", "ja", .play),
        .init("本編", "ja", .play),

        .init("予告編", "ja", .nonFeature),
        .init("特典映像", "ja", .nonFeature),
        .init("字幕", "ja", .nonFeature),
        .init("チャプター", "ja", .nonFeature),
    ]

    /// Words a real OCR run got wrong, kept beside the table because Vision
    /// wants the *correct* spelling of a word it is likely to mangle. These
    /// are not button roles and never match anything — `Crew` and `Cast` are
    /// halves of a caption OCR split, not captions.
    static let misreadCorrections = ["Cast", "Crew"]

    // MARK: - Derived views (no data of their own)

    /// Folded play keys by language — the shape earlier code read, now a
    /// view over `entries`.
    static let playLabels: [String: [String]] = grouped(.play)

    /// Folded non-feature keys by language.
    static let nonFeatureLabels: [String: [String]] = grouped(.nonFeature)

    private static func grouped(_ role: Role) -> [String: [String]] {
        var out: [String: Set<String>] = [:]
        for entry in entries where entry.role == role {
            out[entry.language, default: []].insert(entry.key)
        }
        return out.mapValues { $0.sorted() }
    }

    /// Every play label in its authored spelling.
    static let allPlayLabels: [String] = Set(
        entries.filter { $0.role == .play }.map(\.text)
    ).sorted()

    /// What `MenuOCR.Settings.customWords` seeds Vision with: every button
    /// word this project has ever named, plus the corrections. One list, so
    /// the words the matcher knows and the words the reader is primed for
    /// cannot drift apart.
    static let customWords: [String] = Set(entries.map(\.text) + misreadCorrections).sorted()

    /// Every disc slug that has contributed a row, for the archive review.
    static let contributingDiscs: [String] = Set(entries.flatMap(\.seenOn)).sorted()

    // MARK: - Matching

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
    /// Languages are consulted in tag order so a word several languages
    /// share (`film`) always reports the same one.
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

    /// What the table says this caption does, or `nil` when it has never
    /// seen the word. The archive's vocabulary column: a `nil` here on a
    /// reviewed disc is a row waiting to be added.
    static func role(of label: String) -> Role? {
        if isPlayLabel(label) { return .play }
        if isNonFeatureLabel(label) { return .nonFeature }
        return nil
    }
}
