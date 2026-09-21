import Foundation

/// One audio track's new tags, as an upgrade would write them
/// (`-metadata:s:a:<track> language=… title=…`).
nonisolated struct AudioTag: Codable, Hashable, Sendable {
    /// 0-based **audio** track index — what `-metadata:s:a:<n>` addresses and
    /// what `AudioSummary.track` is. Never ffprobe's global stream index.
    var track: Int
    /// ISO 639-2, from `LanguageCode.code(forMenuName:)`. `nil` leaves the
    /// existing tag alone.
    var language: String?
    /// The menu's own word — `Français`, not `fra`.
    var title: String?
}

/// #0062/§7.4 — everything an upgrade job needs, as one plain value.
///
/// Deliberately self-contained: the file to rewrite, the chapter rows already
/// checked against *that file's* chapter count, and the audio tags. Nothing in
/// it refers to a disc, a scan, a `JobController` or a view — so the same job
/// can be driven from the Confirm step today and from a library list later,
/// with no second code path.
nonisolated struct UpgradePlan: Codable, Hashable, Sendable {
    /// The library file to rewrite, in place, by staged replacement.
    var filePath: String
    /// One row per chapter, `1…chapterCount`, validated against the file.
    /// Empty means "leave the chapter titles alone".
    var chapters: [MarkerRow]
    var audio: [AudioTag]

    init(filePath: String, chapters: [MarkerRow] = [], audio: [AudioTag] = []) {
        self.filePath = filePath
        self.chapters = chapters
        self.audio = audio
    }

    var isEmpty: Bool { chapters.isEmpty && audio.isEmpty }

    /// "20 chapter names, 1 audio language" — what the Done card says was
    /// changed. Never a claim about video or audio *data*: a remux copies
    /// those bytes and the verification proves it.
    var changeSummary: String {
        let parts = summaryParts
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }

    /// The same list, joined the way a sentence joins one: "20 chapter names
    /// and 1 audio language". `changeSummary` above keeps its comma-joined
    /// shape, which the Done card and its tests pin.
    var plainChangeSummary: String {
        let parts = summaryParts
        return parts.isEmpty ? "nothing" : PlainLanguage.andList(parts)
    }

    private var summaryParts: [String] {
        var parts: [String] = []
        if !chapters.isEmpty {
            parts.append("\(chapters.count) chapter name\(chapters.count == 1 ? "" : "s")")
        }
        let languages = audio.filter { $0.language != nil }.count
        if languages > 0 {
            parts.append("\(languages) audio language\(languages == 1 ? "" : "s")")
        }
        let titles = audio.filter { $0.language == nil && $0.title != nil }.count
        if titles > 0 {
            parts.append("\(titles) audio track name\(titles == 1 ? "" : "s")")
        }
        return parts
    }
}

/// One line of the comparison card: what Plex has now, what the disc offers,
/// and what will happen.
nonisolated struct UpgradeRow: Equatable, Sendable {
    nonisolated enum Verdict: Equatable, Sendable {
        /// Will be written by the remux.
        case upgrade
        /// The file already has this; there is nothing to add.
        case unchanged
        /// The disc has something, and it is **refused** — with the reason,
        /// stated in full, including both counts where counts are the issue.
        case refused(String)
        /// A remux cannot do this at all; the Replace path is how.
        case needsRerip(String)

        var isUpgrade: Bool { self == .upgrade }
    }

    /// "Chapters", "Audio 1", "Subtitles".
    var label: String
    /// "20, unnamed (\"Chapter 1\"…\"Chapter 20\")".
    var now: String
    /// "23 names from the scene menu", or "—".
    var fromDisc: String
    var verdict: Verdict
}

/// §7.3 — the comparison, as a pure function of what the file lacks and what
/// the disc offers.
///
/// **The rules that refuse are the point of this type.** A wrong chapter name
/// is a wrong caption at the right timestamp; a chapter set that does not line
/// up with the file's own markers is names against the wrong moments, written
/// over a file that took forty minutes to make. So:
///
/// - chapters upgrade **only** when the disc named exactly as many chapters as
///   the file has, and only when the file's names are placeholders — unless
///   the user explicitly ticks to overwrite real names;
/// - a count mismatch is stated with **both** numbers and refuses; nothing is
///   trimmed, padded, or guessed;
/// - an audio track is tagged only where the disc's menu gives a real
///   per-stream mapping (§5.2 shape 1); an ordered list is a caption;
/// - everything else — a missing subtitle, a language that was never encoded
///   — says "needs a re-rip" and offers nothing.
nonisolated enum UpgradeProposal {

    nonisolated struct Result: Equatable, Sendable {
        /// The card's rows, in display order.
        var rows: [UpgradeRow]
        /// `nil` when there is nothing an upgrade would do — in which case
        /// the card says so rather than offering a no-op button.
        var plan: UpgradePlan?
        /// The card's headline.
        var headline: String
        /// True when the only thing standing between the user and the chapter
        /// names is the "replace existing names" tick — so the card shows it
        /// rather than leaving a dead end.
        var overwriteWouldHelp: Bool

        var offersUpgrade: Bool { plan != nil }

        /// True when the disc had something to give for a row and a rule
        /// **refused** it — the Oppenheimer 20/21 chapter-count case and its
        /// siblings.
        ///
        /// Deliberately not `.needsRerip`: a subtitle a remux cannot add is
        /// not something Changeover declined to do, it is what Replace is
        /// for, and every file this app produces carries no subtitles
        /// (#0036), so counting it would make "declined" the answer on every
        /// duplicate. Matches `headline(plan:rows:overwriteWouldHelp:)`
        /// exactly, so the plain sentence and the verbatim headline can never
        /// disagree about which of the two "no upgrade" cases this is.
        var declinedSomething: Bool {
            rows.contains { if case .refused = $0.verdict { return true } else { return false } }
        }
    }

    /// - Parameters:
    ///   - filePath: the library file the plan would rewrite.
    ///   - inventory: what `ffprobe` found in it.
    ///   - offer: what the disc's menus can supply. Pass an empty offer for a
    ///     library-only view: every row then reads from the file alone.
    ///   - overwriteExistingNames: the card's explicit tick. Only ever
    ///     consulted when the file's chapters already carry real names.
    static func compare(
        filePath: String,
        inventory: LibraryFileInventory,
        offer: DiscUpgradeOffer,
        overwriteExistingNames: Bool = false
    ) -> Result {
        let gaps = LibraryFileGaps.find(inventory)
        var rows: [UpgradeRow] = []
        var plan = UpgradePlan(filePath: filePath)
        var overwriteWouldHelp = false

        // MARK: Chapters
        let chapterRow = chapterRow(
            gaps: gaps,
            inventory: inventory,
            names: offer.chapterNames,
            overwriteExistingNames: overwriteExistingNames
        )
        rows.append(chapterRow.row)
        plan.chapters = chapterRow.rows
        overwriteWouldHelp = chapterRow.overwriteWouldHelp

        // MARK: Audio, one row per track
        let mapping = Dictionary(offer.audioMapping.map { ($0.track, $0.word) }, uniquingKeysWith: { first, _ in first })
        for track in inventory.audio {
            let (row, tag) = audioRow(track: track, menuWord: mapping[track.track], languages: offer.languages)
            rows.append(row)
            if let tag { plan.audio.append(tag) }
        }

        // MARK: Everything a remux cannot do
        if gaps.hasNoSubtitles {
            rows.append(UpgradeRow(
                label: "Subtitles",
                now: "none",
                fromDisc: subtitleOffer(offer),
                verdict: .needsRerip("a subtitle track has to be encoded, so this needs a re-rip")
            ))
        }

        let finalPlan = plan.isEmpty ? nil : plan
        return Result(
            rows: rows,
            plan: finalPlan,
            headline: headline(plan: finalPlan, rows: rows, overwriteWouldHelp: overwriteWouldHelp),
            overwriteWouldHelp: overwriteWouldHelp
        )
    }

    // MARK: - Chapters

    private static func chapterRow(
        gaps: LibraryFileGaps,
        inventory: LibraryFileInventory,
        names: [MarkerRow],
        overwriteExistingNames: Bool
    ) -> (row: UpgradeRow, rows: [MarkerRow], overwriteWouldHelp: Bool) {
        let now = chapterNowText(gaps: gaps, inventory: inventory)
        let fromDisc = names.isEmpty
            ? "—"
            : "\(names.count) name\(names.count == 1 ? "" : "s") from the scene menu"

        func row(_ verdict: UpgradeRow.Verdict) -> UpgradeRow {
            UpgradeRow(label: "Chapters", now: now, fromDisc: fromDisc, verdict: verdict)
        }

        guard gaps.chapterCount > 0 else {
            return (row(.needsRerip("the file has no chapter markers at all, and a remux cannot add timings")), [], false)
        }
        guard !names.isEmpty else {
            return (row(.unchanged), [], false)
        }
        // The user's rule, and the one that bites on the disc this feature
        // exists for: the disc's scan reports 21 chapters on Oppenheimer's
        // feature and the file in the library has 20. Both numbers are said
        // out loud; nothing is dropped to make them agree.
        guard names.count == gaps.chapterCount else {
            return (row(.refused(
                "\(gaps.chapterCount) chapters in the file, \(names.count) name\(names.count == 1 ? "" : "s") on the disc — not upgraded"
            )), [], false)
        }
        guard names.map(\.number) == Array(1...gaps.chapterCount) else {
            return (row(.refused(
                "the disc's names are not chapters 1…\(gaps.chapterCount) — not upgraded"
            )), [], false)
        }
        guard names.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return (row(.refused("a chapter name from the disc came out empty — not upgraded")), [], false)
        }
        if !gaps.chaptersAreUnnamed && !overwriteExistingNames {
            return (row(.refused(
                "\(gaps.namedChapterCount) of the file's chapters already carry real names — tick “Replace existing names” to overwrite them"
            )), [], true)
        }
        return (row(.upgrade), names, false)
    }

    private static func chapterNowText(gaps: LibraryFileGaps, inventory: LibraryFileInventory) -> String {
        guard gaps.chapterCount > 0 else { return "none" }
        if gaps.chaptersAreUnnamed {
            let first = inventory.chapters.first?.title ?? ""
            let last = inventory.chapters.last?.title ?? ""
            if first.isEmpty || last.isEmpty {
                return "\(gaps.chapterCount), unnamed"
            }
            return "\(gaps.chapterCount), unnamed (“\(first)”…“\(last)”)"
        }
        return "\(gaps.chapterCount), \(gaps.namedChapterCount) named"
    }

    // MARK: - Audio

    private static func audioRow(
        track: AudioSummary,
        menuWord: String?,
        languages: LanguageHints.Lists?
    ) -> (UpgradeRow, AudioTag?) {
        let label = "Audio \(track.track + 1)"
        var nowParts = [track.codec.uppercased(), channelText(track.channels)]
        nowParts.append(track.language.map { "language \($0)" } ?? "language not set")
        if let title = track.title { nowParts.append("“\(title)”") }
        let now = nowParts.joined(separator: ", ")

        // §5.2 shape 1 — the menu's button set the stream directly, so the
        // word is structurally attached to this track.
        if let menuWord {
            let code = LanguageCode.code(forMenuName: menuWord)
            let needsLanguage = track.language == nil && code != nil
            let needsTitle = track.title == nil
            guard needsLanguage || needsTitle else {
                return (UpgradeRow(label: label, now: now, fromDisc: "menu: \(menuWord)", verdict: .unchanged), nil)
            }
            return (
                UpgradeRow(label: label, now: now, fromDisc: "menu: \(menuWord)", verdict: .upgrade),
                AudioTag(
                    track: track.track,
                    language: needsLanguage ? code : nil,
                    title: needsTitle ? menuWord : nil
                )
            )
        }

        // §5.2 shape 2 — an ordered list of words and nothing more. The list
        // order usually matches stream order, and "usually" is not a mapping,
        // so this never becomes an assignment.
        if track.language == nil, let spoken = languages?.spoken, !spoken.isEmpty {
            return (UpgradeRow(
                label: label,
                now: now,
                fromDisc: "menu lists: \(spoken.joined(separator: ", "))",
                verdict: .refused("the disc's menu lists its languages but does not say which track is which — not upgraded")
            ), nil)
        }

        if track.language == nil {
            return (UpgradeRow(
                label: label,
                now: now,
                fromDisc: "—",
                verdict: .refused("the disc's menus name no language for this track")
            ), nil)
        }
        return (UpgradeRow(label: label, now: now, fromDisc: "—", verdict: .unchanged), nil)
    }

    private static func channelText(_ channels: Int) -> String {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    private static func subtitleOffer(_ offer: DiscUpgradeOffer) -> String {
        guard let subtitles = offer.languages?.subtitles, !subtitles.isEmpty else { return "—" }
        return "menu lists: \(subtitles.joined(separator: ", "))"
    }

    // MARK: - Headline

    private static func headline(plan: UpgradePlan?, rows: [UpgradeRow], overwriteWouldHelp: Bool) -> String {
        if plan != nil {
            return "This disc can improve that file without re-encoding it:"
        }
        if overwriteWouldHelp {
            return "This disc's chapter names differ from the ones already in the file:"
        }
        if rows.contains(where: { if case .refused = $0.verdict { return true } else { return false } }) {
            return "This disc cannot improve that file:"
        }
        return "That file already has everything this disc can give it."
    }
}
