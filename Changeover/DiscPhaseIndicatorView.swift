import SwiftUI

/// #0165 — the five phases of a disc's visit, drawn as a row that fills in.
///
/// The window has always shown one screen at a time with no sense of how many
/// there are, so a person watching a disc had no way to say "it is on 3 of 5"
/// — and on a disc holding two films, no way to tell that the screen in front
/// of them was the middle of something rather than the end of it.
///
/// Everything it shows is `DiscPhaseIndicator`, a pure function of the step
/// and the scan, which is the only coverage a view can have in this project
/// (`docs/ui-test-crash-prevention.md`).
///
/// Height is a constant and a small one. `docs/window-sizing.md` §2: the
/// hosting view publishes the root's minimum as the window's
/// `contentMinSize`, so anything in this strip that grew with content would
/// be #0140 again. One line of `.caption2`, fixed, no wrapping.
struct DiscPhaseIndicatorView: View {
    let current: DiscPhase

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(DiscPhaseIndicator.steps(current: current).enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(step.mark))
                        .frame(width: 6, height: 6)
                    Text(step.phase.title)
                        .font(.caption2)
                        .fontWeight(step.mark == .current ? .semibold : .regular)
                        .foregroundStyle(step.mark == .upcoming ? Color.secondary : .primary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiscPhaseIndicator.caption(current).detail ?? current.title)
        .help(DiscPhaseIndicator.caption(current).plain)
    }

    private func color(_ mark: DiscPhaseIndicator.Mark) -> Color {
        switch mark {
        case .done:     return .secondary
        case .current:  return .accentColor
        case .upcoming: return Color.secondary.opacity(0.3)
        }
    }
}
