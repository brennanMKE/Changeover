import AppKit
import SwiftUI

/// #0153 — the screen that says why the app took a disc out.
///
/// Reached only when the drive is empty *because the app emptied it* for a
/// reason the user did not ask for. A finished rip does not come here — the
/// Done step already explains that one — and neither does an eject the user
/// clicked, because they know why that happened.
///
/// Every sentence comes from `EjectExplanation`, which is pure and tested. The
/// view formats nothing and decides nothing: on the two occasions this screen
/// exists for, the failure was that the reason was computed and then thrown
/// away, so the reason and its presentation are deliberately the same value.
struct EjectedStepView: View {
    @Environment(JobController.self) private var jobs

    let explanation: EjectExplanation

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "eject.circle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(explanation.headline)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(explanation.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // The "if this looks wrong" half. Set apart rather than run into
            // the paragraph above, because it is the part the user needs when
            // they disagree with the decision — which is the case that sent
            // them hunting for a bug the first two times this happened.
            Text(explanation.advice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            Text("Put the next disc in when you are ready.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
