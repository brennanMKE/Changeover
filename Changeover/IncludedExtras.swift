import Foundation

/// #0184 — what else this disc is about to import, said on the step where the
/// user is standing.
///
/// The app finds a disc's bonus material, names it, ticks it and files it
/// correctly, and until now said none of that until the Confirm step. On Signs
/// tonight the log read
///
///     interrogate bonus: title 8 “Making of Signs” → Behind The Scenes,
///                        ticked=true, off by 0s
///
/// while the Choose step showed a search box and nothing else. The user asked
/// how it was going to be fixed "so the bonus feature is included" — and it
/// already was. An import nobody can see is indistinguishable from one that is
/// not happening, which is the same fault as #0153's silent eject and #0171's
/// unreachable rung, arriving a third time in a third place.
///
/// Pure, so the sentence is tested rather than merely compiled.
nonisolated enum IncludedExtras {

    /// One thing coming along with the film.
    nonisolated struct Item: Equatable, Sendable {
        var titleIndex: Int
        var label: String
        var durationSeconds: Int
        /// The Plex folder it will land in, e.g. `Behind The Scenes`.
        var folderName: String

        init(titleIndex: Int, label: String, durationSeconds: Int, folderName: String) {
            self.titleIndex = titleIndex
            self.label = label
            self.durationSeconds = durationSeconds
            self.folderName = folderName
        }
    }

    /// Everything ticked, in disc order, with the name and folder it will use.
    ///
    /// Reads the same two inputs `ExtrasPlan.make` reads — the ticked indices
    /// and the labels — so the line cannot promise something the pipeline will
    /// not do. Anything ticked without a name is still reported, because a
    /// nameless extra is still an encode the user is about to pay for; it just
    /// goes to the `Clips` tree instead of beside the film.
    static func items(ticked: Set<Int>, labels: [Int: String], titles: [DiscTitle]) -> [Item] {
        titles
            .filter { ticked.contains($0.index) }
            .sorted { $0.index < $1.index }
            .map { title in
                let label = labels[title.index] ?? ""
                return Item(
                    titleIndex: title.index,
                    label: label,
                    durationSeconds: title.durationSeconds,
                    folderName: label.isEmpty
                        ? clipsFolderName
                        : PlexExtra.kind(forLabel: label).folderName)
            }
    }

    /// What an unnamed extra's destination is called in a sentence. Not a
    /// `PlexExtra.Kind` — it is outside the Plex library entirely (#0031), and
    /// saying "Other" would imply it sits with the film.
    static let clipsFolderName = "Clips"

    /// The line above Continue. `nil` when nothing else is coming.
    ///
    /// Leads with what it is rather than how many: "Also importing “Making of
    /// Signs” (59m)" is checkable at a glance and "1 extra" is not.
    static func line(_ items: [Item]) -> String? {
        guard !items.isEmpty else { return nil }
        if items.count == 1, let only = items.first {
            return "Also importing \(quoted(only.label, fallback: "title \(only.titleIndex)")) "
                + "(\(DiscTitleFormatting.plainDuration(only.durationSeconds))), "
                + "filed with the film."
        }
        let total = items.reduce(0) { $0 + $1.durationSeconds }
        return "Also importing \(items.count) extras "
            + "(\(DiscTitleFormatting.plainDuration(total)) in all), filed with the film."
    }

    /// The detail register: every item, one per line, with where it lands.
    static func detail(_ items: [Item]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map { item in
            "title \(item.titleIndex) · \(DiscTitleFormatting.duration(item.durationSeconds)) · "
                + "\(quoted(item.label, fallback: "no name")) → \(item.folderName)"
        }.joined(separator: "\n")
    }

    private static func quoted(_ text: String, fallback: String) -> String {
        text.isEmpty ? fallback : "“\(text)”"
    }
}
