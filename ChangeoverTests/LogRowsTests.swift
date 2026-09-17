import Foundation
import Testing
@testable import Changeover

/// #0062 — `LogRows.build`: which rows the History window draws, and what the
/// folds say. Pure: no `JobLog` instance, no SwiftUI.
struct LogRowsTests {

    // MARK: - Fixtures

    private static func line(_ id: Int, _ text: String, after previous: LogCategory? = nil) -> LogLine {
        LogLine(
            id: id,
            timestamp: Date(timeIntervalSince1970: 0),
            text: text,
            category: LogClassifier.category(for: text, previousCategory: previous)
        )
    }

    /// The shape of a real encode's log, as the wireframe draws it: two
    /// pipeline lines, the 23-line x265 preamble, the pipeline's own
    /// "selected title" milestone, a nine-line `[hh:mm:ss] scan:` run, then
    /// the failure and its detail. The milestone in the middle is what makes
    /// these two *separate* runs — a fold is a maximal run of unimportant
    /// lines, so contiguous chatter of two shapes folds once (pinned by
    /// `contiguousChatterOfTwoShapesFoldsOnce` below).
    private static func realisticLog() -> [LogLine] {
        var lines: [LogLine] = [
            line(0, "── Starting: Air (2023) {tmdb-964960}"),
            line(1, "▶ Job 2026-09-17T14-02-11-8F3A"),
        ]
        for index in 0..<23 {
            lines.append(line(2 + index, "x265 [info]: setting \(index)"))
        }
        lines.append(line(25, "▶ HandBrake selected title 1"))
        for index in 0..<9 {
            lines.append(line(26 + index, "[11:03:41] scan: scanning title \(index)"))
        }
        lines.append(line(35, "ERROR: avformatMux: No space left on device"))
        lines.append(line(36, "✗ HandBrake ran out of space."))
        lines.append(line(37, "   Free some room and try again.", after: .failure))
        return lines
    }

    private func labels(_ rows: [LogRow]) -> [String] {
        rows.map { row in
            switch row {
            case .line(let line):     return line.text
            case .collapsed(let run): return run.summary
            }
        }
    }

    // MARK: - Important

    @Test func importantKeepsTheMilestonesAndTheErrorAndFoldsEverythingElse() {
        let rows = LogRows.build(lines: Self.realisticLog(), filter: .important, expanded: [])

        #expect(labels(rows) == [
            "── Starting: Air (2023) {tmdb-964960}",
            "▶ Job 2026-09-17T14-02-11-8F3A",
            "x265 settings · 23 lines",
            "▶ HandBrake selected title 1",
            "HandBrake output · 9 lines",
            "ERROR: avformatMux: No space left on device",
            "✗ HandBrake ran out of space.",
            "   Free some room and try again.",
        ])
    }

    /// The fold is a maximal run of unimportant lines, not one run per shape:
    /// x265 settings running straight into HandBrake's timestamped chatter is
    /// **one** fold, named for the mixture. Nothing is lost — the count is
    /// exact and the run expands in place.
    @Test func contiguousChatterOfTwoShapesFoldsOnce() {
        var lines: [LogLine] = [Self.line(0, "▶ Job x")]
        for index in 0..<4 { lines.append(Self.line(1 + index, "x265 [info]: setting \(index)")) }
        for index in 0..<3 { lines.append(Self.line(5 + index, "[11:03:41] scan: title \(index)")) }

        #expect(labels(LogRows.build(lines: lines, filter: .important, expanded: []))
                == ["▶ Job x", "HandBrake output · 7 lines"])
    }

    @Test func expandingOneFoldInlinesOnlyThatRunAndKeepsItsHeader() {
        let lines = Self.realisticLog()
        let collapsed = LogRows.build(lines: lines, filter: .important, expanded: [])
        guard case .collapsed(let x265)? = collapsed.first(where: { if case .collapsed = $0 { return true }; return false }) else {
            Issue.record("expected a fold")
            return
        }
        #expect(x265.firstID == 2)
        #expect(x265.lastID == 24)
        #expect(x265.count == 23)

        let rows = LogRows.build(lines: lines, filter: .important, expanded: [x265.firstID])
        let texts = labels(rows)
        #expect(texts[2] == "x265 settings · 23 lines")
        #expect(texts[3] == "x265 [info]: setting 0")
        #expect(texts[25] == "x265 [info]: setting 22")
        // The other run is untouched.
        #expect(texts[26] == "▶ HandBrake selected title 1")
        #expect(texts[27] == "HandBrake output · 9 lines")
        #expect(rows.count == collapsed.count + 23)
    }

    @Test func rowIDsAreUniqueAcrossLinesAndFolds() {
        let lines = Self.realisticLog()
        for expanded in [Set<Int>(), Set([2]), Set([2, 26])] {
            let ids = LogRows.build(lines: lines, filter: .important, expanded: expanded).map(\.id)
            #expect(Set(ids).count == ids.count, "duplicate row id with expanded = \(expanded)")
        }
        // A fold over line 0 must not collide with line 0 itself.
        let folded = LogRows.build(lines: [Self.line(0, "x265 [info]: a")], filter: .important, expanded: [])
        #expect(folded.map(\.id) == [-1])
    }

    /// Nothing is ever silently dropped: the counts on the folds plus the
    /// visible rows account for every line.
    @Test func foldCountsAreExactAndAccountForEveryLine() {
        let lines = Self.realisticLog()
        let rows = LogRows.build(lines: lines, filter: .important, expanded: [])
        let shown = rows.reduce(0) { total, row in
            switch row {
            case .line:               return total + 1
            case .collapsed(let run): return total + run.count
            }
        }
        #expect(shown == lines.count)
    }

    /// A `.detail` line follows its milestone in either filter — the
    /// continuation must never be separated from the headline it explains.
    @Test func aDetailLineStaysDirectlyUnderItsMilestoneInBothFilters() {
        let lines = Self.realisticLog()
        for filter in LogFilter.allCases {
            let texts = labels(LogRows.build(lines: lines, filter: filter, expanded: []))
            guard let index = texts.firstIndex(of: "   Free some room and try again.") else {
                Issue.record("detail line missing under \(filter)")
                continue
            }
            #expect(texts[index - 1] == "✗ HandBrake ran out of space.")
        }
    }

    // MARK: - Everything

    /// The orchestrator's decision: "Everything" still folds encoder runs of
    /// eight or more. Copy Log is always raw regardless (`JobLog.exportText`).
    @Test func everythingFoldsLongEncoderRunsAndInlinesShortOnes() {
        var long: [LogLine] = [Self.line(0, "▶ Job x")]
        for index in 0..<8 { long.append(Self.line(1 + index, "x265 [info]: setting \(index)")) }
        #expect(labels(LogRows.build(lines: long, filter: .everything, expanded: [])) == [
            "▶ Job x", "x265 settings · 8 lines",
        ])

        var short: [LogLine] = [Self.line(0, "▶ Job x")]
        for index in 0..<7 { short.append(Self.line(1 + index, "x265 [info]: setting \(index)")) }
        let rows = labels(LogRows.build(lines: short, filter: .everything, expanded: []))
        #expect(rows.count == 8)
        #expect(rows.allSatisfy { !$0.contains("· 7 lines") })
    }

    /// `.plain` is not chatter to fold: `makemkvcon`'s `MSG:` lines and
    /// HandBrake's banner stay inline under "Everything", however many there
    /// are.
    @Test func everythingNeverFoldsPlainLines() {
        var lines: [LogLine] = []
        for index in 0..<20 { lines.append(Self.line(index, "MSG:1005,0,1,\"message \(index)\"")) }
        let rows = LogRows.build(lines: lines, filter: .everything, expanded: [])
        #expect(rows.count == 20)
        #expect(rows.allSatisfy { if case .line = $0 { return true }; return false })
    }

    /// …but under "Important" they do fold, because they are not important —
    /// and a run with no HandBrake shape in it is labelled honestly.
    @Test func importantFoldsPlainLinesAndCallsThemOutput() {
        var lines: [LogLine] = []
        for index in 0..<20 { lines.append(Self.line(index, "MSG:1005,0,1,\"message \(index)\"")) }
        let rows = LogRows.build(lines: lines, filter: .important, expanded: [])
        #expect(labels(rows) == ["Output · 20 lines"])
    }

    // MARK: - Labels

    @Test func labelNamesTheThreeShapesItCanTellApart() {
        func label(_ texts: [String]) -> String {
            let lines = texts.enumerated().map { Self.line($0.offset, $0.element) }
            return LogRows.label(for: lines[...])
        }
        #expect(label(["x265 [info]: a", "x265 [warning]: b"]) == "x265 settings")
        #expect(label(["libdvdread: Couldn't find device name.", "libdvdnav: Can't read name block."]) == "libdvdnav")
        #expect(label(["x265 [info]: a", "[11:03:41] scan: b"]) == "HandBrake output")
        #expect(label(["MSG:1005,0,1,\"x\""]) == "Output")
    }

    @Test func anEmptyLogProducesNoRows() {
        #expect(LogRows.build(lines: [], filter: .important, expanded: []).isEmpty)
        #expect(LogRows.build(lines: [], filter: .everything, expanded: []).isEmpty)
    }
}
