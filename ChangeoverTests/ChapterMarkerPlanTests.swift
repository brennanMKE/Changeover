import Foundation
import Testing
@testable import Changeover

/// Whether the disc's chapter names may be written into the encode
/// (`ChapterMarkerPlan`).
///
/// The rule the user set is stricter than the document's table: the names are
/// written **only when the extracted count equals the feature title's chapter
/// count**. Refuse, never pad. A wrong name is a wrong caption at the right
/// timestamp; a set that does not line up with HandBrake's own markers is a
/// CSV applied by number to markers somebody else placed.
struct ChapterMarkerPlanTests {

    private static func candidates(_ numbers: ClosedRange<Int>) -> [ChapterNames.Candidate] {
        numbers.map {
            ChapterNames.Candidate(chapter: $0, printedNumber: $0, name: "Chapter text \($0)", confidence: 1)
        }
    }

    // MARK: - The equality rule

    @Test func anExactMatchIsWritten() {
        let decision = ChapterMarkerPlan.decide(candidates: Self.candidates(1...23), chapterCount: 23)
        #expect(decision.isWrite)
        #expect(decision.rows.count == 23)
        #expect(decision.rows.map(\.number) == Array(1...23))
    }

    /// **The falsification.** The menu names 20 of the disc's 21 chapters —
    /// Oppenheimer's exact shape. Padding, trimming or writing a partial set
    /// are all forbidden: nothing is written, and the reason says both
    /// numbers.
    @Test func oneChapterShortIsRefusedNotPadded() {
        let decision = ChapterMarkerPlan.decide(candidates: Self.candidates(1...20), chapterCount: 21)
        #expect(!decision.isWrite)
        #expect(decision.rows.isEmpty)
        guard case .refused(let reason) = decision else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("20"))
        #expect(reason.contains("21"))
    }

    /// The other direction: the menu names more chapters than the disc has.
    /// `ChapterNames.markers` drops the out-of-range rows, and what is left
    /// no longer equals the count — so still nothing is written.
    @Test func moreNamesThanChaptersIsRefused() {
        let decision = ChapterMarkerPlan.decide(candidates: Self.candidates(1...30), chapterCount: 23)
        #expect(!decision.isWrite)
    }

    /// A gap in the middle is a count mismatch too, however close it looks.
    @Test func aMissingMiddleChapterIsRefused() {
        var names = Self.candidates(1...23)
        names.removeAll { $0.chapter == 11 }
        #expect(!ChapterMarkerPlan.decide(candidates: names, chapterCount: 23).isWrite)
    }

    @Test func aScanWithNoChapterCountRefuses() {
        #expect(!ChapterMarkerPlan.decide(candidates: Self.candidates(1...23), chapterCount: nil).isWrite)
        #expect(!ChapterMarkerPlan.decide(candidates: Self.candidates(1...23), chapterCount: 0).isWrite)
    }

    @Test func noNamesAtAllRefusesWithoutBlamingTheDisc() {
        guard case .refused(let reason) = ChapterMarkerPlan.decide(candidates: [], chapterCount: 23) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason == "the disc's menus name no chapters")
    }

    /// A scene index with highlights only: `ChapterNames.markers` returns
    /// `nil` below half, and the reason says so rather than reporting a count
    /// mismatch.
    @Test func aScenesIndexBelowHalfIsRefusedAsSuch() {
        guard case .refused(let reason) = ChapterMarkerPlan.decide(candidates: Self.candidates(1...5), chapterCount: 23) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("fewer than half"))
    }

    /// A disputed candidate is dropped by `ChapterNames.markers`, which then
    /// leaves the count one short — and a short set is refused whole.
    @Test func aDisputedNameCostsTheWholeSet() {
        var names = Self.candidates(1...23)
        names[6] = ChapterNames.Candidate(chapter: 7, printedNumber: 9, name: "Death touch", confidence: 1, disputed: true)
        #expect(!ChapterMarkerPlan.decide(candidates: names, chapterCount: 23).isWrite)
    }

    @Test func anEmptyNameIsNeverWritten() {
        var names = Self.candidates(1...23)
        names[3] = ChapterNames.Candidate(chapter: 4, printedNumber: 4, name: "   ", confidence: 1)
        #expect(!ChapterMarkerPlan.decide(candidates: names, chapterCount: 23).isWrite)
    }

    // MARK: - The caption

    @Test func aWriteIsAnnouncedWithItsCount() {
        var menu = MenuIntelligence()
        menu.chapterNames = Self.candidates(1...23)
        menu.markerPlan = ChapterMarkerPlan.decide(candidates: menu.chapterNames, chapterCount: 23)
        #expect(MenuStatusLine.chapterLine(menu) == "23 chapter names from the disc menu will be written into the file.")
    }

    /// A refusal the user cannot see is indistinguishable from a bug.
    @Test func aRefusalIsSaidOutLoud() throws {
        var menu = MenuIntelligence()
        menu.chapterNames = Self.candidates(1...20)
        menu.markerPlan = ChapterMarkerPlan.decide(candidates: menu.chapterNames, chapterCount: 21)
        let line = try #require(MenuStatusLine.chapterLine(menu))
        #expect(line.hasPrefix("Chapter names from the disc menu are not being used"))
        #expect(line.contains("21"))
    }

    /// A disc that names nothing says nothing: a caption about absent
    /// chapter names on every disc without a scene menu would be noise.
    @Test func aDiscWithNoNamesIsSilent() {
        #expect(MenuStatusLine.chapterLine(MenuIntelligence()) == nil)
    }
}
