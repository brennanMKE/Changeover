import AppKit
import SwiftUI

/// #0062 — one job's log, filtered and folded.
///
/// The old view painted every row of `JobLog.displayLines` in one of two
/// tones, so 23 lines of `x265 [info]:` build settings and
/// `libdvdread: Couldn't find device name.` sat on exactly the same footing as
/// the four lines that say what happened. Now each line carries a
/// `LogCategory` (decided once, at append time) and the rows come from
/// `LogRows.build` — a pure function of `(lines, filter, expanded runs)`. The
/// live progress line is a pinned footer rather than a scrolling row, so the
/// tail stays readable.
///
/// Everything this view decides is in `LogRows`/`LogCategory`; what is left
/// here is a `switch` and some layout.
struct LogPane: View {
    let log: JobLog
    /// The filed `.mp4` of a succeeded job, if there is one.
    let revealURL: URL?
    /// Puts the card plus the whole *unfiltered* log on the pasteboard.
    let onCopy: () -> Void

    /// Display-only state, the same class as `DiscTitleListView.showFullTable`.
    /// Not persisted across launches — cut, on purpose, to land this.
    @State private var filter: LogFilter = .important
    @State private var expanded: Set<Int> = []
    /// Pins to the newest line only while the user hasn't scrolled away.
    @State private var isAtBottom = true

    var body: some View {
        let rows = LogRows.build(lines: lines, filter: filter, expanded: expanded)
        VStack(alignment: .leading, spacing: 0) {
            bar
            Divider()
            if log.droppedCount > 0 {
                Text("… \(log.droppedCount) earlier lines dropped")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Divider()
            }
            scroller(rows: rows)
            if let progress = log.latestProgress {
                Divider()
                Text(progress.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
        }
    }

    /// `displayLines` minus the coalesced progress line, which the footer
    /// above renders instead.
    private var lines: [LogLine] {
        log.displayLines.filter { $0.category != .progress }
    }

    // MARK: - The pane's own bar

    private var bar: some View {
        HStack(spacing: 10) {
            Text("Log")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $filter) {
                ForEach(LogFilter.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer(minLength: 8)
            if let revealURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Button("Copy Log", action: onCopy)
                .font(.caption)
                .help("Copy this job's summary and its whole unfiltered log.")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Rows

    private func scroller(rows: [LogRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        rowView(row).id(row.id)
                    }
                    // A zero-height sentinel at the very bottom: while it is
                    // on screen the user is at the bottom, and a new line
                    // should still scroll into view.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(8)
            }
            .background(Color(.textBackgroundColor))
            .onChange(of: rows.last?.id) { _, lastID in
                guard isAtBottom, let lastID else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: LogRow) -> some View {
        switch row {
        case .line(let line):
            Text(line.text)
                .font(.system(.caption2, design: .monospaced).weight(line.category == .section ? .bold : .regular))
                .foregroundStyle(color(for: line.category))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .collapsed(let run):
            Button {
                if expanded.contains(run.firstID) {
                    expanded.remove(run.firstID)
                } else {
                    expanded.insert(run.firstID)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded.contains(run.firstID) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(run.summary)
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The whole reason `LogCategory` exists: one colour per meaning, so a
    /// failure never reads like chatter and chatter never reads like a
    /// warning.
    private func color(for category: LogCategory) -> Color {
        switch category {
        case .section, .step, .success, .detail:
            return .primary
        case .failure, .toolError:
            return .red
        case .warning:
            return .orange
        case .encoder, .plain, .progress:
            return .secondary
        }
    }
}
