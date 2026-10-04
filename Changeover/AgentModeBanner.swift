import SwiftUI
import Combine

/// #0195 — the strip at the top of the rip window while an agent is driving.
///
/// Reported while an agent was importing bonus features from another Claude
/// session: "the Mac app does not reflect what is happening." It was not
/// malfunctioning — `changeoverctl watch` had suspended its automation exactly
/// as designed — but a window that has gone quiet because something else is in
/// charge looks the same as one that has gone wrong.
///
/// Deliberately a banner and not a badge. The app is in a different *mode*,
/// the mode has a cause and an end, and the user has to be able to see all
/// three without hunting: who is in charge, what they last asked for, and that
/// it stops when the session does.
struct AgentModeBanner: View {
    /// Optional on purpose. A non-`Observable` lookup traps when the object
    /// is absent, and it is legitimately absent in two places: a build with no
    /// bridge, and the app-hosted test host that renders this window without
    /// one. No bridge means no agent, which means no banner — the same answer
    /// the ordinary case gives.
    @Environment(AppXPCServer.self) private var bridge: AppXPCServer?

    /// Re-rendered on a timer so "2m ago" is true rather than true-once.
    /// One second is far finer than the text's resolution, which is the point:
    /// the line crosses from "just now" to "5s ago" without the user wondering
    /// whether the window has frozen.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let bridge, AgentMode.isActive(attachedSessions: bridge.sessionCount) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentMode.headline(attachedSessions: bridge.sessionCount))
                        .font(.subheadline.weight(.semibold))
                    if let line = AgentMode.activityLine(bridge.lastActivity, now: now) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // The detail register carries the "why nothing is
                    // happening by itself" sentence, which is the one a
                    // worried person needs and a comfortable one does not.
                    DetailOnlyText(text: AgentMode.explanation)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .onReceive(tick) { now = $0 }
            .accessibilityElement(children: .combine)
        }
    }
}
