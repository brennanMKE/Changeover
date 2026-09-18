import Foundation

/// Whether the disc's chapter names may be written into the encode, and the
/// rows if they may (`docs/menu-intelligence.md` §3.3).
///
/// `ChapterNames.markers(_:chapterCount:)` already refuses the dangerous
/// shapes: no number above the chapter count, no duplicates, no empty names,
/// `nil` rather than a partial set below half. This adds the rule the user
/// asked for on top of it, and it is stricter than the document's table:
///
/// > **only when the extracted count equals the feature title's chapter
/// > count — refuse, never pad.**
///
/// So a menu that names 20 of 21 chapters writes nothing at all, rather than
/// 20 rows and one unnamed marker. The reasoning is asymmetric on purpose. A
/// wrong *name* is a wrong caption at the right timestamp — cheap, visible,
/// fixable by a later pass over the file. A set that does not line up with
/// HandBrake's own markers is a CSV applied by number to markers somebody
/// else placed, and the one failure mode here that can spoil a forty-minute
/// encode. When the two counts disagree, the honest answer is that this disc
/// needs looking at, not that nineteen of its chapters can be guessed.
///
/// A refusal is never silent: `MenuStatusLine.chapterLine` shows the reason
/// on the Confirm step, and the names stay in the archive either way.
nonisolated enum ChapterMarkerPlan {

    nonisolated enum Decision: Equatable, Sendable {
        case write([MarkerRow])
        case refused(reason: String)

        var rows: [MarkerRow] {
            if case .write(let rows) = self { return rows }
            return []
        }

        var isWrite: Bool {
            if case .write = self { return true }
            return false
        }
    }

    /// - Parameter chapterCount: `DiscTitle.chapterCount` for the title the
    ///   scan settled on. `nil` — no scan, no settled title — always refuses:
    ///   there is nothing to check the names against.
    static func decide(candidates: [ChapterNames.Candidate], chapterCount: Int?) -> Decision {
        guard let chapterCount, chapterCount > 0 else {
            return .refused(reason: "the scan has no chapter count for this title")
        }
        guard !candidates.isEmpty else {
            return .refused(reason: "the disc's menus name no chapters")
        }
        guard let rows = ChapterNames.markers(candidates, chapterCount: chapterCount) else {
            return .refused(reason: "fewer than half of the \(chapterCount) chapters were named")
        }
        guard rows.count == chapterCount else {
            return .refused(reason: "the menu names \(rows.count) chapters and the disc has \(chapterCount)")
        }
        // `markers` sorts, deduplicates and bounds the numbers, so this can
        // only fail if that contract ever changes — which is exactly why it
        // is checked here rather than assumed.
        guard rows.map(\.number) == Array(1...chapterCount) else {
            return .refused(reason: "the named chapters are not 1…\(chapterCount)")
        }
        guard rows.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .refused(reason: "a chapter name came out empty")
        }
        return .write(rows)
    }

    /// The CSV file name inside the job directory. Lives beside the encode's
    /// own output so `WorkingFiles.sweep` removes it with everything else.
    static let csvFileName = "chapters.csv"
}
