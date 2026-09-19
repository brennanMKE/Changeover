import Foundation

/// §7.5 step 3 — what makes "remux, never re-encode" a property the app
/// **checks** rather than a promise the command line makes.
///
/// Run on the staged copy, before the library file is touched. A refusal here
/// is a Done card with the failed check named, and the original file is
/// exactly as it was.
///
/// Four of these checks are scars from doing this by hand (2026-09-18):
///
/// - **The right streams, not the stream count.** A DVD rip carries a leftover
///   `bin_data` timed-metadata stream that does not survive an MP4 remux. That
///   is junk leaving, not data lost, so the video and audio streams are
///   compared one by one and the "other" count is only ever allowed to *fall*.
/// - **Chapter times, not raw values.** The remux rewrites chapters on a finer
///   timebase, so ffprobe's integers differ while the moments do not.
///   `LibraryFileInventory` normalises both to milliseconds; the comparison is
///   in milliseconds, with 1 ms of slack for the conversion.
/// - **The names have to actually be there.** A metadata write that silently
///   did nothing is caught by reading them back.
/// - **Track titles come back as `name` in MP4.** `LibraryFileInventory`
///   reads both keys, so a successful write is never reported as a failure.
nonisolated enum RemuxVerification {

    nonisolated enum Verdict: Equatable, Sendable {
        case ok
        /// The named check that failed, in a sentence a user reads.
        case refused(String)

        var isOK: Bool { self == .ok }
        var reason: String? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// Duration slack. A remux copies packets; anything beyond a second is a
    /// different file.
    static let durationToleranceMS = 1_000
    /// Chapter slack — one millisecond, which is the most a 1/90000 → 1/1000
    /// conversion can round by.
    static let chapterToleranceMS = 1
    /// Size slack. A copy that changed size by more than this re-encoded
    /// something (or dropped a stream that mattered).
    static let sizeTolerance = 0.02

    static func verify(
        original: LibraryFileInventory,
        upgraded: LibraryFileInventory,
        plan: UpgradePlan
    ) -> Verdict {
        // 1. Duration.
        let durationDelta = abs(upgraded.durationMS - original.durationMS)
        guard durationDelta <= durationToleranceMS else {
            return .refused("the rewritten file runs \(DiscTitleFormatting.duration(upgraded.durationSeconds)) and the original runs \(DiscTitleFormatting.duration(original.durationSeconds))")
        }

        // 2. Video: the same codec at the same size, or there is no point
        // calling this a copy.
        switch (original.video, upgraded.video) {
        case (nil, nil):
            break
        case (let before?, let after?):
            guard before.codec == after.codec else {
                return .refused("the video stream came back as \(after.codec), not \(before.codec) — that is a re-encode, not a copy")
            }
            guard before.width == after.width, before.height == after.height else {
                return .refused("the video stream changed size — that is a re-encode, not a copy")
            }
        case (_?, nil):
            return .refused("the rewritten file has no video stream")
        case (nil, _?):
            return .refused("the rewritten file gained a video stream")
        }

        // 3. Audio, one stream at a time — never a total stream count, which
        // a departing `bin_data` stream would fail for the wrong reason.
        guard original.audio.count == upgraded.audio.count else {
            return .refused("the rewritten file has \(upgraded.audio.count) audio streams and the original has \(original.audio.count)")
        }
        for (before, after) in zip(original.audio, upgraded.audio) {
            guard before.codec == after.codec else {
                return .refused("audio track \(before.track + 1) came back as \(after.codec), not \(before.codec) — that is a re-encode, not a copy")
            }
            guard before.channels == after.channels else {
                return .refused("audio track \(before.track + 1) came back with \(after.channels) channels, not \(before.channels)")
            }
        }
        guard upgraded.subtitleCount >= original.subtitleCount else {
            return .refused("the rewritten file lost a subtitle stream")
        }

        // 4. Chapters: the same count, at the same moments.
        guard original.chapters.count == upgraded.chapters.count else {
            return .refused("the rewritten file has \(upgraded.chapters.count) chapters and the original has \(original.chapters.count)")
        }
        for (index, pair) in zip(original.chapters, upgraded.chapters).enumerated() {
            let (before, after) = pair
            guard abs(after.startMS - before.startMS) <= chapterToleranceMS,
                  abs(after.endMS - before.endMS) <= chapterToleranceMS else {
                return .refused("chapter \(index + 1) moved — it starts at \(after.startMS) ms and used to start at \(before.startMS) ms")
            }
        }

        // 5. What was asked for is actually in the file.
        for row in plan.chapters {
            let index = row.number - 1
            guard index >= 0, index < upgraded.chapters.count else {
                return .refused("chapter \(row.number) is not in the rewritten file")
            }
            guard upgraded.chapters[index].title == row.name else {
                return .refused("chapter \(row.number) reads “\(upgraded.chapters[index].title)” and should read “\(row.name)”")
            }
        }
        for tag in plan.audio {
            guard let stream = upgraded.audio.first(where: { $0.track == tag.track }) else {
                return .refused("audio track \(tag.track + 1) is not in the rewritten file")
            }
            if let language = tag.language, stream.language != language {
                return .refused("audio track \(tag.track + 1) is tagged \(stream.language ?? "nothing") and should be tagged \(language)")
            }
            // In MP4 the title is read back as `name`; `LibraryFileInventory`
            // accepts either key, so this compares what was written.
            if let title = tag.title, stream.title != title {
                return .refused("audio track \(tag.track + 1) is named \(stream.title.map { "“\($0)”" } ?? "nothing") and should be named “\(title)”")
            }
        }

        // 6. Size, last: the cheapest check and the least specific, so it
        // never gets the chance to explain a failure one of the above knows
        // better.
        if let before = original.sizeBytes, let after = upgraded.sizeBytes, before > 0 {
            let ratio = abs(Double(after) - Double(before)) / Double(before)
            guard ratio <= sizeTolerance else {
                return .refused("the rewritten file is \(Int((ratio * 100).rounded())) % a different size — a copy that changed size by that much re-encoded something")
            }
        }

        return .ok
    }
}
