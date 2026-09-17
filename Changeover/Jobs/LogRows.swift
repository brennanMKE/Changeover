import Foundation

/// #0062 — which log rows the History window shows.
nonisolated enum LogFilter: String, Codable, Sendable, CaseIterable {
    /// The default: the pipeline's own milestones, warnings, errors and their
    /// detail lines, with every run of chatter folded into one clickable row.
    case important
    /// The raw scroll — except that a run of eight or more encoder lines
    /// still folds. The x265 preamble is 23 lines and a `[hh:mm:ss] scan:`
    /// run is hundreds; a raw view that is 90 % those is not "everything", it
    /// is nothing. **Copy Log** is always raw regardless (`JobLog.exportText`).
    case everything

    var title: String {
        switch self {
        case .important:  return "Important"
        case .everything: return "Everything"
        }
    }
}

/// One rendered row: a line, or a fold standing in for a run of them.
nonisolated enum LogRow: Identifiable, Equatable, Sendable {
    case line(LogLine)
    case collapsed(Run)

    /// A maximal run of consecutive lines the filter folds.
    nonisolated struct Run: Equatable, Sendable {
        /// The identity of the run, and the key in `LogRows.build`'s
        /// `expanded` set. A line id, so it is stable as the log grows.
        let firstID: Int
        let lastID: Int
        /// Exact — nothing is ever silently dropped from the view.
        let count: Int
        /// "x265 settings" / "libdvdnav" / "HandBrake output" / "Output".
        let label: String

        var summary: String { "\(label) · \(count) lines" }
    }

    /// Unique within one log: a line keeps its own id, a fold takes the
    /// negative of its first line's id, biased by one so line 0's fold is -1
    /// rather than colliding with line 0 itself.
    var id: Int {
        switch self {
        case .line(let line):    return line.id
        case .collapsed(let run): return -(run.firstID + 1)
        }
    }
}

/// #0062 — the pure function behind the log pane. Takes the lines, the
/// filter and the set of folds the user has opened; returns the rows. No
/// SwiftUI, no `JobLog` instance, no state of its own — which is the only
/// coverage this window can have, since UI tests are forbidden here
/// (`docs/ui-test-crash-prevention.md`).
nonisolated enum LogRows {

    /// A run of encoder chatter shorter than this stays inline under
    /// `.everything`: there is nothing to gain by folding four lines.
    static let everythingFoldThreshold = 8

    /// - Parameters:
    ///   - lines: `JobLog.displayLines` minus the progress line (the window
    ///     pins `latestProgress` as a footer instead of scrolling it away).
    ///   - expanded: the `Run.firstID`s the user has opened in place. An
    ///     expanded run still renders its own header row, now a disclosure
    ///     the user can close again, followed by its lines.
    static func build(lines: [LogLine], filter: LogFilter, expanded: Set<Int>) -> [LogRow] {
        var rows: [LogRow] = []
        rows.reserveCapacity(lines.count)

        var index = lines.startIndex
        while index < lines.endIndex {
            guard let runEnd = foldableRun(in: lines, from: index, filter: filter) else {
                rows.append(.line(lines[index]))
                index += 1
                continue
            }
            let slice = lines[index..<runEnd]
            let run = LogRow.Run(
                firstID: slice.first!.id,
                lastID:  slice.last!.id,
                count:   slice.count,
                label:   label(for: slice)
            )
            rows.append(.collapsed(run))
            if expanded.contains(run.firstID) {
                rows.append(contentsOf: slice.map(LogRow.line))
            }
            index = runEnd
        }
        return rows
    }

    /// The end index of the foldable run starting at `start`, or `nil` when
    /// the line there is not foldable under `filter`.
    ///
    /// - `.important` folds every maximal run of non-important lines, of any
    ///   length — `encoder` and `plain`, never `toolError` (that is important)
    ///   and never a milestone.
    /// - `.everything` folds only a run of `.encoder` lines, and only at
    ///   `everythingFoldThreshold` or longer.
    private static func foldableRun(in lines: [LogLine], from start: Int, filter: LogFilter) -> Int? {
        let foldable: (LogLine) -> Bool
        switch filter {
        case .important:  foldable = { !$0.category.isImportant }
        case .everything: foldable = { $0.category == .encoder }
        }
        guard foldable(lines[start]) else { return nil }

        var end = start
        while end < lines.endIndex, foldable(lines[end]) { end += 1 }

        if filter == .everything, end - start < everythingFoldThreshold { return nil }
        return end
    }

    /// What the fold calls itself. Shape-based, never content-based: the
    /// point is to tell the user what they are not reading.
    static func label(for run: ArraySlice<LogLine>) -> String {
        if run.allSatisfy({ $0.text.hasPrefix("x265 [") }) { return "x265 settings" }
        if run.allSatisfy({ $0.text.hasPrefix("libdvdnav:") || $0.text.hasPrefix("libdvdread:") }) { return "libdvdnav" }
        if run.contains(where: { LogClassifier.isEncoderChatter($0.text) }) { return "HandBrake output" }
        return "Output"
    }
}
