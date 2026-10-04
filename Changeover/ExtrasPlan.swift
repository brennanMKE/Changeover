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

    /// #0178 — where one encoded extra is filed: the non-Plex `Clips` tree,
    /// or a Plex extras subfolder inside the film's own folder.
    ///
    /// **Why this is a case on `Item` and not a second, parallel plan type.**
    /// The obvious alternative is a `BonusPlan` with its own loop in
    /// `DVDPipeline`, and it was rejected on the strength of what that loop
    /// actually contains. Encoding a non-feature title carries #0046's two
    /// cancel boundaries (between extras, and the one inside a killed
    /// `HandBrakeCLI`), #0037's post-encode duration check, #0031's
    /// delete-the-partial-and-carry-on rule, #0035's skip when the feature
    /// came from the MakeMKV fallback, and the invariant that none of it may
    /// change the job's outcome. Every one of those applies to a bonus
    /// feature exactly as it applies to a clip — a 58-minute making-of is
    /// encoded by the same HandBrake, cancelled by the same cancel and
    /// measured by the same `AVURLAsset`. The *only* thing that differs is
    /// the single `LibraryDestination` value handed to `PlexOrganizer.move`.
    ///
    /// A second loop would be a second copy of all of that, free to drift
    /// from this one; and the drift would be silent, because the loop's
    /// properties are exactly the kind that only show up on a disc nobody
    /// has in the drive. One extra case states the difference once.
    nonisolated enum Filing: Equatable, Sendable {
        /// #0174/#0178 — inside the film's own folder, in one of Plex's
        /// recognised extras subfolders, under the name the disc printed:
        /// `Movies/<folder>/Behind The Scenes/looking for Signs.mp4`.
        ///
        /// **The name is what makes this safe**, in two separate ways. Plex
        /// scans a movie folder for films, so a file dropped beside the
        /// feature becomes a second, wrongly-named movie — that hazard is
        /// what sent `.extra` to `Clips` in #0031, and the only exemption
        /// from it is `PlexExtra.Kind`, the fixed set of subfolder names
        /// Plex reads as extras instead. And a file in one of those folders
        /// is shown to a person by its filename, so `Bonus Feature - t08`
        /// beside the film would be an unexplained object in the library.
        /// A title with no name gets `.clip`; see `make(…labels:)`.
        case bonusFeature(kind: PlexExtra.Kind, label: String)
    }

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
        /// #0178. `var` with a default rather than `let`, so the memberwise
        /// initialiser keeps it optional and the ~15 existing construction
        /// sites across `ExtrasPipelineTests`, `OutputDurationCheckTests`,
        /// `DVDPipelineCancellationTests`, `JobStateMachineTests`,
        /// `MakeMKVFallbackTests` and `DiscTitleFormattingTests` compile
        /// unchanged — the same additive shape `DVDPipeline.extras` itself
        /// took.
        /// #0192 — the default is "nothing named it", which now files under
        /// `Other` beside the film rather than into a folder Plex never
        /// scans. Every extra ends up with its film; the only question a
        /// label answers is which subfolder and what the file is called.
        var filing: Filing = .bonusFeature(kind: .other, label: "")

        /// The one `LibraryDestination` the pipeline hands to
        /// `PlexOrganizer.move` for this item.
        ///
        /// Derived here rather than stored, so the title index in the path
        /// is always the title index that was resolved against the scan —
        /// `LibraryDestination.bonusFeature` carries one of its own (it is
        /// `PlexExtra.fileName`'s fallback when a label sanitises away), and
        /// two copies of the same integer is how #0028's class of bug
        /// starts.
        var destination: LibraryDestination {
            switch filing {
            case .bonusFeature(let kind, let label):
                return .bonusFeature(titleIndex: titleIndex, kind: kind, label: label)
            }
        }

        /// The name the disc gave this title, for the log. `nil` for a clip
        /// — HandBrake gives an extra no name of its own, which is the whole
        /// reason `.clip`'s filename is an index.
        /// The name the disc gave this title, for the log. Empty when
        /// nothing named it — `PlexExtra.fileName` then generates
        /// `Bonus Feature - tNN`, because HandBrake gives an extra no name of
        /// its own and a file in an extras folder is shown to a person by its
        /// filename.
        var label: String? {
            switch filing {
            case .bonusFeature(_, let label): return label.isEmpty ? nil : label
            }
        }

        var isBonusFeature: Bool {
            if case .bonusFeature = filing { return true }
            return false
        }
    }

    var items: [Item] = []

    /// #0026's running total — a duration, not a size: a HandBrake scan
    /// reports no size (`sizeBytes: 0`), unlike the MakeMKV table this
    /// ticket's Description was originally written against.
    var totalDurationSeconds: Int {
        items.reduce(0) { $0 + $1.durationSeconds }
    }

    /// #0178 — how many of these land beside the film rather than in `Clips`.
    ///
    /// #0192: all of them, now that `Clips` is gone. Kept because callers
    /// still ask, and because it is the honest answer to "how many extras are
    /// in this plan" for anything that only cares about the count.
    var bonusFeatureCount: Int {
        items.filter(\.isBonusFeature).count
    }

    /// #0192 — how many carry a name of their own.
    ///
    /// The distinction that still matters to a person reading the Confirm
    /// step. A named extra becomes `Behind The Scenes/looking for Signs.mp4`;
    /// an unnamed one becomes `Other/Bonus Feature - t08.mp4`, which is
    /// honest about being title 8 of the disc and nothing more. Where they go
    /// no longer varies; what they will be called does.
    func bonusFeatureCount(withLabel: Bool) -> Int {
        items.filter { ($0.label != nil) == withLabel }.count
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
    ///
    /// #0178 — `labels` names titles the disc itself named, keyed by title
    /// index, and a named title is filed beside the film instead of in
    /// `Clips` (see `Filing.bonusFeature`). Three rules, all of them here so
    /// the pipeline never has to decide anything:
    ///
    /// 1. **A label for a title that was not requested, or that resolved
    ///    away, is ignored.** The labels are a dictionary, not a parallel
    ///    array, and they are looked up by an index this function has
    ///    already checked against `disc` — so a label can never pull a title
    ///    into the plan, and can never attach to the wrong one. This is
    ///    #0028's rule applied to the second input: an index from one scan
    ///    must not be believed against another.
    /// 2. **A label that sanitises to nothing is not a label.**
    ///    `PlexExtra.sanitize("..")` is `""`, and a nameless file in a Plex
    ///    extras folder is worse than the same file in `Clips` — there is
    ///    nothing for Plex to show a person. It falls back to `.clip`, which
    ///    is exactly what it would have been before this ticket.
    /// 3. **The raw label, not the sanitised one, is carried into the
    ///    destination.** `PlexExtra.kind(forLabel:)` reads keywords, and
    ///    `PlexExtra.fileName` sanitises again at the point the string
    ///    becomes a path component — one sanitiser, at the boundary, the way
    ///    `MovieMetadata` does it (#0010).
    /// #0196 — `kinds` names the Plex extras subfolder outright for a title,
    /// instead of letting `kind(forLabel:)` read it off the label.
    ///
    /// The window has no control for this and does not need one: the label comes
    /// off the disc's own menu, and `PlexExtra.kind(forLabel:)`'s keyword rules
    /// were written against the captured corpus of what menus actually print. An
    /// **agent** is in a different position. It has read the OCR, the menu
    /// structure and the model's answer, and may know perfectly well that "full
    /// circle" is a featurette and "Signs: a commentary" is not a making-of,
    /// which the keyword rules cannot. So `changeoverctl select --extra-kind`
    /// exists, and it has to land somewhere.
    ///
    /// Additive and defaulted empty, which matters: every existing caller — the
    /// window's running total, `JobController.start`, and ~15 construction sites
    /// across the extras tests — passes nothing and gets exactly today's
    /// behaviour. An override can only ever *narrow* the choice to one of
    /// `PlexExtra.Kind`'s eight cases, because the parameter is typed as the enum
    /// and the unrecognised folder name was already refused at the boundary
    /// (`AgentSelectionPlan`). There is no spelling of a folder name that can
    /// reach this.
    ///
    /// A kind given for a title with no usable label is still honoured: the extra
    /// goes to the named folder as `Bonus Feature - tNN.mp4`, which is honest
    /// about being title NN of the disc and is in the right place for Plex.
    nonisolated static func make(
        featureIndex: Int,
        requested: [Int],
        disc: DiscInfo,
        labels: [Int: String] = [:],
        kinds: [Int: PlexExtra.Kind] = [:]
    ) -> ExtrasPlan {
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
                interlaceDetected: title.interlaceDetected,
                filing:            filing(forLabel: labels[index], kind: kinds[index])
            )
        }
        return ExtrasPlan(items: items)
    }

    /// Rule 2 above, on its own so it is testable without a `DiscInfo`.
    /// #0192 — every extra is filed with its film. There is no second place.
    ///
    /// This used to send an extra with no usable name to `Clips`, a folder
    /// deliberately outside the Plex libraries. The user asked what `Clips`
    /// was for, and the honest answer was: nothing Plex knows about. It is not
    /// a Plex feature, it was invented here, and its entire purpose was being
    /// somewhere Plex was not looking.
    ///
    /// That workaround was right in September and obsolete by October. #0031
    /// built `Clips` because at the time *any* video near a film in `Movies/`
    /// would be scanned as a second film. #0174 adopted Plex's own extras
    /// convention — the recognised subfolder names Plex excludes from the
    /// movie scan — which is exactly the exemption that made the workaround
    /// unnecessary. Nobody went back to retire it, so the app kept two
    /// destinations for one kind of content and chose between them on whether
    /// OCR happened to read a menu page. A disc read well put its making-of
    /// beside the film; the same disc read badly hid it where Plex never
    /// looks. The thing that varied was the app's luck, not the user's
    /// content.
    ///
    /// So an unnamed extra goes to `Other`, which is a real Plex extras
    /// folder, under the name `PlexExtra.fileName` already generates for this
    /// case — `Bonus Feature - t08.mp4`, honest about being title 8 of the
    /// disc and nothing more. Both halves existed; nothing reached for them.
    /// #0196 — `kind` overrides the derivation, and nothing else about the rule
    /// changes. A label that sanitises to nothing is still not a label, so the
    /// filename still falls back to `Bonus Feature - tNN`; what an override
    /// changes is only which of Plex's eight folders the file lands in.
    nonisolated static func filing(forLabel label: String?, kind: PlexExtra.Kind? = nil) -> Filing {
        guard let label, !PlexExtra.sanitize(label).isEmpty else {
            return .bonusFeature(kind: kind ?? .other, label: "")
        }
        return .bonusFeature(kind: kind ?? PlexExtra.kind(forLabel: label), label: label)
    }

    // MARK: - Where the labels come from

    /// #0178 — the `labels` map, read off the disc's own menu text with no
    /// model involved.
    ///
    /// This is #0174's measured path and nothing more: a printed runtime next
    /// to a printed name is a fact two independent readings of the disc agree
    /// on, and `MenuExtraLabels.match` binds them one to one, globally
    /// optimally. On Signs that is six labels onto titles 9–14, every pairing
    /// inside five seconds. A label that fits no title is dropped rather than
    /// forced — naming a title wrongly puts the wrong video in the film's own
    /// folder, which is worse than leaving it in `Clips` unnamed.
    ///
    /// `titles` should be the titles a label could plausibly be about: not
    /// the feature, and not the sub-30-second logo stings and menu loops
    /// `DiscInterrogation.shortestWorthNaming` already refuses to name.
    /// `MenuExtraLabels.match` caps both sides at eight (`maximumLabels`) and
    /// returns nothing past that, so a very crowded disc goes unnamed — which
    /// is #0174's deliberate stance, not an oversight.
    nonisolated static func labels(printedOn menuLines: [String], titles: [DiscTitle]) -> [Int: String] {
        let matches = MenuExtraLabels.match(
            printed: MenuExtraLabels.printedLabels(in: menuLines),
            to: titles
        )
        return Dictionary(matches.map { ($0.titleIndex, $0.label) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// #0178 — the same map out of a #0175 interrogation, for the half of
    /// this that reads the disc by asking a model rather than by parsing a
    /// printed runtime.
    ///
    /// Only `bonusFeatures` and `extras` are taken. `films` is deliberately
    /// excluded: a film is imported as a film (`DiscRipPlan`), and filing one
    /// as its own extra would hide a whole feature inside another film's
    /// folder — the #0034 data-loss shape. `unverified` is excluded for the
    /// reason it exists: the disc could not corroborate it, and an
    /// uncorroborated name is exactly the DREAMSCAPE failure #0175 was built
    /// to keep out of the library.
    nonisolated static func labels(from understanding: DiscInterrogation.Understanding) -> [Int: String] {
        let named = understanding.bonusFeatures + understanding.extras
        return Dictionary(named.map { ($0.titleIndex, $0.label) },
                          uniquingKeysWith: { first, _ in first })
    }
}
