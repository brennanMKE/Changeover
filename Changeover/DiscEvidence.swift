import Foundation

/// #0175 — everything known about the disc in the drive, in one value, so a
/// question can be asked of it without reaching back into the app.
///
/// The app reads a disc three ways and until now each reader kept its findings
/// to itself: `DiscScanner` knows the titles and their runtimes, `MenuReader`
/// knows what the menus print, and `AppSettings` knows the volume label. The
/// inference rungs each pulled the one or two facts they wanted and ignored
/// the rest — which is why `MultiTitleInference` could ask "which films are on
/// this disc" while having no idea the disc holds a 58-minute title that is
/// obviously not a film.
///
/// Gathering them first is what makes a *sequence* of questions possible, each
/// seeing the same disc.
nonisolated struct DiscEvidence: Equatable, Sendable {

    /// The volume label. Often a catalogue number (`7000078778_1`), sometimes
    /// the film (`Signs`), occasionally every film at once
    /// (`UNCLE_BUCK_GREAT_OUTDOORS`).
    var volumeName: String

    /// Menu text, page by page, in the order each page printed it.
    ///
    /// **Pages, not one flat list.** A DVD menu's structure is evidence: the
    /// Get Hard disc's entry menu prints the PLAY block once per film, and
    /// that repetition is the strongest signal on the disc that it holds two.
    /// Flattening and deduplicating destroys it, which is the mistake
    /// `MultiTitleInference` had to work around.
    var menuPages: [[String]]

    /// Every title the scan found.
    var titles: [DiscTitle]

    /// The title the scan called the main feature, if it named one.
    var mainFeatureIndex: Int?

    init(volumeName: String, menuPages: [[String]], titles: [DiscTitle],
         mainFeatureIndex: Int? = nil) {
        self.volumeName = volumeName
        self.menuPages = menuPages
        self.titles = titles
        self.mainFeatureIndex = mainFeatureIndex
    }

    /// Built from what the app already holds.
    static func make(volumeName: String, ocr: MenuOCRDocument?, disc: DiscInfo,
                     mainFeatureIndex: Int?) -> DiscEvidence {
        var pages: [[String]] = []
        var seenOnEarlierPages = Set<String>()
        for still in ocr?.stills ?? [] {
            var page: [String] = []
            for observation in still.observations {
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 120, text.contains(where: \.isLetter) else { continue }
                // Repeats WITHIN a page are kept; across pages they are
                // furniture repeated on every screen.
                guard !seenOnEarlierPages.contains(text.lowercased()) else { continue }
                page.append(text)
            }
            for text in page { seenOnEarlierPages.insert(text.lowercased()) }
            if !page.isEmpty { pages.append(page) }
        }
        return DiscEvidence(volumeName: volumeName, menuPages: pages,
                            titles: disc.titles, mainFeatureIndex: mainFeatureIndex)
    }

    /// Every menu line, flattened, for a question that does not care about
    /// page structure.
    var allLines: [String] { menuPages.flatMap { $0 } }

    /// The titles long enough to be a film, longest first — the shortlist
    /// every "what is on this disc" question is really about.
    var substantialTitles: [DiscTitle] {
        titles.filter { $0.durationSeconds >= DiscTitleHeuristic.featureMinimumSeconds }
            .sorted { $0.durationSeconds > $1.durationSeconds }
    }

    /// How the title table reads to a person, for a prompt. Runtimes only —
    /// no index arithmetic, because the model is being asked to recognise
    /// content, not to do bookkeeping the app does better.
    var titleTableForPrompt: String {
        titles
            .filter { $0.durationSeconds >= 60 }
            .sorted { $0.durationSeconds > $1.durationSeconds }
            .prefix(20)
            // #0183 — the same shape the instructions ask the model to answer
            // in. This printed `59m` while the question asked for `(58:54)`,
            // the model sensibly echoed the shape it had been shown, and the
            // parser rejected it — so Signs' 58:54 bonus reel was nominated
            // from the runtimes and then lost its name.
            .map { "- title \($0.index): \(DiscTitleFormatting.duration($0.durationSeconds))" }
            .joined(separator: "\n")
    }
}
