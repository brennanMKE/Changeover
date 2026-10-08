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

    /// Whether two runtimes are the same film, within `toleranceSeconds`.
    ///
    /// #0216 — lifted out so the feature match and the extras match ask the
    /// identical question. Two answers to "do these runtimes agree" is how one
    /// report starts contradicting another.
    static func isSameRuntime(_ a: Int, _ b: Int) -> Bool {
        abs(a - b) <= toleranceSeconds
    }

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
        let ordered = titles.sorted { $0.index < $1.index }

        // #0231 — pair titles with files in order of how well they AGREE, not
        // in title order.
        //
        // The previous version walked the titles by index and gave each one
        // its nearest unclaimed file. That is greedy in the wrong dimension: a
        // title considered early takes a file that a later title matches
        // exactly, and the later title is then reported missing. On Pacific
        // Rim: Uprising, title 11 (0:32) claimed the 0:38 file — six seconds
        // out, but inside the tolerance and nothing closer was left — and
        // title 30, whose runtime was 0:38 exactly, was reported as not in the
        // library at all. Three extras were wrong that way, and the output
        // reads as an instruction to re-import files that are already filed.
        //
        // So build every acceptable pairing, sort by the size of the
        // disagreement, and take them best-first. A perfect match is always
        // claimed before a merely tolerable one, whatever order the titles are
        // in. Ties break on title index, then on file name, so the result does
        // not depend on the order the filesystem listed things in.
        struct Pairing {
            var titleIndex: Int
            var fileOffset: Int
            var distance: Int
            var fileName: String
        }
        var pairings: [Pairing] = []
        for title in ordered {
            for (offset, extra) in timed.enumerated() {
                let distance = abs((extra.file.durationSeconds ?? 0) - title.durationSeconds)
                guard distance <= toleranceSeconds else { continue }
                pairings.append(Pairing(titleIndex: title.index, fileOffset: offset,
                                        distance: distance, fileName: extra.file.name))
            }
        }
        pairings.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.titleIndex != $1.titleIndex { return $0.titleIndex < $1.titleIndex }
            return $0.fileName < $1.fileName
        }

        // One file answers for one title: two extras of the same length on one
        // disc are two different videos, and the second must not be declared
        // held on the strength of the first.
        var claimedTitles: Set<Int> = []
        var claimedFiles: Set<Int> = []
        var holder: [Int: LibraryExtraFile] = [:]
        for pairing in pairings {
            guard !claimedTitles.contains(pairing.titleIndex),
                  !claimedFiles.contains(pairing.fileOffset) else { continue }
            claimedTitles.insert(pairing.titleIndex)
            claimedFiles.insert(pairing.fileOffset)
            holder[pairing.titleIndex] = timed[pairing.fileOffset]
        }

        return ordered.map { Verdict(titleIndex: $0.index, existing: holder[$0.index]) }
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
