import ChangeoverBridge
import Foundation

/// #0196 — whether a `changeoverctl select` may be applied, and what it resolves
/// to.
///
/// This is the boundary. Everything an agent names arrives as text and integers
/// out of another process, and three of those inputs become path components or
/// encoder arguments:
///
/// - a **disc insertion token**, which is the only thing that can tell one visit
///   from another. Two discs with no resolvable identity mount at the same path
///   with the same device node, so a selection decided for the disc that was in
///   the drive four minutes ago must be refused rather than applied to the one
///   that is in it now. That is #0034's data-loss shape — a stale selection filing
///   a new disc under the previous film's name — reached by a new road.
/// - a **title index**, which is meaningless across scans. #0028's rule: an index
///   from one scan must never be believed against another.
/// - an **extras folder name**, which is the one input where a near miss is worse
///   than a refusal. Plex excludes exactly eight folder names from its movie scan;
///   `Behind the Scenes` is not one of them, so a file in it is scanned as a film
///   and filed as a second movie with a nonsense name. There is no sensible
///   nearest-match here, because the nearest match to a typo is a folder that
///   silently works and a folder that silently does not look identical from the
///   outside.
///
/// So every one of them is checked against the state the app is actually holding,
/// and anything that does not resolve is refused with a named outcome rather than
/// dropped, defaulted or guessed.
///
/// Pure and `nonisolated`, like `StartGate` and `ExtrasOnlyImport`: the refusals
/// are the whole of the externally visible behaviour, and UI tests are forbidden
/// in this project, so a seam that needs a disc to exercise is a seam with no
/// coverage.
nonisolated enum AgentSelectionPlan {

    /// One extra, resolved: an index the scan has and, where it was named, one of
    /// Plex's eight folders as a typed value rather than a string.
    nonisolated struct ResolvedExtra: Equatable, Sendable {
        let titleIndex: Int
        let kind: PlexExtra.Kind?
        let label: String?
    }

    /// A selection that may be applied.
    nonisolated struct Resolved: Equatable, Sendable {
        let featureTitle: Int?
        let movieID: Int?
        let query: String?
        let extras: [ResolvedExtra]
    }

    nonisolated enum Decision: Equatable, Sendable {
        case apply(Resolved)
        /// An ``ActionOutcome`` identifier and the sentence to report.
        case refuse(outcome: String, reason: String)
    }

    /// - Parameters:
    ///   - request: what the CLI sent.
    ///   - mountedInsertionID: `DiscInsertion.insertionID.uuidString` for the disc
    ///     in the drive, or `nil` when the drive is empty.
    ///   - scannedTitleIndices: the title indices of the scan the app is **holding
    ///     right now**. Empty means there is no completed scan, which is a
    ///     different refusal from "that index is not on the disc" — an agent that
    ///     arrived early should wait, and one that named title 99 should not.
    ///   - isRunning: whether a job is running. A selection applied mid-job would
    ///     move the extras out from under it; `RipFlowController
    ///     .applyBonusFeatures` guards the same way, and `startNextFilm` is the
    ///     only thing allowed to change them while a plan is in flight.
    ///   - isConfigured: `AppSettings.isConfigured`. Nothing works before that, and
    ///     saying so is more useful than a TMDB search that fails for a reason an
    ///     agent cannot see.
    static func decide(
        request: SelectionRequest,
        mountedInsertionID: String?,
        scannedTitleIndices: [Int],
        isRunning: Bool,
        isConfigured: Bool
    ) -> Decision {
        guard isConfigured else {
            return .refuse(
                outcome: ActionOutcome.refusedNotConfigured,
                reason: "Changeover has no Plex library root or no TMDB key yet, so there is "
                    + "nothing a selection could be applied to. Settings has to be filled in first."
            )
        }

        guard !request.isEmpty else {
            return .refuse(
                outcome: ActionOutcome.refusedEmptyRequest,
                reason: "the selection named nothing — no film, no feature title and no extras."
            )
        }

        guard !isRunning else {
            return .refuse(
                outcome: ActionOutcome.refusedJobRunning,
                reason: "a job is running, and changing the selection under it would move the "
                    + "extras out from beneath the encode. Wait for it, or cancel it."
            )
        }

        guard let mountedInsertionID else {
            return .refuse(
                outcome: ActionOutcome.refusedNoDisc,
                reason: EjectPolicy.noDiscReason + " There is nothing to select from."
            )
        }

        // The disc check comes before any index check, deliberately. If the disc
        // has been swapped then *every* index in the request is about something
        // else, and reporting "title 4 is not on this disc" would send an agent
        // looking for a scan problem it does not have.
        if let named = request.discInsertionID, named != mountedInsertionID {
            return .refuse(
                outcome: ActionOutcome.refusedDiscSwapped,
                reason: discSwappedReason(named: named, mounted: mountedInsertionID)
            )
        }

        // An index is only meaningful against a scan, so a request carrying one
        // needs the scan to exist. A request that carries none — `--movie` alone —
        // does not, and refusing it would stop an agent naming the film while the
        // scan is still running, which is exactly when it should be allowed to.
        let needsScan = request.featureTitle != nil || !request.extras.isEmpty
        if needsScan, scannedTitleIndices.isEmpty {
            return .refuse(
                outcome: ActionOutcome.refusedNoScan,
                reason: "there is no completed disc scan, so a title index means nothing yet. "
                    + "Wait with `changeoverctl wait --for scan-complete`."
            )
        }

        let known = Set(scannedTitleIndices)

        if let feature = request.featureTitle, !known.contains(feature) {
            return .refuse(
                outcome: ActionOutcome.refusedUnknownTitle,
                reason: unknownTitleReason(feature, known: scannedTitleIndices)
            )
        }

        var resolved: [ResolvedExtra] = []
        for extra in request.extras {
            guard known.contains(extra.titleIndex) else {
                return .refuse(
                    outcome: ActionOutcome.refusedUnknownTitle,
                    reason: unknownTitleReason(extra.titleIndex, known: scannedTitleIndices)
                )
            }
            // An extra that is also the feature is refused rather than dropped.
            // `ExtrasPlan.make` would drop it anyway, and that is the right
            // behaviour for a window where a click can collide with a selection —
            // but an agent that asked for one title to be both is confused, and an
            // exit 0 would leave it believing something that is not going to
            // happen.
            if let feature = request.featureTitle, extra.titleIndex == feature {
                return .refuse(
                    outcome: ActionOutcome.refusedUnknownTitle,
                    reason: "title \(feature) cannot be both the feature and one of its own extras."
                )
            }

            var kind: PlexExtra.Kind?
            if let named = extra.kind {
                guard let matched = PlexExtra.Kind(rawValue: named) else {
                    return .refuse(
                        outcome: ActionOutcome.refusedUnknownExtrasFolder,
                        reason: unknownFolderReason(named)
                    )
                }
                kind = matched
            }
            resolved.append(
                ResolvedExtra(titleIndex: extra.titleIndex, kind: kind, label: extra.label)
            )
        }

        return .apply(
            Resolved(
                featureTitle: request.featureTitle,
                movieID: request.movieID,
                query: request.query,
                extras: resolved
            )
        )
    }

    // MARK: - The sentences

    /// Names both tokens, because the useful question for an agent is "is this the
    /// disc I was told about" and it cannot answer that from a refusal that only
    /// says no.
    static func discSwappedReason(named: String, mounted: String) -> String {
        "the disc in the drive is not the one this was decided for. You named insertion "
            + "\(named); the drive holds \(mounted). Every title index you chose belongs to a "
            + "disc that has left, so nothing was applied. Read `status` again and decide from "
            + "the current scan."
    }

    /// Lists what the scan does have. A refusal that only says "not found" leaves
    /// an agent to go and ask, and the answer is three words long.
    static func unknownTitleReason(_ index: Int, known: [Int]) -> String {
        "title \(index) is not on the disc Changeover scanned. Its titles are "
            + "\(known.sorted().map(String.init).joined(separator: ", "))."
    }

    /// **Never suggests a nearest match**, and that is the point.
    ///
    /// The realistic typo is a case difference — `Behind the Scenes` — and a
    /// nearest-match correction would accept it and file into the right folder,
    /// which teaches an agent that the spelling is forgiving. It is not: Plex
    /// matches these names, and the next near miss would go into a folder Plex
    /// scans as a film. Refusing with the list is the only answer that leaves the
    /// agent knowing the truth.
    static func unknownFolderReason(_ named: String) -> String {
        "'\(named)' is not one of Plex's extras folders. Plex excludes exactly these "
            + "from its movie scan, spelled exactly like this: "
            + PlexExtra.Kind.allCases.map(\.folderName).joined(separator: ", ")
            + ". A folder that is not on that list is scanned as a film and filed as a "
            + "second movie with a nonsense name, so a near miss is refused rather than "
            + "corrected. Omit the kind to let Changeover derive it from the label."
    }
}
