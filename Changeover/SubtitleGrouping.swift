import Foundation

/// #0033 — collapses HandBrake's per-aspect-ratio subtitle variant pairs
/// (Wide Screen / Letterbox / …) into logical tracks. HandBrake reports a
/// separate `DiscStream` per variant even though the pair is the same
/// logical subtitle track re-positioned for a different disc framing:
/// presenting them all as separate rows would show Fargo's six logical
/// subtitle tracks as twelve near-identical rows
/// (`MakeMKVReplacement-Results.md` §6, cited in this issue's Description).
///
/// Pure, `nonisolated`: a plain function from a `DiscTitle`'s subtitle
/// streams to groups — no disc, no process, no UI import — the same seam as
/// `HandBrakeScanParser` and `DiscTitleFormatting`.
///
/// **Collapse only across different variants, never within one variant.**
/// The real `dragon-tattoo-title0-min1.json` fixture's title 1 carries three
/// distinct `Wide Screen` English subtitle tracks (indices 1, 2, 5) that the
/// metadata cannot otherwise tell apart — grouping by (language, role) alone
/// would silently merge three real tracks into one row and hide two of
/// them. Only a bucket that actually contains more than one *variant*, in
/// equal counts, collapses; everything else falls back to showing what is
/// there, one row per stream.
nonisolated struct SubtitleGroup: Equatable, Sendable, Identifiable {
    /// Normalized by the parser; `nil` means untagged (#0033's `"und"` fix
    /// covers the one fixture case — `LanguageCode.normalize` from #0027
    /// isn't a dependency here).
    var languageCode: String?
    /// Parenthetical-free, from the parser.
    var languageName: String?
    var isForced: Bool
    var isCommentary: Bool
    /// `DiscStream.isTextSubtitle` — matches HandBrake's unprefixed `CC608`
    /// `SourceName` as well as MakeMKV's `S_CC608/DVD` (#0033).
    var isText: Bool
    /// At most one member per variant, in `TrackNumber` order. Never empty.
    var members: [DiscStream]
    /// The member an encode would take: the `Wide Screen` one when present,
    /// else the lowest `TrackNumber`. Nothing in Phase 2 actually encodes a
    /// subtitle selection yet (#0029's refresh) — these groups are read-only
    /// rows in #0027's picker for now.
    var selectedTrackNumber: Int
    var id: Int { members[0].index }
}

nonisolated enum SubtitleGrouping {
    /// HandBrake's label for the variant this app prefers: its encode is
    /// always anamorphic widescreen (`CLAUDE.md`, `Config.swift`). An
    /// unrecognized label is kept as-is and never treated as a parse
    /// failure — see `unknownVariantLabelPairsByPositionWithWideScreen`.
    static let preferredVariant = "Wide Screen"

    static func groups(for title: DiscTitle) -> [SubtitleGroup] {
        let subtitles = title.streams
            .filter { $0.kind == .subtitle }
            .sorted { $0.index < $1.index }

        // Step 2: bucket by (languageCode, languageName, isForced,
        // isCommentary, codecId), keeping buckets in first-appearance order.
        var bucketOrder: [BucketKey] = []
        var buckets: [BucketKey: [DiscStream]] = [:]
        for stream in subtitles {
            let key = BucketKey(stream: stream)
            if buckets[key] == nil {
                bucketOrder.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(stream)
        }

        return bucketOrder.flatMap { split(buckets[$0] ?? []) }
    }

    /// Step 3: split one bucket by `variant` (`nil` is its own variant) and
    /// pair equal-sized variant groups by position; anything else — one
    /// variant only, or unequal counts — falls back to one group per
    /// stream, so an unexpected shape never silently drops a track.
    private static func split(_ members: [DiscStream]) -> [SubtitleGroup] {
        // `String?` is `Hashable` (Optional conforms when its wrapped type
        // does), so `nil` — "no parenthetical reported" — is a perfectly
        // usable dictionary key here and needs no wrapper.
        var variantOrder: [String?] = []
        var byVariant: [String?: [DiscStream]] = [:]
        for stream in members {
            if byVariant[stream.variant] == nil {
                variantOrder.append(stream.variant)
                byVariant[stream.variant] = []
            }
            byVariant[stream.variant]?.append(stream)
        }

        let counts = Set(variantOrder.map { byVariant[$0]?.count ?? 0 })
        guard variantOrder.count >= 2, counts.count == 1, let n = counts.first, n > 0 else {
            return members.map { makeGroup(members: [$0]) }
        }

        return (0..<n).map { position in
            let paired = variantOrder.map { byVariant[$0]![position] }
            return makeGroup(members: paired)
        }
    }

    private static func makeGroup(members: [DiscStream]) -> SubtitleGroup {
        let ordered = members.sorted { $0.index < $1.index }
        let first = ordered[0]
        let selectedTrackNumber = ordered.first { $0.variant == preferredVariant }?.index
            ?? ordered.map(\.index).min()!
        return SubtitleGroup(
            languageCode: LanguageCode.normalize(first.languageCode),
            languageName: first.languageName,
            isForced: first.isForced,
            isCommentary: first.isCommentary,
            isText: first.isTextSubtitle,
            members: ordered,
            selectedTrackNumber: selectedTrackNumber
        )
    }

    private struct BucketKey: Hashable {
        var languageCode: String?
        var languageName: String?
        var isForced: Bool
        var isCommentary: Bool
        var codecId: String

        init(stream: DiscStream) {
            // #0027 review: normalized like audio, so `fre`/`fra` and
            // `und`/nil bucket together whatever produced the stream.
            languageCode = LanguageCode.normalize(stream.languageCode)
            languageName = stream.languageName
            isForced = stream.isForced
            isCommentary = stream.isCommentary
            codecId = stream.codecId
        }
    }
}
