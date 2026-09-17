import SwiftUI

/// #0027 — audio track selection for the settled feature title, plus (#0033)
/// a read-only list of its subtitle groups. Sits under `DiscTitleListView`'s
/// verdict row and appears only once a title is selected — an unselected
/// title has no tracks to offer.
///
/// Thin by design, matching `DiscTitleListView`: every decision (which
/// tracks exist, which are duplicates, which are preselected, how subtitle
/// variants collapse) is `AudioTrackOptions` or `SubtitleGrouping`, both
/// tested standalone. This view only lays rows out and binds
/// `jobs.selectedAudioTrackNumbers` directly with `@Bindable` — no `@State`
/// copy, no `ObservableObject`.
///
/// No subtitle selection here: Phase 2's output carries no subtitle track at
/// all (#0014 §5), so the subtitle rows are informational only. #0036 is the
/// follow-on that adds a real subtitle field.
struct TrackSelectionView: View {
    @Bindable var jobs: JobController
    let settings: AppSettings
    let title: DiscTitle

    /// #0140 — the subtitle list is reference-only (#0036) and was the
    /// worst offender for pushing `Start Ripping` off-screen (21 rows on
    /// the disc that filed this issue). Collapsed by default; only its
    /// one-line `DiscTitleFormatting.subtitleSummary` shows until expanded.
    @State private var subtitlesExpanded = false

    private var audioOptions: [AudioTrackOption] { AudioTrackOptions.options(for: title) }
    private var isUntagged: Bool { AudioTrackOptions.isUntagged(title) }
    private var subtitleGroups: [SubtitleGroup] { SubtitleGrouping.groups(for: title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            audioSection
            if !subtitleGroups.isEmpty {
                subtitleSection
            }
        }
    }

    // MARK: - Audio

    /// #0140: the list itself gets a sensible maximum height (a disc with
    /// many audio tracks — the filing disc had 7 — otherwise grows this
    /// section without bound, same failure mode as the subtitle list). A
    /// nested `ScrollView` rather than a `List`: these rows are checkbox
    /// toggles, not a selectable table, and the outer window body already
    /// nests one scroll region inside another for the #0043 log pane, so
    /// this isn't a new pattern in this view tree.
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Audio")
                .font(.headline)
            if let notice = AudioTrackOptions.notice(
                options: audioOptions,
                preferred: settings.preferredAudioLanguages,
                untagged: isUntagged,
                selected: jobs.selectedAudioTrackNumbers
            ) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(audioOptions) { option in
                        Toggle(isOn: audioBinding(for: option)) {
                            audioLabel(for: option)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private func audioBinding(for option: AudioTrackOption) -> Binding<Bool> {
        Binding(
            get: { jobs.selectedAudioTrackNumbers.contains(option.trackNumber) },
            set: { isOn in
                jobs.selectedAudioTrackNumbers = AudioTrackOptions.toggling(
                    jobs.selectedAudioTrackNumbers,
                    trackNumber: option.trackNumber,
                    isOn: isOn,
                    options: audioOptions
                )
            }
        )
    }

    private func audioLabel(for option: AudioTrackOption) -> some View {
        HStack(spacing: 6) {
            Text(Self.languageLabel(option.languageCode, fallback: option.displayName))
                .font(.system(.body, design: .monospaced))
            if !option.duplicateTrackNumbers.isEmpty {
                Text("\(option.duplicateTrackNumbers.count + 1) tracks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if option.isCommentary {
                Text("Commentary")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Subtitles (read-only, #0033 — #0036 makes these selectable)

    /// #0140: collapsed by default behind a disclosure — a disc with many
    /// subtitle tracks (21 on the disc that filed this issue, each its own
    /// "cannot become an MP4 track" row) was the single biggest contributor
    /// to the window growing past the screen. The label alone, from
    /// `DiscTitleFormatting.subtitleSummary` (unit-tested), carries the
    /// "purely informational" fact that used to be a separate caption line.
    private var subtitleSection: some View {
        DisclosureGroup(isExpanded: $subtitlesExpanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(subtitleGroups) { group in
                    Text(Self.subtitleRowText(for: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 3)
        } label: {
            Text(DiscTitleFormatting.subtitleSummary(count: subtitleGroups.count))
                .font(.subheadline)
        }
    }

    private static func subtitleRowText(for group: SubtitleGroup) -> String {
        var parts = [languageLabel(group.languageCode, fallback: group.languageName ?? "Track \(group.selectedTrackNumber)")]
        if group.isForced { parts.append("forced") }
        if group.isCommentary { parts.append("commentary") }
        parts.append(group.isText ? "text — not wired to the output yet" : "bitmap — cannot become an MP4 track")
        return parts.joined(separator: " · ")
    }

    private static func languageLabel(_ code: String?, fallback: String) -> String {
        guard let code, let name = Locale.current.localizedString(forLanguageCode: code) else {
            return fallback
        }
        return name
    }
}
