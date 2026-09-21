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
    /// does not apply, so `preselection` cannot use it and `notice` says so
    /// instead. #0059 review: this used to go on to say every non-commentary
    /// track is kept on such a title. It no longer is — #0059 made the
    /// default one track everywhere — and the compensating honesty is
    /// `notice`'s untagged message, which tells the user to tick more if the
    /// disc carries a second language. Do not read this flag as "keep
    /// everything"; it only means "the language preference has nothing to
    /// match against here".
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
    /// Order matters: it is the order of `--audio`, and so the order of the
    /// output file's audio streams — the first selected track becomes the
    /// first stream, which is the one many players pick by default.
    /// Appending in click order would let unchecking and re-checking English
    /// move French into that slot with nothing on screen to show it.
    /// (Pre-#0059 this mattered for a second reason: the first track was the
    /// only one that got an AAC copy. #0059 gives every selected track its
    /// own AAC encode, so only the stream order still rides on this.)
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
        if let missing = unselectedPreferredLanguages(
            options: options,
            normalizedPreferred: normalizedPreferred,
            selected: selected
        ) {
            return "\(missing.joined(separator: ", ")) is also on this title and one of your preferred languages, but only one track starts selected — tick it to keep it too."
        }
        return nil
    }

    /// `docs/plain-language-ui.md` §3.5 — the plain sibling of `notice`,
    /// case for case, with `notice`'s own wording kept verbatim as the
    /// detail.
    ///
    /// `nil` for the "no preferred languages are set" case as well as for
    /// `notice`'s own `nil`: a caption whose only content is why the default
    /// is the default gives the person nothing to decide (rule 7), so it is
    /// detail only. Every other case names the control — "tick" — because
    /// the checkbox beside it is the whole point.
    nonisolated static func plainNotice(
        options: [AudioTrackOption],
        preferred: [String],
        untagged: Bool,
        selected: [Int]
    ) -> String? {
        if options.isEmpty {
            return "This part of the disc has no sound."
        }
        if selected.isEmpty {
            return "Tick at least one audio track to start."
        }
        if untagged {
            return "The disc doesn't say which language each track is. The first is ticked; tick others if you want them too."
        }
        let normalizedPreferred = preferred.compactMap(LanguageCode.normalize)
        let matchesPreference = options.contains { option in
            guard !option.isCommentary, let code = option.languageCode else { return false }
            return normalizedPreferred.contains(code)
        }
        if !matchesPreference {
            // No preference set at all is not news; none of the preferences
            // being on this disc is.
            guard !normalizedPreferred.isEmpty else { return nil }
            return "None of your usual languages is on this disc, so the first track is ticked."
        }
        if let missing = unselectedPreferredLanguages(
            options: options,
            normalizedPreferred: normalizedPreferred,
            selected: selected
        ) {
            // Names, not ISO codes: "Spanish", never "spa".
            let names = missing.map { PlainLanguage.languageName($0) ?? $0 }
            let verb = names.count == 1 ? "is" : "are"
            return "\(PlainLanguage.andList(names)) \(verb) also on this disc. Tick \(names.count == 1 ? "it" : "them") if you want to keep \(names.count == 1 ? "it" : "them")."
        }
        return nil
    }

    /// #0059 review — the tagged-disc half of "don't drop a second language
    /// silently".
    ///
    /// #0059 made `preselection` pick exactly **one** track, which is right
    /// for the common case (a duplicate mix) and is the user's measured
    /// decision. But on a title that genuinely carries two of the languages
    /// the user asked for — `preferredAudioLanguages` defaults to
    /// `["eng", "spa"]`, and a Region 1 DVD with an English and a Spanish
    /// track is ordinary — the old rule selected both and the new one
    /// selects the first, with nothing on screen to say the other was
    /// dropped. `notice` said nothing here, because before #0059 there was
    /// nothing to say. The untagged case got a reworded caption; this is the
    /// same honesty for the tagged case.
    ///
    /// - Returns: the preferred language codes present on a non-commentary
    ///   option but absent from `selected`, in disc order — or `nil` when
    ///   every preferred language present is already covered. Keyed on
    ///   *language*, not track, so two English tracks (a 5.1 and a 2.0
    ///   downmix — Oppenheimer's shape) stay quiet: dropping the second is
    ///   exactly what #0059 wants, and it is not a lost language.
    nonisolated private static func unselectedPreferredLanguages(
        options: [AudioTrackOption],
        normalizedPreferred: [String],
        selected: [Int]
    ) -> [String]? {
        let preferredSet = Set(normalizedPreferred)
        let selectedSet = Set(selected)
        var selectedCodes = Set<String>()
        for option in options where selectedSet.contains(option.trackNumber) {
            if let code = option.languageCode { selectedCodes.insert(code) }
        }

        var missing: [String] = []
        var seen = Set<String>()
        for option in options where !option.isCommentary {
            guard let code = option.languageCode,
                  preferredSet.contains(code),
                  !selectedCodes.contains(code),
                  seen.insert(code).inserted
            else { continue }
            missing.append(code)
        }
        return missing.isEmpty ? nil : missing
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
