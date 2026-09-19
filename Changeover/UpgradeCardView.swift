import SwiftUI

/// §7.3 — the comparison card under the duplicate notice: what the file in
/// Plex has now, what this disc offers, and the one button that closes the
/// gap without re-encoding anything.
///
/// Thin, like `DuplicateNoticeView`: every sentence comes from
/// `UpgradePresentation.card`, which is pure and pinned by tests. It sits
/// inside the Confirm step's single `ScrollView`, so however many rows a disc
/// produces it can never push Start off-screen (#0140).
struct UpgradeCardView: View {
    let card: UpgradePresentation.Card
    @Binding var overwriteExistingNames: Bool
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.headline)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                UpgradeRowView(row: row)
            }

            if let footnote = card.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if card.offersOverwriteToggle {
                Toggle(UpgradePresentation.overwriteToggleTitle, isOn: $overwriteExistingNames)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }

            if card.offersUpgrade {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if let reason = card.disabledReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.trailing)
                    }
                    Button(card.actionTitle, action: onUpgrade)
                        .font(.caption)
                        .disabled(card.disabledReason != nil)
                        .help(card.disabledReason ?? "Rewrite this file's metadata in place. The video and audio are copied untouched.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.separatorColor).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.separatorColor)))
    }
}

/// One comparison line. The verdict carries its own reason, so a refusal is
/// never a silent blank — the whole point of §7.3's count-mismatch rule is
/// that both numbers end up on screen.
private struct UpgradeRowView: View {
    let row: UpgradeRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.label)
                    .font(.caption.weight(.semibold))
                    .frame(width: 66, alignment: .leading)
                Text("now: \(row.now)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(row.fromDisc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(mark)
                    .font(.caption)
                    .foregroundStyle(tone)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 72)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mark: String {
        switch row.verdict {
        case .upgrade:    return "✓ upgrade"
        case .unchanged:  return "—"
        case .refused:    return "not upgraded"
        case .needsRerip: return "needs a re-rip"
        }
    }

    private var tone: Color {
        switch row.verdict {
        case .upgrade:   return .green
        case .unchanged: return .secondary
        default:         return .orange
        }
    }

    private var detail: String? {
        switch row.verdict {
        case .refused(let reason), .needsRerip(let reason): return reason
        case .upgrade, .unchanged: return nil
        }
    }
}
