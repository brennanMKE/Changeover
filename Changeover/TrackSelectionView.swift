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

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Audio")
                .font(.headline)
            if isUntagged {
                Text("This disc does not tag its audio languages — keeping all tracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if audioOptions.isEmpty {
                Text("No audio tracks reported for this title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(audioOptions) { option in
                Toggle(isOn: audioBinding(for: option)) {
                    audioLabel(for: option)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func audioBinding(for option: AudioTrackOption) -> Binding<Bool> {
        Binding(
            get: { jobs.selectedAudioTrackNumbers.contains(option.trackNumber) },
            set: { isOn in
                if isOn {
                    if !jobs.selectedAudioTrackNumbers.contains(option.trackNumber) {
                        jobs.selectedAudioTrackNumbers.append(option.trackNumber)
                    }
                } else {
                    jobs.selectedAudioTrackNumbers.removeAll { $0 == option.trackNumber }
                }
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

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Subtitles")
                .font(.headline)
            Text("Not carried into the output yet — shown for reference.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(subtitleGroups) { group in
                Text(Self.subtitleRowText(for: group))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
