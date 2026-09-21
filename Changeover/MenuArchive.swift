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
