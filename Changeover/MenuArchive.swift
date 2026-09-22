import Foundation

/// The raw tier of the data-collection archive: what one disc's menus said,
/// kept as text, one directory per disc (`docs/menu-intelligence.md` §8.1–8.2).
///
/// **Why this exists.** The menu read used to delete its whole working
/// directory the moment the text was out of it, on the reasoning that 64 MB of
/// decrypted menu video is not worth keeping. True of the video; false of
/// everything beside it. Five discs went through joe on 19–20 September and
/// left nothing behind, so when four of them produced no chapter names there
/// was no way to tell a disc that prints none from a reader that failed — the
/// exact question the archive is for. `structure.json` is about 88 KB and the
/// two derived documents are a few more; the cells are the megabytes, and they
/// are what gets deleted.
///
/// Writing here can never fail a rip. Every call is best-effort: a full disk, a
/// read-only archive root, a disc id that is not a usable directory name — all
/// of them mean the rip carries on and the archive is thinner, never that the
/// user loses an encode.
nonisolated enum MenuArchive {

    /// `changeover-menu-ocr/1` and `changeover-menu-derived/1` are written
    /// with sorted keys so two captures of the same disc diff cleanly, and
    /// without escaped slashes so paths in the text stay readable.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: - What the disc was called, and what it turned out to be

    /// One disc's label paired with the movie the user actually chose for it.
    ///
    /// This is the ground truth for the disc-name problem
    /// (`docs/disc-name-inference.md`). `DiscNameSearchTerm` turns a volume
    /// label into a search term with a short rule list, and the rules only
    /// cover labels that carry their own word boundaries: `ARMY_OF_DARKNESS`
    /// works, `ENEMYATTHEGATES` does not, and the user retypes it. Deciding
    /// whether a smarter route is worth having — and later, whether it
    /// actually answers correctly — needs pairs of (what the disc called
    /// itself, what it really was), and nothing was keeping them.
    ///
    /// Recorded when the rip starts rather than when it finishes: the choice
    /// is the evidence, and a rip that fails and is retried rewrites this
    /// record rather than losing it.
    nonisolated struct DiscNaming: Codable, Equatable, Sendable {
        var format: String = "changeover-disc-naming/1"
        var recordedAt: String
        /// The volume label exactly as the drive reported it, unmodified —
        /// the input any future inference has to work from.
        var volumeName: String
        var discID: String?
        /// What `DiscNameSearchTerm.derive` offered, or `nil` when it
        /// declined. `nil` beside a real title is precisely the case worth
        /// studying.
        var derivedSearchTerm: String?
        /// Whether the heuristic's term already matches the chosen title,
        /// case- and punctuation-insensitively. Recorded rather than computed
        /// later so the comparison used to judge a run is the same one every
        /// time.
        var derivedMatchesChoice: Bool
        var chosenTitle: String
        var chosenYear: String
        var tmdbID: String
    }

    /// Fold a title to the form the match check compares: lowercase, letters
    /// and digits, and **word boundaries kept** as single spaces.
    ///
    /// Keeping the boundaries is the entire point, and the first version of
    /// this got it backwards. Folding all the way down to letters made
    /// "Enemyatthegates" and "Enemy at the Gates" equal — so the one disc
    /// this feature exists for was recorded as a *match*, and the archive
    /// would have reported the rules working perfectly on exactly the labels
    /// where they fail. A term with the spaces missing finds nothing on TMDB,
    /// which is the thing being measured.
    ///
    /// Punctuation and case still fold away: "The Girl in the Spider's Web"
    /// and "THE_GIRL_IN_THE_SPIDERS_WEB" are the same search.
    /// An apostrophe is dropped rather than spaced, because it sits *inside*
    /// a word: spacing it would split "Spider's" into "spider s" and stop
    /// `THE_GIRL_IN_THE_SPIDERS_WEB` matching the title it plainly is.
    static func fold(_ text: String) -> String {
        let withoutApostrophes = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let spaced = String(withoutApostrophes.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    static func naming(
        volumeName: String,
        discID: String?,
        derivedSearchTerm: String?,
        chosenTitle: String,
        chosenYear: String,
        tmdbID: String,
        recordedAt: Date = Date()
    ) -> DiscNaming {
        DiscNaming(
            recordedAt: ISO8601DateFormatter().string(from: recordedAt),
            volumeName: volumeName,
            discID: discID,
            derivedSearchTerm: derivedSearchTerm,
            derivedMatchesChoice: derivedSearchTerm.map { fold($0) == fold(chosenTitle) } ?? false,
            chosenTitle: chosenTitle,
            chosenYear: chosenYear,
            tmdbID: tmdbID
        )
    }

    /// Write the naming record for one disc. Best-effort, like every other
    /// write here: a rip is never failed for the archive's sake.
    @discardableResult
    static func writeNaming(
        root: String,
        slug: String,
        naming: DiscNaming,
        fileManager: FileManager = .default
    ) -> String? {
        let directory = discDirectory(root: root, slug: slug)
        guard (try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)) != nil,
              let data = try? encoder().encode(naming)
        else { return nil }
        let path = (directory as NSString).appendingPathComponent("naming.json")
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }

    // MARK: - Naming

    /// The directory name for a disc, from whatever identity it has.
    ///
    /// Prefers the disc's own id (lsdvd's `dvddiscid`), which is stable across
    /// re-reads and unique per pressing; falls back to the volume name, which
    /// is neither but is always there. Anything that is not a letter, digit,
    /// dot, dash or underscore becomes a dash, so a volume called
    /// `BLOODSPORT/2` cannot write outside the archive root.
    static func slug(discID: String?, volumeName: String) -> String {
        let source = (discID?.isEmpty == false ? discID! : volumeName)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        let lowered = source.lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            out.append(allowed.contains(scalar) ? Character(scalar) : "-")
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        // A name of nothing but separators, or one that walks up the tree,
        // is not a directory name this will create.
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "disc" : trimmed
    }

    static func discDirectory(root: String, slug: String) -> String {
        (root as NSString).appendingPathComponent(slug)
    }

    static func menusDirectory(root: String, slug: String) -> String {
        (discDirectory(root: root, slug: slug) as NSString).appendingPathComponent("menus")
    }

    // MARK: - What is kept and what is thrown away

    /// The working directory's entries that are never archived: the decrypted
    /// menu video, and the stills once their text has been read out.
    ///
    /// Returned rather than deleted inline so the rule is a plain value a test
    /// can assert, instead of a `removeItem` buried in an async function that
    /// only a disc could exercise.
    static func disposable(in workDirectory: String) -> [String] {
        [(workDirectory as NSString).appendingPathComponent("cells")]
    }

    // MARK: - Writing

    /// Copy this disc's text products into the archive, then drop the video.
    ///
    /// `stillsSource` is the working directory the helper and ffmpeg wrote
    /// into; the JPEG for each still is moved into `menus/stills/`, keeping
    /// the picture the OCR text was read from beside the text, so a better
    /// reader can be re-run later without the disc.
    @discardableResult
    static func write(
        root: String,
        slug: String,
        structureJSON: Data?,
        ocr: MenuOCRDocument?,
        derived: MenuDerived?,
        stillIDs: [String],
        workDirectory: String,
        fileManager: FileManager = .default
    ) -> String? {
        let menus = menusDirectory(root: root, slug: slug)
        do {
            try fileManager.createDirectory(atPath: menus, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        func write(_ data: Data?, _ name: String) {
            guard let data else { return }
            try? data.write(to: URL(fileURLWithPath: (menus as NSString).appendingPathComponent(name)))
        }

        // Encode only what exists. `JSONEncoder.encode` of a `nil` Optional
        // succeeds and produces the four bytes `null`, so encoding
        // unconditionally would leave a `derived.json` on every disc whose
        // menus yielded nothing — a file that reads like a finding and is
        // actually the absence of one.
        write(structureJSON, "structure.json")
        if let ocr { write(try? encoder().encode(ocr), "ocr.json") }
        if let derived { write(try? encoder().encode(derived), "derived.json") }

        if !stillIDs.isEmpty {
            let stills = (menus as NSString).appendingPathComponent("stills")
            try? fileManager.createDirectory(atPath: stills, withIntermediateDirectories: true)
            for id in stillIDs {
                let from = (workDirectory as NSString).appendingPathComponent("\(id).jpg")
                guard fileManager.fileExists(atPath: from) else { continue }
                let to = (stills as NSString).appendingPathComponent("\(id).jpg")
                try? fileManager.removeItem(atPath: to)
                try? fileManager.moveItem(atPath: from, toPath: to)
            }
        }
        return menus
    }
}
