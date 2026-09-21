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

    /// The advisory line from the disc's Languages menu, or `nil` — which is
    /// the usual answer, because most discs tag their tracks and most menu
    /// reads never happen.
    private var menuLanguageHint: String? {
        MenuAudioHint.line(jobs.menuState.intelligence?.languages)
    }

    /// The verbatim audio caption — the detail register's half of the pair.
    private var audioNotice: String? {
        AudioTrackOptions.notice(
            options: audioOptions,
            preferred: settings.preferredAudioLanguages,
            untagged: isUntagged,
            selected: jobs.selectedAudioTrackNumbers
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            audioSection
            if !subtitleGroups.isEmpty {
                subtitleSection
            }
        }
    }

    // MARK: - Audio

    /// #0140 review: **deliberately not scrollable and not height-capped.**
    /// The first pass put these rows in a nested `ScrollView` capped at 160
    /// points, which traded one bug for two: the disc that filed the issue
    /// has 7 audio tracks, which do not fit in 160 points, so ticking the
    /// last one meant scrolling a box inside a box; and on macOS a nested
    /// scroller swallows the wheel/trackpad gesture while the pointer is
    /// over it, so a window full of inner scrollers is a window the user
    /// cannot scroll. These rows are the one control on this screen the
    /// user *must* operate, so they lay out at natural height and the
    /// window body's single `ScrollView` (`ConfirmStepView.body`) carries
    /// them. That is safe now in a way it was not before this issue: the
    /// outer scroll view's *minimum* height is nil, so however many tracks
    /// the disc has, the section can no longer push the window past the
    /// screen — which was the whole bug.
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Audio")
                .font(.headline)
            // `docs/plain-language-ui.md` §3.5. The plain sentence names the
            // control; the verbatim one — which is the diagnostic record of
            // #0059's one-track default — sits under it with Details open.
            // The "no preferred languages are set" case has no plain form at
            // all: it explains why the default is the default, which is
            // nothing the person has to decide (rule 7).
            if let plain = AudioTrackOptions.plainNotice(
                options: audioOptions,
                preferred: settings.preferredAudioLanguages,
                untagged: isUntagged,
                selected: jobs.selectedAudioTrackNumbers
            ) {
                WordingText(
                    wording: Wording(plain: plain, detail: audioNotice),
                    font: .caption
                )
            } else if let detail = audioNotice {
                DetailOnlyText(text: detail)
            }
            // Menu intelligence (§5.3): what the disc's own Languages menu
            // prints, beside the picker and nothing more. It never changes
            // the preselection, never sets a language on an untagged stream
            // and never merges tracks — an ordered list of names is not a
            // mapping, and on the one disc measured no single OCR
            // configuration even read the whole list.
            //
            // Detail only since `docs/plain-language-ui.md`: what the disc's
            // menu prints is never a mapping and never changes a track, so
            // there is nothing here for a person to act on.
            if let hint = menuLanguageHint {
                DetailOnlyText(text: hint)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(audioOptions) { option in
                    Toggle(isOn: audioBinding(for: option)) {
                        audioLabel(for: option)
                    }
                    .toggleStyle(.checkbox)
                }
            }
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
            // Proportional, not monospaced: this is a language, not a
            // terminal column, and the monospaced style read as one.
            Text(Self.languageLabel(option.languageCode, fallback: option.displayName))
                .font(.body)
            if !option.duplicateTrackNumbers.isEmpty, settings.showsDetails {
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
    ///
    /// `docs/plain-language-ui.md` §3.3: with Details off this whole section
    /// collapses to one constant caption — the #0036 fact about the *output*,
    /// which is the surprise a person needs to hear once. The count and the
    /// per-track rows are detail.
    @ViewBuilder
    private var subtitleSection: some View {
        if settings.showsDetails {
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
        } else {
            Text(DiscTitleFormatting.plainSubtitleLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func subtitleRowText(for group: SubtitleGroup) -> String {
        var parts = [languageLabel(group.languageCode, fallback: group.languageName ?? "Track \(group.selectedTrackNumber)")]
        if group.isForced { parts.append("forced") }
        if group.isCommentary { parts.append("commentary") }
        parts.append(group.isText ? "text — not wired to the output yet" : "bitmap — cannot become an MP4 track")
        return parts.joined(separator: " · ")
    }

    /// `PlainLanguage.languageName` is the one lookup, shared with the disc
    /// table's plain column so the picker and the table can never name the
    /// same language two different ways.
    private static func languageLabel(_ code: String?, fallback: String) -> String {
        PlainLanguage.languageName(code) ?? fallback
    }
}
