import SwiftUI

/// The one control that switches the whole app between its two registers
/// (`docs/plain-language-ui.md` §1.4).
///
/// A `Button` styled as a link with a chevron, not a SwiftUI
/// `DisclosureGroup` bound to `@State`: the state has to be the shared,
/// persisted `AppSettings.showsDetails`, and the same control must read
/// identically on Confirm, Ripping, Done and Settings.
///
/// Its content is laid out **inside the step's own scroller**, never in the
/// action bar, so opening it can never raise the window's published minimum
/// height (#0140). `WindowSizing.heightClass(for:)` keys on the step and
/// knows nothing about this flag, which is that rule doing its job.
struct DetailsDisclosure<Content: View>: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(settings.showsDetails ? 90 : 0))
                    Text(settings.showsDetails ? "Hide details" : "Details")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityLabel("Details")
            .accessibilityValue(settings.showsDetails ? "shown" : "hidden")
            .accessibilityHint("Shows the exact reasons and technical values.")

            if settings.showsDetails {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle() {
        if reduceMotion {
            settings.showsDetails.toggle()
        } else {
            withAnimation { settings.showsDetails.toggle() }
        }
        // Persisted on toggle, the way `choosePlexRoot()` already writes
        // immediately — but only this one key, so the Settings window's
        // unsaved edits are not swept along with it.
        settings.persistShowsDetails()
    }
}

/// Renders one `Wording`: the plain line, and — with Details open — the
/// verbatim precise sentence beneath it, so a screen reader hears the plain
/// sentence first and can move on.
struct WordingText: View {
    @Environment(AppSettings.self) private var settings

    let wording: Wording
    var font: Font = .subheadline
    /// The plain line's colour, where a step tints it (#0056's orange guess,
    /// a red failure). The detail line is always secondary.
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(wording.plain)
                .font(font)
                .foregroundStyle(tint ?? Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.showsDetails, let detail = wording.detail, detail != wording.plain {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A line that exists only in the detail register: shown verbatim with
/// Details open, and nothing at all with it closed.
struct DetailOnlyText: View {
    @Environment(AppSettings.self) private var settings

    let text: String
    var font: Font = .caption
    var tint: Color?

    var body: some View {
        if settings.showsDetails {
            Text(text)
                .font(font)
                .foregroundStyle(tint ?? Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
