import SwiftUI

/// #0048 — one job's log, rendered from `JobLog.displayLines` (#0043): the
/// capped ring plus any milestone the ring has evicted, in arrival order,
/// with the most recent HandBrake/MakeMKV progress line placed by id.
///
/// Rows key on `LogLine.id`, which is unique only *within this log* — never
/// mixed into the same `ForEach` as another job's lines, unlike
/// `JobController.logDisplayRows` (the live/idle view in
/// `MetadataEntryView`), which merges two sources and needs the wider
/// `LogDisplayRow.ID`. A history row always shows exactly one job's own
/// `JobLog`, so the plain `LogLine.id` is enough here.
struct JobLogView: View {
    let log: JobLog

    /// Pins to the newest line only while the user hasn't scrolled away —
    /// yanking the view down while someone is reading a failure ten thousand
    /// lines back would be worse than no autoscroll (#0048's plan).
    @State private var isAtBottom = true

    var body: some View {
        let lines = log.displayLines
        VStack(alignment: .leading, spacing: 0) {
            if log.droppedCount > 0 {
                Text("… \(log.droppedCount) earlier lines dropped")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(line.isMilestone ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                        // A zero-height sentinel at the very bottom: while it
                        // is on screen, the user is at the bottom, and a new
                        // line should still scroll into view.
                        Color.clear
                            .frame(height: 1)
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(8)
                }
                .background(Color(.textBackgroundColor))
                .onChange(of: lines.last?.id) { _, lastID in
                    guard isAtBottom, let lastID else { return }
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}
