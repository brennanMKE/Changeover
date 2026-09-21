import Foundation

/// #0026 — pure formatting/derivation helpers for the disc title list, kept
/// out of `DiscTitleListView` so they're unit-testable with no SwiftUI and no
/// disc.
nonisolated enum DiscTitleFormatting {
    /// `H:MM:SS`, e.g. 6645 seconds → "1:50:45" — the confirmation row's
    /// worked example in the Plan ("Title 3 · 1:50:45 · 21 chapters").
    static func duration(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    /// `ByteCountFormatter` in file style, e.g. "6.3 GB" — `nil` when the
    /// scan reported no size. `HandBrakeScanParser` sets `sizeBytes: 0` and
    /// documents `0 = unknown` (`HandBrakeScanParser.swift`); handing `0`
    /// straight to `ByteCountFormatter` renders "Zero KB", a stated-but-false
    /// value (#0038). Any non-positive byte count is treated as unknown.
    static func size(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The confirmation row's detail string, e.g. "Title 3 · 1:50:45 · 21
    /// chapters", or with a known size, "Title 3 · 1:50:45 · 21 chapters ·
    /// 6.8 GB" (#0038). The size segment is omitted entirely — never shown
    /// as "Zero KB" — when `size(_:)` returns `nil`.
    static func confirmationDetail(index: Int, title: DiscTitle) -> String {
        var segments = [
            "Title \(index)",
            duration(title.durationSeconds),
            "\(title.chapterCount) chapters",
        ]
        if let sizeText = size(title.sizeBytes) {
            segments.append(sizeText)
        }
        return segments.joined(separator: " · ")
    }

    /// The `.single` confirmation row's extras line (#0038): "Extras: none"
    /// until something is ticked, then "Extras: N · H:MM:SS" — the running
    /// total from the same `ExtrasPlan` the pipeline will actually encode,
    /// not a raw count of table rows.
    static func extrasStatusLine(_ plan: ExtrasPlan) -> String {
        guard !plan.items.isEmpty else { return "Extras: none" }
        return "Extras: \(plan.items.count) · \(duration(plan.totalDurationSeconds))"
    }

    /// "2 audio (eng, spa) · 1 sub" — must survive a title where **no**
    /// stream carries a language tag at all (`hornets-nest-min0.txt`'s
    /// feature has zero attribute-3 lines across every stream): the
    /// parenthetical is omitted entirely, never rendered as "()" or "(nil)".
    /// A single untagged stream among tagged siblings likewise contributes
    /// nothing to the parenthetical, since `orderedUniqueLanguages` only
    /// collects streams that actually carry a code.
    ///
    /// The subtitle count is the number of `SubtitleGrouping.groups(for:)`
    /// groups, not the raw stream count (#0033's #0026 handoff) — a raw
    /// count double-counts HandBrake's per-aspect-ratio variant pairs, e.g.
    /// Fargo's twelve VOBSUB substreams for six logical subtitle tracks.
    static func streamSummary(for title: DiscTitle) -> String {
        let audio = title.streams.filter { $0.kind == .audio }
        let subtitleGroups = SubtitleGrouping.groups(for: title)

        var parts: [String] = []
        if !audio.isEmpty {
            let languages = orderedUniqueLanguages(audio)
            let suffix = languages.isEmpty ? "" : " (\(languages.joined(separator: ", ")))"
            parts.append("\(audio.count) audio\(suffix)")
        }
        if !subtitleGroups.isEmpty {
            parts.append("\(subtitleGroups.count) sub\(subtitleGroups.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "no audio or subtitle streams" : parts.joined(separator: " · ")
    }

    /// First-appearance-order, de-duplicated, tagged-only language codes.
    private static func orderedUniqueLanguages(_ streams: [DiscStream]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for stream in streams {
            guard let code = LanguageCode.normalize(stream.languageCode), seen.insert(code).inserted else { continue }
            result.append(code)
        }
        return result
    }

    /// The sentence for a scan failure. Moved here from
    /// `DiscTitleListView.message(for:)` by #0061 so the Choose-movie step's
    /// one-line status strip (`ScanStatusLine`) and the Confirm step's disc
    /// panel say exactly the same thing, and so it gains tests.
    static func scanFailureMessage(_ failure: DiscScanner.Failure) -> String {
        switch failure {
        case .toolMissing(let path):
            return "HandBrakeCLI was not found at \(path). Check the path in Settings."
        case .launchFailure(let message):
            return "Could not launch HandBrakeCLI: \(message)"
        case .toolExited(let code):
            return "The disc scan failed (HandBrakeCLI exited with status \(code))."
        case .jsonMissing:
            return "The disc scan did not complete — no title information came back."
        case .titleSetCorrupted:
            return "The disc scan's title data was corrupted and could not be read."
        case .cancelled:
            // #0051: reached from `JobController.cancelScan()` and from
            // `ejectDisc()` cancelling a scan before ejecting. Rescan is
            // offered the same as any other failure.
            return "The scan was cancelled."
        }
    }

    /// #0032's one-line status for the runtime cross-check, moved here from
    /// `MetadataEntryView` by #0061 (the view it lived on is gone) so it is
    /// unit-tested rather than merely compiled.
    ///
    /// Must never read like a pass when the check did not run —
    /// `.unavailable` always says "will not run", never silently mirrors
    /// `.loaded`'s text.
    static func runtimeCaption(_ lookup: RuntimeLookup) -> String? {
        switch lookup {
        case .idle:
            return nil
        case .loading:
            return "Checking TMDB runtime…"
        case .loaded(_, let minutes):
            return "TMDB runtime \(runtime(minutes))"
        case .unavailable(_, let reason):
            return "Runtime cross-check will not run — \(runtimeNotRunText(reason))"
        }
    }

    /// TMDB reports a runtime in whole minutes: 98 → "1h 38m", 45 → "45m".
    static func runtime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remaining = minutes % 60
        return hours > 0 ? "\(hours)h \(remaining)m" : "\(remaining)m"
    }

    static func runtimeNotRunText(_ reason: RuntimeCrossCheck.NotRunReason) -> String {
        switch reason {
        case .missingAPIKey:         return "TMDB API key is not configured."
        case .pending:               return "waiting on TMDB."
        case .lookupFailed(let msg): return msg
        case .noRuntimeOnTMDB:       return "TMDB has no runtime for this title."
        case .noFeatureTitle:        return "no disc feature title yet."
        }
    }

    /// #0039 — the message for `DiscTitleHeuristic.Outcome.noTitles`: a scan
    /// that exited 0 and produced valid JSON but read zero titles. Distinct
    /// wording from `.none`'s "no title looks like a feature" on purpose —
    /// this disc was never actually read. `lastLine` is HandBrake's own
    /// last line of output (either stream), when there was one. The
    /// permissions hint appears only when `warnings` names the libdvdcss
    /// raw-device fallback, worded as a possibility, not a diagnosis — the
    /// fallback usually works fine on its own.
    static func noTitlesMessage(warnings: [String], lastLine: String?) -> String {
        var message = "The scan read no titles from this disc."
        if let lastLine, !lastLine.trimmingCharacters(in: .whitespaces).isEmpty {
            message += " HandBrake's last line: \"\(lastLine)\""
        }
        if warnings.contains(where: { $0.contains("libdvdcss") }) {
            message += " This scan fell back to reading the disc through libdvdcss's raw-device workaround — if that keeps failing to find titles, Changeover may not have permission to read the drive (System Settings → Privacy & Security → Files and Folders, or Full Disk Access)."
        }
        return message
    }

    /// #0056 — the confirmation row's addendum for `DiscTitleHeuristic
    /// .FeatureSource`: `nil` when HandBrake's own `MainFeature` supplied
    /// the answer (the ordinary case needs no extra line), or a caption
    /// naming the length fallback when it didn't.
    static func featureSourceCaption(_ source: DiscTitleHeuristic.FeatureSource) -> String? {
        switch source {
        case .scanner:
            return nil
        case .length:
            return "HandBrake did not name a main feature — chosen because it is the only title at or above 45 minutes."
        }
    }

    /// #0140 — the collapsed disclosure's one-line summary for the
    /// (purely informational, #0036) subtitle list, e.g. "21 subtitle
    /// tracks, none carried into the output". `count` is the number of
    /// `SubtitleGrouping.groups(for:)` groups, matching `streamSummary`'s
    /// "N sub(s)" count so the two never disagree about how many subtitle
    /// tracks the disc has. The trailing clause is constant regardless of
    /// `count` — it states a fact about the *output* (#0036's decision:
    /// Phase 2 carries no subtitles at all), not a per-track count, so it
    /// reads correctly whether one track or many were found.
    static func subtitleSummary(count: Int) -> String {
        "\(count) subtitle track\(count == 1 ? "" : "s"), none carried into the output"
    }

    /// The Play All refusal's one sentence, e.g. "This looks like a TV
    /// season disc — 8 titles of about 21 minutes that together match the
    /// length of title 12." `episodes` are the indices
    /// `DiscTitleHeuristic.playAllEpisodes` clustered; `index` is the
    /// suspicious long title. Names what was found, not what was rejected.
    static func playAllMessage(index: Int, episodes: [Int], disc: DiscInfo) -> String {
        let episodeTitles = disc.titles.filter { episodes.contains($0.index) }
        let averageSeconds = episodeTitles.isEmpty
            ? 0
            : episodeTitles.reduce(0) { $0 + $1.durationSeconds } / episodeTitles.count
        // Round to the nearest minute for the sentence; the exact seconds
        // are visible per-row in the table below it.
        let averageMinutes = (averageSeconds + 30) / 60
        return "This looks like a TV season disc — \(episodes.count) titles of about "
            + "\(averageMinutes) minutes that together match the length of title \(index)."
    }

    // MARK: - The plain register (docs/plain-language-ui.md §3.3)
    //
    // Every function above keeps its name, its wording and its tests. What
    // follows is the plain sibling of each: one short sentence a person with
    // no vocabulary for DVDs can act on, with the precise one kept verbatim
    // as the detail. Nothing above was reworded.

    /// Whole minutes, rounded: 5872 → "1h 38m", 2890 → "48m". The plain
    /// sibling of `duration(_:)`, which keeps `H:MM:SS` for the table's
    /// detail column and the extras total.
    static func plainDuration(_ totalSeconds: Int) -> String {
        runtime((max(0, totalSeconds) + 30) / 60)
    }

    /// "The movie · 1h 38m" — the plain sibling of `confirmationDetail`.
    /// No index, no chapter count, no byte size: none of them is something
    /// the person has to act on, and all three are one disclosure away.
    static func plainFeatureLine(title: DiscTitle) -> String {
        "The movie · \(plainDuration(title.durationSeconds))"
    }

    /// The heading and table badge in the plain register. "Main feature" is
    /// HandBrake's word; this is the user's.
    static let plainFeatureLabel = "The movie"

    static func plainScanFailureMessage(_ failure: DiscScanner.Failure) -> String {
        switch failure {
        case .toolMissing:
            return "A program Changeover needs isn't installed. Open Settings to fix it."
        case .launchFailure:
            return "The disc reader couldn't start. Open Settings to check it."
        case .toolExited:
            return "The disc couldn't be read. Try Scan Again, or clean the disc."
        case .jsonMissing:
            return "The disc couldn't be read. Try Scan Again."
        case .titleSetCorrupted:
            return "The disc couldn't be read. Try Scan Again, or clean the disc."
        case .cancelled:
            // Already plain, and already the whole truth.
            return "The scan was cancelled."
        }
    }

    /// The plain sibling of `noTitlesMessage(warnings:lastLine:)`. Constant:
    /// neither HandBrake's last line nor the Full Disk Access hint gives a
    /// person anything to *do* that "try again, or clean the disc" doesn't,
    /// and the hint is worded as a possibility, not a diagnosis (see its own
    /// doc comment). Both stay verbatim in the detail.
    static let plainNoTitlesMessage = "Nothing playable was found on this disc. Try Scan Again, or clean the disc."

    /// The scan failure in both registers.
    static func scanFailureWording(_ failure: DiscScanner.Failure) -> Wording {
        Wording(plain: plainScanFailureMessage(failure), detail: scanFailureMessage(failure))
    }

    static func noTitlesWording(warnings: [String], lastLine: String?) -> Wording {
        Wording(
            plain: plainNoTitlesMessage,
            detail: noTitlesMessage(warnings: warnings, lastLine: lastLine)
        )
    }

    /// #0056's length fallback, in plain words. Stays orange in both
    /// registers: it is the one guess on the screen, and the plain sentence
    /// has to keep saying so.
    static func plainFeatureSourceCaption(_ source: DiscTitleHeuristic.FeatureSource) -> String? {
        switch source {
        case .scanner:
            return nil
        case .length:
            return "Changeover guessed this is the movie because it's the only long part of the disc. Check the length looks right."
        }
    }

    static func featureSourceWording(_ source: DiscTitleHeuristic.FeatureSource) -> Wording? {
        guard let plain = plainFeatureSourceCaption(source),
              let detail = featureSourceCaption(source) else { return nil }
        return Wording(plain: plain, detail: detail)
    }

    /// "Extras: none" / "Extras: 2 · 48m" — the plain sibling of
    /// `extrasStatusLine`, which keeps `H:MM:SS`.
    static func plainExtrasLine(_ plan: ExtrasPlan) -> String {
        guard !plan.items.isEmpty else { return "Extras: none" }
        return "Extras: \(plan.items.count) · \(plainDuration(plan.totalDurationSeconds))"
    }

    /// The Play All refusal, plain. The cluster arithmetic that produced it
    /// is exactly what the detail register is for; what the person needs is
    /// "this isn't a film — pick the part you want".
    static let plainPlayAllMessage = "This looks like a TV disc, not a movie. Pick the part you want below."

    static func playAllWording(index: Int, episodes: [Int], disc: DiscInfo) -> Wording {
        Wording(
            plain: plainPlayAllMessage,
            detail: playAllMessage(index: index, episodes: episodes, disc: disc)
        )
    }

    /// `DiscTitleHeuristic.Outcome.none` — the disc that did not identify
    /// itself. The detail is the sentence `DiscTitleListView` used to hold as
    /// a literal; moving it here is what gives it a test.
    static let noFeatureWording = Wording(
        plain: "Changeover couldn't tell which part of the disc is the movie. Pick it below — it's usually the longest one.",
        detail: "This disc did not identify itself — no title looks like a feature. That can happen on a TV disc with no Play All title, or a feature under 45 minutes. Choose one below."
    )

    /// The `.playAll`/`.none` extras running total, likewise moved out of
    /// `DiscTitleListView` so it is pinned rather than merely compiled.
    static func extrasSummaryWording(_ plan: ExtrasPlan) -> Wording {
        let count = plan.items.count
        return Wording(
            plain: plainExtrasLine(plan),
            detail: "\(count) extra\(count == 1 ? "" : "s") selected — \(duration(plan.totalDurationSeconds)) total, filed outside the Plex library"
        )
    }

    /// "English, Spanish" / "No sound" — the plain sibling of
    /// `streamSummary(for:)`. Language *names*, never codes; the subtitle
    /// count is a detail, because the output carries no subtitles at all
    /// (#0036) and the count therefore changes nothing the person can do.
    ///
    /// A fully untagged title has no names to give, so it says how many
    /// tracks there are instead — which is the one thing that is still true.
    static func plainLanguages(for title: DiscTitle) -> String {
        let audio = title.streams.filter { $0.kind == .audio }
        guard !audio.isEmpty else { return "No sound" }
        let names = orderedUniqueLanguages(audio).compactMap { PlainLanguage.languageName($0) }
        guard !names.isEmpty else {
            return "\(audio.count) audio track\(audio.count == 1 ? "" : "s")"
        }
        return names.joined(separator: ", ")
    }

    /// #0036's fact about the *output*, said once, in plain words. Constant
    /// on purpose: the track count is what the detail register carries.
    static let plainSubtitleLine = "Subtitles aren't copied to Plex yet."

    static func subtitleWording(count: Int) -> Wording {
        Wording(plain: plainSubtitleLine, detail: subtitleSummary(count: count))
    }

    /// The plain sibling of `runtimeCaption`. "Listed length", not "TMDB
    /// runtime": the person did not choose a database, they chose a movie.
    static func plainRuntimeCaption(_ lookup: RuntimeLookup) -> String? {
        switch lookup {
        case .idle:
            return nil
        case .loading:
            return "Checking the movie's length…"
        case .loaded(_, let minutes):
            return "Listed length \(runtime(minutes))"
        case .unavailable:
            // Why it will not run — a missing key, a lookup error — is the
            // detail. That it did not happen is the plain fact.
            return "Couldn't check the movie's length."
        }
    }

    static func runtimeWording(_ lookup: RuntimeLookup) -> Wording? {
        guard let plain = plainRuntimeCaption(lookup), let detail = runtimeCaption(lookup) else { return nil }
        return Wording(plain: plain, detail: detail)
    }

    /// #0032's verdict in both registers, moved out of `DiscTitleListView` so
    /// the Δ arithmetic behind the plain sentence is tested.
    ///
    /// `nil` for `.notRun`: the movie card's own runtime caption already says
    /// the check did not happen, and repeating it here was the redundant
    /// second line the first pass flagged.
    static func runtimeVerdictWording(title: DiscTitle, verdict: RuntimeCrossCheck.Verdict) -> Wording? {
        switch verdict {
        case .consistent(let delta):
            return Wording(
                plain: "✓ Length matches.",
                detail: "Title \(title.index) matches the TMDB runtime (Δ \(signed(delta))s)"
            )
        case .mismatch(let delta):
            let direction = delta < 0 ? "shorter" : "longer"
            return Wording(
                plain: "This part is \(PlainLanguage.minutes(delta)) \(direction) than the movie should be. It may not be the movie — check before ripping.",
                detail: "Title \(title.index) does not match the TMDB runtime (Δ \(signed(delta))s) — check this is the right title."
            )
        case .notRun:
            return nil
        }
    }

    /// The caption after "Rip anyway".
    static let acknowledgedWording = Wording(
        plain: "OK — you've chosen to rip it anyway.",
        detail: "Confirmed — Start is enabled despite the mismatch."
    )

    /// `RuntimeCrossCheck`'s delta, signed — the shape `DiscTitleListView`
    /// rendered inline before the verdict moved here.
    static func signed(_ seconds: Int) -> String {
        seconds >= 0 ? "+\(seconds)" : "\(seconds)"
    }
}
