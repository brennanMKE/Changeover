import AppKit
import SwiftUI

/// #0143 — the "already in Plex" panel on the Confirm step.
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
    @Environment(AppSettings.self) private var settings

    let notice: DuplicateNotice
    let onReplace: () -> Void
    let onRecheck: () -> Void
    /// #0186 — "Import Just the Extras". Defaulted to a no-op so the preview
    /// and the screenshot harness need not supply one; production passes
    /// `RipFlowController.acknowledgeExtrasOnly`.
    var onExtrasOnly: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(notice.tone.color)
                // The plain headline always leads, so a screen reader hears
                // the short sentence first.
                Text(notice.plainHeadline)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notice.plainLines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The verbatim headline, the file line (`name · size · added
            // date`) and the folder path, under Details.
            if settings.showsDetails {
                ForEach([notice.headline] + notice.lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if notice.offersReplace || notice.offersRecheck || notice.offersExtrasOnly {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if notice.offersRecheck {
                        Button("Check again", action: onRecheck)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if let path = notice.revealPath, notice.offersReplace {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .font(.caption)
                    }
                    // #0186 — the non-destructive answer, and the reason it
                    // comes first and is not the default action: it is the one
                    // of the two that cannot lose anything, so it should be the
                    // easier one to reach, while the irreversible one stays
                    // where the reflex already expects it.
                    if notice.offersExtrasOnly {
                        Button("Import Just the Extras", action: onExtrasOnly)
                            .font(.caption)
                            .help("Encode the ticked extras into this film's folder in Plex. The film's own file is not read, moved or replaced.")
                    }
                    if notice.offersReplace {
                        // The label says exactly what will happen. Start stays
                        // disabled until this is pressed: the step flow was
                        // designed for "type, Return, Return", and a banner
                        // cannot stop a reflex — a disabled button can.
                        Button("Replace the Existing File", action: onReplace)
                            .font(.caption)
                            // #0186: said plainly, now that there is a button
                            // beside it that does not.
                            .help("Rip the whole film again and overwrite the copy already in Plex.")
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
