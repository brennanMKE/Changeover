import AppKit
import SwiftUI

/// #0062 — the "already in Plex" panel on the Confirm step.
///
/// `PlexOrganizer.move` replaces an existing library file on purpose (#0012's
/// staged `replaceItemAt`), so before this a re-rip of a film that is already
/// there silently overwrote it *after* a 40-minute encode. A re-rip is a real
/// workflow, not an error — so this makes the duplicate impossible to miss,
/// blocks Start until the replacement is confirmed, and makes that
/// confirmation one clear click rather than a dead end.
///
/// Thin: everything it says comes from `DuplicatePresentation.notice`.
/// It sits inside the Confirm step's single `ScrollView`, and the action bar
/// is outside that scroller, so it can never push Start off-screen (#0140).
struct DuplicateNoticeView: View {
    let notice: DuplicateNotice
    let onReplace: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(notice.tone.color)
                Text(notice.headline)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notice.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if notice.offersReplace || notice.offersRecheck {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if notice.offersRecheck {
                        Button("Check again", action: onRecheck)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if let path = notice.revealPath, notice.offersReplace {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .font(.caption)
                    }
                    if notice.offersReplace {
                        // The label says exactly what will happen. Start stays
                        // disabled until this is pressed: the step flow was
                        // designed for "type, Return, Return", and a banner
                        // cannot stop a reflex — a disabled button can.
                        Button("Replace the Existing File", action: onReplace)
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(notice.tone.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(notice.tone.color.opacity(0.35))
        )
    }

    private var symbol: String {
        switch notice.kind {
        case .checking:     return "ellipsis.circle"
        case .present:      return "exclamationmark.triangle"
        case .acknowledged: return "checkmark.circle"
        case .unreachable:  return "questionmark.circle"
        }
    }
}
