import Foundation

/// #0186 — the user's explicit "bring in just the extras", recorded against
/// the one film *and* the one library folder it was given for.
///
/// Exactly `ReplaceAcknowledgement`'s shape (#0143), which is itself #0032's
/// `MismatchAcknowledgement` shape, and for the same reason: a bare `Bool`
/// survives picking a different movie in the results, so a confirmation given
/// for film A would silently enable Start for film B.
///
/// It is a **separate type** from `ReplaceAcknowledgement` on purpose, not a
/// second case on it or a flag beside it. The two answer the same question —
/// "this film is already in Plex, now what?" — with opposite consequences:
/// Replace re-encodes the feature and overwrites the library file (#0012's
/// staged `replaceItemAt`), while this one never touches that file at all.
/// Carrying both answers in one value would make the destructive reading one
/// typo away from the harmless one, and it is the destructive one that cannot
/// be undone. Two types means the compiler, not a reviewer, keeps them apart —
/// and `StartGate.libraryDecision` still checks Replace *first*, so a disc with
/// both answers recorded does the thing the user asked for most recently
/// (`RipFlowController` clears each when the other is given).
nonisolated struct ExtrasOnlyAcknowledgement: Equatable, Sendable {
    let movieID: Int
    /// The matched folder as it is on disk — the same key
    /// `ReplaceAcknowledgement` uses, so a confirmation shown for one folder
    /// never counts for another.
    let folderPath: String
}

/// #0186 — what a job is for: importing the film, or importing only the bonus
/// material beside a film the library already holds.
///
/// The common case for anyone with an existing Plex library: the feature was
/// ripped years ago and the making-of is still on the disc. #0185 stopped the
/// app ejecting such a disc; this is the other half.
///
/// `Codable`/`Hashable` because it travels on `RipRequest`, which is wire
/// format (#0027) — additive, with `.film` as the default, so a payload
/// predating this ticket decodes to an ordinary rip.
nonisolated enum JobIntent: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    /// Encode the feature, file it into `Movies/`, then the extras. Every job
    /// before #0186.
    case film
    /// Encode and file only the ticked extras, into the folder of a film the
    /// library already has. No feature encode, no feature move.
    case extrasOnly

    /// Where this run files the feature it encoded — and `nil` when it encodes
    /// no feature at all.
    ///
    /// **This is the whole safety argument for #0186.** `LibraryDestination
    /// .feature` is the one value in the app that resolves to the film's own
    /// file inside `Movies/`, and `PlexOrganizer.move` replaces whatever is at
    /// that path on purpose (#0012's staged `replaceItemAt`). A library copy
    /// the user ripped years ago, over a disc they may no longer have, is the
    /// one irreversible outcome this app can produce.
    ///
    /// So an extras-only run does not *decline* to move the feature: it has no
    /// destination to move one to. `DVDPipeline.run()` binds this with
    /// `if let`, which means the HandBrake pass over the disc, #0037's duration
    /// check, #0015's MakeMKV fallback, the `.encoded` marker and the
    /// `PlexOrganizer.move` call are all inside a branch the compiler will not
    /// enter for `.extrasOnly`. The guarantee is a missing value, not a
    /// remembered check — and a future edit that wants to move a feature has to
    /// get a destination from here to do it.
    ///
    /// The extras themselves were never a hazard: `ExtrasPlan.Item.destination`
    /// can only ever produce `.extra` or `.bonusFeature`, so the loop that
    /// files them has no way to name the feature's path either.
    var featureDestination: LibraryDestination? {
        switch self {
        case .film:
            return .feature
        case .extrasOnly:
            return nil
        }
    }
}

/// #0186 — the pure half of an extras-only run: whether it may proceed, and
/// what to say when it may not.
///
/// A plain-value seam for the same reason `StartGate` and `ExtrasPlan` are
/// ones: this is the only coverage the decision can have (UI tests are
/// forbidden), and the refusal sentences are the user's whole explanation for
/// a job that did nothing.
nonisolated enum ExtrasOnlyImport {

    /// Why an extras-only run can or cannot go ahead.
    nonisolated enum Readiness: Equatable, Sendable {
        case ready
        /// Nothing is ticked, so there is no work. A job that encodes nothing
        /// and files nothing is not a success with zero extras — it is a
        /// request that should never have been accepted, and `JobController
        /// .start` refuses it before this is ever reached. Kept here as the
        /// pipeline's own failsafe at the point of harm, the pattern #0034
        /// established.
        case nothingTicked
        /// The film's folder is not in the library, so there is nowhere beside
        /// the film for an extra to go.
        case noFilmFolder(path: String)
    }

    /// - Parameters:
    ///   - filmFolder: `LibraryPaths.filmFolder(metadata:roots:)` — the folder
    ///     `LibraryPaths.resolve` will *actually* file a bonus feature inside.
    ///     Passed in rather than derived here so there is exactly one place
    ///     that spells this path (#0172: two places computing one answer is how
    ///     they come to disagree, and here a disagreement would mean checking
    ///     one folder and writing into another).
    ///   - exists: whether that folder is already a directory on disk.
    ///   - extraCount: `ExtrasPlan.items.count`, after the plan has been
    ///     resolved against the held scan — never the raw ticked set, which can
    ///     still name a title a superseded scan had.
    static func readiness(filmFolder: String, exists: Bool, extraCount: Int) -> Readiness {
        guard extraCount > 0 else { return .nothingTicked }
        guard exists else { return .noFilmFolder(path: filmFolder) }
        return .ready
    }

    /// The typed failure for a readiness that is not `.ready`, or `nil` when it
    /// is.
    ///
    /// **`stage: .preflight` is load-bearing, not decorative.** This is checked
    /// after `Preflight.check` and before this job creates anything, so
    /// `WorkingFiles.disposition` answers `.nothingCreated`: nothing is
    /// deleted, nothing is kept, and no working folder is left for the next
    /// job's sweep to report. A `.organize`-stage refusal would instead keep a
    /// job directory (`.keepJobDirectory`, the #0012 rule protecting a feature
    /// that is the only copy) that holds nothing worth keeping.
    ///
    /// The reason is `.unknown(sentence)` rather than a new `FailureReason`
    /// case because `FailureReason`'s decoder throws on an unknown case key
    /// (#0007 review), so a new case would break an older decoder — the same
    /// constraint that made `FallbackAttempt` an additive field rather than a
    /// case. #0037's short-output refusal already took this shape: a whole
    /// sentence, because `FailurePresenter` renders `.unknown` as "Something
    /// went wrong: …" and the sentence is then the entire explanation.
    static func refusal(for readiness: Readiness) -> JobFailure? {
        switch readiness {
        case .ready:
            return nil
        case .nothingTicked:
            return JobFailure(stage: .preflight, reason: .unknown(
                "nothing was ticked to bring in, so an extras-only import had no work to do. The copy already in Plex was not touched."
            ))
        case .noFilmFolder(let path):
            return JobFailure(stage: .preflight, reason: .unknown(
                "there is no folder at \(path), so there is nowhere beside the film for its extras to go. Import the film itself first, or check that your library files it under this TMDB id. Nothing was created, moved or replaced."
            ))
        }
    }

    /// Whether `path` is already a directory.
    ///
    /// `@concurrent` for the reason `PlexOrganizer.move` and `LibraryProbe
    /// .lookup` are: `plexMediaRoot` is often an SMB/NAS mount, a `stat` of it
    /// is blocking work with no `await` of its own to suspend on, and under
    /// this target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` plus
    /// `NonisolatedNonsendingByDefault` a plain `nonisolated async` function
    /// would still run it on its caller's actor — which for `DVDPipeline.run()`
    /// is MainActor, freezing the menu bar for as long as the mount takes to
    /// answer.
    ///
    /// A path that exists but is a *file* reads as absent, deliberately: the
    /// run refuses rather than handing `createDirectory` something it will
    /// fail on later, after the extras have already been encoded.
    @concurrent
    static func folderExists(_ path: String) async -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
