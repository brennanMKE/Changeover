import Foundation

/// #0031 Step B — the pure seam between what the user opted into
/// (`RipRequest.extraTitleIndices`) and what the pipeline actually encodes.
/// Built once, against the scan `JobController` currently holds, the same
/// way `EncodeSelection.make(request:disc:)` resolves the feature — never
/// trust a request's indices without checking them against a live scan
/// first, per #0028's "never mix indices across scans" rule.
///
/// `nonisolated` and `Sendable` for the same reason as `EncodeSelection`:
/// built on MainActor (`JobController.start`) and consumed by the
/// `nonisolated` `DVDPipeline`/`EncodeController`.
nonisolated struct ExtrasPlan: Equatable, Sendable {
    /// Everything `DVDPipeline`'s extras loop needs for one extra, resolved
    /// once against the scan: `durationSeconds`/`frameRate`/
    /// `interlaceDetected` come straight off the matching `DiscTitle`, the
    /// same fields `EncodeSelection.make` reads for the feature's own
    /// `DeinterlaceDecision`.
    struct Item: Equatable, Sendable {
        let titleIndex: Int
        let durationSeconds: Int
        let frameRate: Double?
        let interlaceDetected: Bool?
    }

    var items: [Item] = []

    /// #0026's running total — a duration, not a size: a HandBrake scan
    /// reports no size (`sizeBytes: 0`), unlike the MakeMKV table this
    /// ticket's Description was originally written against.
    var totalDurationSeconds: Int {
        items.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Resolves `requested` (`RipRequest.extraTitleIndices`) against `disc`:
    /// - Duplicate indices are removed, keeping first occurrence.
    /// - `featureIndex` is dropped — an extra can never be the feature.
    /// - Indices that aren't a title of `disc` are dropped (a stale
    ///   selection from a superseded scan, the same defense-in-depth
    ///   `EncodeSelection.make` applies to the feature).
    /// - Kept indices are sorted ascending, so encode order is deterministic
    ///   and matches the table the user picked from.
    ///
    /// An empty `requested` gives an empty plan — zero extras is the
    /// default and a valid job.
    nonisolated static func make(featureIndex: Int, requested: [Int], disc: DiscInfo) -> ExtrasPlan {
        let titlesByIndex = Dictionary(uniqueKeysWithValues: disc.titles.map { ($0.index, $0) })

        var seen = Set<Int>()
        let indices = requested
            .filter { $0 != featureIndex && seen.insert($0).inserted }
            .filter { titlesByIndex[$0] != nil }
            .sorted()

        let items = indices.map { index -> Item in
            let title = titlesByIndex[index]! // guaranteed present by the filter above
            return Item(
                titleIndex:        title.index,
                durationSeconds:   title.durationSeconds,
                frameRate:         title.frameRate,
                interlaceDetected: title.interlaceDetected
            )
        }
        return ExtrasPlan(items: items)
    }
}
