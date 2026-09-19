import Foundation

/// What one file already in the Plex library is **missing** — decided from the
/// file alone, with no disc anywhere near it.
///
/// This is deliberately the smaller half of §7's comparison. A library sweep
/// ("which of my 200 films could be improved?") can answer itself entirely
/// from `LibraryFileInventory` values read off the library volume: it needs no
/// disc in the drive, no menu read, and no TMDB call. Only the *other* half —
/// what a particular disc can supply (`DiscUpgradeOffer`) — needs the disc,
/// and that is resolved at insertion.
///
/// Keeping the two apart is what makes the sweep cheap to add later: the list
/// view calls `find(_:)` per file; the Confirm step calls
/// `UpgradeProposal.compare` with a disc's offer as well.
nonisolated struct LibraryFileGaps: Equatable, Sendable, Codable {

    /// How many chapter markers the file has. `0` means a rip that wrote none
    /// at all — a remux cannot invent timings, so that is a re-rip.
    var chapterCount: Int
    /// Every chapter title is a placeholder (`Chapter 1`…) or empty.
    var chaptersAreUnnamed: Bool
    /// How many chapters do carry a real name. Non-zero with
    /// `chaptersAreUnnamed == false` is the "already named" case, which is
    /// only ever overwritten on an explicit tick.
    var namedChapterCount: Int

    /// Audio tracks (0-based, as `-metadata:s:a:<n>` addresses them) with no
    /// ISO language tag at all — the `und` case from Hornet's Nest.
    var untaggedAudioTracks: [Int]
    /// Audio tracks with no human-readable title. Plex shows the language
    /// when there is one, so an untitled *tagged* track is a much smaller
    /// gap than an untagged one — both are listed, neither is conflated.
    var untitledAudioTracks: [Int]
    var audioTrackCount: Int

    /// The file carries no subtitle stream. Recorded because it is the most
    /// common "needs a re-rip" row on the card, never because a remux could
    /// do anything about it.
    var hasNoSubtitles: Bool

    /// Nothing here a remux could ever improve.
    var isEmpty: Bool {
        !wantsChapterNames && untaggedAudioTracks.isEmpty && untitledAudioTracks.isEmpty
    }

    /// The file has chapter markers whose names are all placeholders — the
    /// one gap a disc's scene menu fills exactly.
    var wantsChapterNames: Bool { chapterCount > 0 && chaptersAreUnnamed }

    /// One sentence for a list row: "20 chapters, all unnamed · 1 audio track
    /// with no language". Empty string when there is nothing to say, so a
    /// sweep can filter on `isEmpty` rather than on prose.
    var summaryLine: String {
        var parts: [String] = []
        if wantsChapterNames {
            parts.append("\(chapterCount) chapters, all unnamed")
        } else if chapterCount == 0 {
            parts.append("no chapter markers")
        }
        if !untaggedAudioTracks.isEmpty {
            parts.append("\(untaggedAudioTracks.count) audio track\(untaggedAudioTracks.count == 1 ? "" : "s") with no language")
        } else if !untitledAudioTracks.isEmpty {
            parts.append("\(untitledAudioTracks.count) audio track\(untitledAudioTracks.count == 1 ? "" : "s") with no name")
        }
        if hasNoSubtitles { parts.append("no subtitles") }
        return parts.joined(separator: " · ")
    }

    /// The whole file-side half of §7, from one inventory. Pure, cheap, and
    /// callable 200 times in a row.
    static func find(_ inventory: LibraryFileInventory) -> LibraryFileGaps {
        LibraryFileGaps(
            chapterCount: inventory.chapters.count,
            chaptersAreUnnamed: inventory.chaptersAreUnnamed,
            namedChapterCount: inventory.namedChapterCount,
            untaggedAudioTracks: inventory.audio.filter { $0.language == nil }.map(\.track),
            untitledAudioTracks: inventory.audio.filter { $0.title == nil }.map(\.track),
            audioTrackCount: inventory.audio.count,
            hasNoSubtitles: inventory.subtitleCount == 0
        )
    }
}
