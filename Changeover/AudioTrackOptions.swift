import Foundation

/// #0027 — turns a scanned title's raw audio streams into the rows a picker
/// shows, and decides which ones are preselected.
///
/// Pure, `nonisolated`: a plain function from `DiscTitle` to options — no
/// disc, no process, no UI import — the same seam as `SubtitleGrouping` and
/// `DiscTitleFormatting`. `LanguageCode.normalize` (`Changeover/LanguageCode.swift`,
/// #0029) is reused rather than redefined here, per that type's own doc
/// comment.
nonisolated struct AudioTrackOption: Equatable, Sendable, Identifiable {
    /// The HandBrake `TrackNumber` of the first (kept) occurrence — what
    /// `EncodeController.AudioSelection.tracks` receives.
    var trackNumber: Int
    /// Identical *tagged* tracks merged into this row, beyond the first —
    /// e.g. `[3]` when tracks 1 and 3 are the same offering, so the UI can
    /// say "2 tracks". Always empty for an untagged track (untagged streams
    /// are never merged — see `options(for:)`).
    var duplicateTrackNumbers: [Int]
    /// Normalized (`LanguageCode.normalize`). `nil` means untagged.
    var languageCode: String?
    /// `DiscStream.displayName`, else `.languageName`, else `"Track N"` —
    /// never blank.
    var displayName: String
    var isCommentary: Bool
    var id: Int { trackNumber }
}

nonisolated enum AudioTrackOptions {
    /// Lists a title's audio streams, in `TrackNumber` order, collapsing
    /// duplicates.
    ///
    /// **Tagged streams** are merged on `(languageCode, codecId, bitrate,
    /// channelCount, flags, displayName)`, keeping the first occurrence —
    /// `flags` is part of the key so a commentary can never merge into a
    /// plain track that otherwise looks identical (Super Troopers 2's
    /// unflagged commentary aside, which has no metadata that could
    /// distinguish it in the first place).
    ///
    /// **Untagged streams are never merged**, even when two of them are
    /// otherwise byte-for-byte identical metadata (Hornets' Nest's two
    /// untagged `DD Surround 5.1` tracks): identical-looking untagged audio
    /// is exactly what a Swedish original plus an English dub looks like,
    /// and merging them would silently drop a language.
    nonisolated static func options(for title: DiscTitle) -> [AudioTrackOption] {
        let audioStreams = title.streams
            .filter { $0.kind == .audio }
            .sorted { $0.index < $1.index }

        var result: [AudioTrackOption] = []
        var indexForKey: [MergeKey: Int] = [:]

        for stream in audioStreams {
            let normalizedCode = LanguageCode.normalize(stream.languageCode)
            let displayName = stream.displayName ?? stream.languageName ?? "Track \(stream.index)"

            if let normalizedCode {
                let key = MergeKey(
                    languageCode: normalizedCode,
                    codecId:      stream.codecId,
                    bitrate:      stream.bitrate,
                    channelCount: stream.channelCount,
                    flags:        stream.flags,
                    displayName:  displayName
                )
                if let existingIndex = indexForKey[key] {
                    result[existingIndex].duplicateTrackNumbers.append(stream.index)
                    continue
                }
                indexForKey[key] = result.count
            }

            result.append(AudioTrackOption(
                trackNumber:            stream.index,
                duplicateTrackNumbers:  [],
                languageCode:           normalizedCode,
                displayName:            displayName,
                isCommentary:           stream.isCommentary
            ))
        }

        return result
    }

    /// True when no audio stream on `title` carries a language tag at all —
    /// the whole-title fallback (Hornets' Nest): the language preference
    /// does not apply, and every non-commentary track should be kept rather
    /// than falling back to "first track only", which would silently drop a
    /// language on a disc with (say) an English and a Spanish track.
    nonisolated static func isUntagged(_ title: DiscTitle) -> Bool {
        !title.streams.contains {
            $0.kind == .audio && LanguageCode.normalize($0.languageCode) != nil
        }
    }

    /// Which track numbers should be preselected.
    ///
    /// #0059 re-examined this against the user's own evidence: Hornet's
    /// Nest's two untagged 448 kbps tracks became two copies of nearly a
    /// gigabyte each under the old "keep every match" rule, because
    /// `EncodeController` used to copy every selected track at its own
    /// bitrate. Now that every selected track is instead encoded to one AAC
    /// stereo track (#0059's `AudioSelection.tracks`), a second preselected
    /// track is cheaper than it was — but still doubles a file's audio for
    /// no reason on the common case, which is a duplicate mix, not a second
    /// language. So the rule is now **one track by default, on every
    /// title, tagged or not** — the user can still tick more in the picker;
    /// only the *default* changed.
    ///
    /// - On an untagged title, the first non-commentary option is selected
    ///   (or, if every option happens to be flagged commentary, the first
    ///   option). Previously this selected *every* non-commentary option —
    ///   see above.
    /// - Otherwise, the first non-commentary option in `preferred`
    ///   (normalized) is selected — previously every matching option was.
    /// - If nothing matches, the first non-commentary option is selected —
    ///   silently producing a movie with no audio is the worst outcome
    ///   available here.
    /// - If every option is a commentary, the first option is selected.
    /// - Never `[]` when `options` is non-empty.
    nonisolated static func preselection(
        _ options: [AudioTrackOption],
        preferred: [String],
        untagged: Bool
    ) -> [Int] {
        let nonCommentary = options.filter { !$0.isCommentary }

        if untagged {
            if let first = nonCommentary.first { return [first.trackNumber] }
            if let first = options.first { return [first.trackNumber] }
            return []
        }

        let normalizedPreferred = Set(preferred.compactMap(LanguageCode.normalize))
        let matched = nonCommentary.first { option in
            guard let code = option.languageCode else { return false }
            return normalizedPreferred.contains(code)
        }
        if let matched {
            return [matched.trackNumber]
        }
        if let first = nonCommentary.first {
            return [first.trackNumber]
        }
        if let first = options.first {
            return [first.trackNumber]
        }
        return []
    }

    /// #0027 review: true when `title` has audio but `selected` is empty.
    ///
    /// An empty `RipRequest.audioTrackNumbers` becomes `.tracks([])`, which
    /// `EncodeController.audioArguments` turns into `.sourceDefault`, so
    /// HandBrake would encode the disc's first track while every checkbox in
    /// the picker shows unchecked. `StartGate` and `JobController.start` both
    /// refuse this state, so the output always matches what the picker shows.
    nonisolated static func isSelectionMissingAudio(_ title: DiscTitle, selected: [Int]) -> Bool {
        selected.isEmpty && title.streams.contains { $0.kind == .audio }
    }

    /// The selection after the user toggles `trackNumber`, in the order
    /// `options` lists the tracks (disc order).
    ///
    /// Order matters: the first selected track is the one that gets the AAC
    /// stereo copy (#0029). Appending in click order would let unchecking and
    /// re-checking English move French into that slot with nothing on screen
    /// to show it.
    nonisolated static func toggling(
        _ selected: [Int],
        trackNumber: Int,
        isOn: Bool,
        options: [AudioTrackOption]
    ) -> [Int] {
        var set = Set(selected)
        if isOn { set.insert(trackNumber) } else { set.remove(trackNumber) }
        return options.map(\.trackNumber).filter(set.contains)
    }

    /// The one caption under the Audio heading, or `nil` when the selection
    /// needs no explanation. It explains why the tracks that start selected
    /// were chosen, and warns when nothing is selected.
    nonisolated static func notice(
        options: [AudioTrackOption],
        preferred: [String],
        untagged: Bool,
        selected: [Int]
    ) -> String? {
        if options.isEmpty {
            return "No audio tracks reported for this title."
        }
        if selected.isEmpty {
            return "No audio track selected. Choose at least one to start."
        }
        if untagged {
            return "This disc does not tag its audio languages, so only the first track starts selected. Tick more if this disc carries more than one language."
        }
        let normalizedPreferred = preferred.compactMap(LanguageCode.normalize)
        let matchesPreference = options.contains { option in
            guard !option.isCommentary, let code = option.languageCode else { return false }
            return normalizedPreferred.contains(code)
        }
        if !matchesPreference {
            if normalizedPreferred.isEmpty {
                return "No preferred audio languages are set, so the first track starts selected."
            }
            return "None of your preferred languages (\(normalizedPreferred.joined(separator: ", "))) is on this title, so the first track starts selected."
        }
        return nil
    }

    private struct MergeKey: Hashable {
        var languageCode: String
        var codecId: String
        var bitrate: String?
        var channelCount: Int?
        var flags: Int
        var displayName: String
    }
}
