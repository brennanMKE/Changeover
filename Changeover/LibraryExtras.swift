import Foundation

/// #0187 — which of this disc's extras the library already holds.
///
/// #0185 kept a disc in the drive whenever anything was ticked, and said in
/// as many words that "do I already have this featurette" was not a question
/// the app could answer: Plex has no per-extra record to query the way
/// `LibraryProbe` queries a film's `{tmdb-ID}` folder.
///
/// That was wrong, and the user said so. Plex keeps extras in named
/// subfolders of the movie's own folder, so the answer is sitting on the
/// filesystem next to the film — a listing away, in the folder the app already
/// lists. It needed looking at, not a new database.
///
/// Matched on **duration**, the same fact every other identification in this
/// app rests on, because a filename cannot be trusted: the library copy was
/// named by whatever tool filed it, possibly years ago and possibly by hand,
/// while the disc's label comes from a menu read through OCR. Two runtimes
/// agreeing is evidence; two names agreeing is a coincidence waiting to
/// happen, and two names disagreeing proves nothing at all.
nonisolated enum LibraryExtras {

    /// How close a library file's runtime must be to a disc title's to be the
    /// same video.
    ///
    /// Twelve seconds, matching `MenuExtraLabels.toleranceSeconds`. An encode
    /// of a title is the same length as the title to within rounding; the
    /// slack is for a container reporting whole seconds and for a transfer
    /// that trimmed a frame of black. Extras on a real disc are minutes apart
    /// — Signs' run 4:51 to 22:37 — so the gap between right and wrong here is
    /// enormous and the tolerance is nowhere near it.
    static let toleranceSeconds = 12

    /// A disc title judged against what the library already holds.
    nonisolated struct Verdict: Equatable, Sendable {
        var titleIndex: Int
        /// The file already filed for it, when there is one.
        var existing: LibraryExtraFile?
        var isHeld: Bool { existing != nil }
    }

    /// Judges every ticked title against the library folder's extras.
    ///
    /// A library file with no duration is **not** evidence of absence and not
    /// evidence of presence: it is skipped, so a probe that could not read a
    /// runtime leaves the title looking importable. That is the safe
    /// direction — offering an extra the user already has costs them a
    /// re-encode they can cancel, while hiding one they do not have loses it
    /// silently, and the whole point of this work is that silently losing
    /// bonus material is what people's libraries have been doing for years.
    static func verdicts(forTitles titles: [DiscTitle],
                         against extras: [LibraryExtraFile]) -> [Verdict] {
        let timed = extras.filter { ($0.file.durationSeconds ?? 0) > 0 }
        var available = timed
        var result: [Verdict] = []
        for title in titles.sorted(by: { $0.index < $1.index }) {
            let hit = available
                .enumerated()
                .filter { abs(($0.element.file.durationSeconds ?? 0) - title.durationSeconds) <= toleranceSeconds }
                .min { abs(($0.element.file.durationSeconds ?? 0) - title.durationSeconds)
                     < abs(($1.element.file.durationSeconds ?? 0) - title.durationSeconds) }
            if let hit {
                // One file answers for one title: two extras of the same
                // length on one disc are two different videos, and the second
                // must not be declared held on the strength of the first.
                available.remove(at: hit.offset)
                result.append(Verdict(titleIndex: title.index, existing: hit.element))
            } else {
                result.append(Verdict(titleIndex: title.index, existing: nil))
            }
        }
        return result
    }

    /// The titles still worth importing — what the eject decision and the
    /// Choose step's line should both be built on.
    static func stillMissing(_ verdicts: [Verdict]) -> [Int] {
        verdicts.filter { !$0.isHeld }.map(\.titleIndex)
    }

    /// The sentence for an extra the library already holds, in the detail
    /// register: names the file so the claim is checkable rather than taken on
    /// trust — the standard #0153 set after a correct eject was indistinguishable
    /// from a malfunction because nothing said what it had found.
    static func heldDetail(_ verdict: Verdict) -> String? {
        guard let existing = verdict.existing else { return nil }
        return "title \(verdict.titleIndex) is already in \(existing.folderName)/\(existing.file.name)"
    }
}
