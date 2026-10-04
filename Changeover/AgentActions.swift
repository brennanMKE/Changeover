import ChangeoverBridge
import Foundation

/// #0196 — the impure half of the acting verbs: the part that actually touches the
/// app.
///
/// Split from the four pure seams beside it (`AgentAuthorization`,
/// `AgentEjectReport`, `AgentSelectionPlan`, `AgentJobReport`) on exactly the
/// principle `BridgeStatusReader` already follows. Everything with judgement in it
/// lives in those; this is deliberately dull — it reads a few properties, calls the
/// seam, and calls the method the window's own control calls. UI tests are
/// forbidden in this project, so a decision taken here instead of there is a
/// decision with no coverage.
///
/// ## The one rule that matters: no second path
///
/// **Every verb here calls the method the UI calls, and builds nothing of its
/// own.** `eject` is `jobs.ejectDisc()`, the same call the status-menu row makes.
/// `cancel` is `jobs.cancel(id:)`, the same call the history window's Cancel
/// makes. `import` is `flow.startRipping(jobs:settings:)` — the Start button,
/// exactly.
///
/// That is not tidiness. `startRipping` is where the extras-only branch is taken,
/// on the Start gate's own verdict; `ripRequest(jobs:feature:metadata:)` is where
/// `JobIntent` is set from `extrasOnlyApplies(to:)`; and `JobIntent
/// .featureDestination` returns `nil` for `.extrasOnly`, so `DVDPipeline.run()`'s
/// entire feature phase — the HandBrake pass, #0037's duration check, #0015's
/// fallback, the `.encoded` marker and the `PlexOrganizer.move` that replaces a
/// library file — sits inside an `if let` the compiler will not enter. The
/// guarantee that an import cannot overwrite a film already in Plex is **a missing
/// value, not a remembered check**, and it is inherited here for free precisely
/// because nothing here constructs a `RipRequest`.
///
/// A parallel path that built its own request would have to re-derive the intent,
/// and would be one `if` away from re-deriving it wrongly. There is no such path
/// and there must not be one.
///
/// ## Visibility
///
/// Every verb records three things before it returns, for three different readers:
/// `AppXPCServer.lastActivity` for the window's agent banner (#0195, the person at
/// the machine), `FlowDiagnostics.note` for the file anyone can read over SSH, and
/// an `agent.action` event broadcast to every attached session (the *other* agent
/// watching the same disc). A destructive act that only one of the three could see
/// would be invisible to the other two.
@MainActor
enum AgentActions {

    // MARK: - eject

    /// Opens the tray, and says which of the three things happened.
    ///
    /// `--force` waives only the job-running refusal, and it waives it by
    /// **cancelling the job first** rather than by ejecting under it. Ejecting
    /// under a live `HandBrakeCLI` is the thing `EjectPolicy` was written to
    /// prevent: it either comes back busy or takes the volume down mid-encode, and
    /// the encode then fails with a disc-shaped reason that gets blamed on the
    /// disc. So force means "end the job, then eject", which is what an agent
    /// asking for it actually wants — and the job ends through `cancel(id:)`, the
    /// one path that reaches `JobController.finish` and releases #0047's sleep
    /// assertion.
    static func eject(
        _ request: EjectRequest,
        jobs: JobController,
        sessionsAttached: Int
    ) async -> ActionResult {
        // Captured before the eject, because a successful one takes the disc away:
        // `removeDisc()` clears `insertedDisc`, and a result that reported `nil`
        // would leave an agent unable to confirm *which* disc came out.
        let disc = BridgeStatusReader.discStatus(
            jobs.insertedDisc,
            isEjecting: jobs.isEjecting,
            unavailable: jobs.discUnavailable,
            hasMoreWork: jobs.discHasMoreWork
        )

        if let mismatch = discMismatch(request.discInsertionID, jobs: jobs) {
            return refusal(
                verb: BridgeRequest.Action.eject,
                outcome: mismatch.outcome,
                detail: mismatch.reason,
                sessionsAttached: sessionsAttached,
                disc: disc
            )
        }

        var forcedNote: String?
        if request.force, jobs.isRunning, let id = jobs.current?.id {
            let cancelled = jobs.cancel(id: id)
            forcedNote = cancelled
                ? "--force cancelled \(id.rawValue) first. "
                : "--force could not cancel \(id.rawValue). "
            // The cancel reaches the job's `Task`, which has to unwind through
            // `ProcessRunner`'s SIGTERM→SIGKILL grace before `isRunning` clears.
            // Ejecting in the same turn would hit `EjectPolicy.jobRunningReason`
            // and look like force did nothing, so this waits for the job to
            // actually end — bounded, because a wait with no bound in an XPC
            // handler is a hung CLI.
            await waitForJobToEnd(jobs: jobs, within: .seconds(20))
        }

        _ = await jobs.ejectDisc()
        var report = AgentEjectReport.report(for: jobs.lastEjectAttempt)
        if let forcedNote {
            report = AgentEjectReport.Report(
                outcome: report.outcome,
                detail: forcedNote + report.detail
            )
        }

        return ActionResult(
            verb: BridgeRequest.Action.eject,
            outcome: report.outcome,
            detail: report.detail,
            sessionsAttached: sessionsAttached,
            disc: disc
        )
    }

    // MARK: - cancel

    static func cancel(
        _ request: CancelRequest,
        jobs: JobController,
        sessionsAttached: Int
    ) -> ActionResult {
        guard let running = jobs.current else {
            return refusal(
                verb: BridgeRequest.Action.cancel,
                outcome: ActionOutcome.refusedNothingRunning,
                detail: "no job is running."
                    + (jobs.history.last.map { " The last one was \($0.id.rawValue)." } ?? ""),
                sessionsAttached: sessionsAttached
            )
        }

        // A named id that is not the running one is refused rather than redirected.
        // The realistic case is an agent that was away for forty minutes: on a disc
        // holding two films, "cancel the job I started" and "cancel whatever is
        // running" are different jobs, and silently doing the second would stop a
        // film nobody asked to stop.
        if let named = request.jobID, named != running.id.rawValue {
            return refusal(
                verb: BridgeRequest.Action.cancel,
                outcome: ActionOutcome.refusedNothingRunning,
                detail: "job \(named) is not running — \(running.id.rawValue) is. "
                    + "Nothing was cancelled.",
                sessionsAttached: sessionsAttached,
                jobID: running.id.rawValue
            )
        }

        // `CancelPolicy` is the gate, and `cancel(id:)` applies it and logs its own
        // refusal. The decision is read here only to name the outcome, never to
        // take it a second time (#0172: two readers of one fact become two
        // definitions of it).
        let decision = CancelPolicy.decide(
            requestedID: running.id,
            currentID: running.id,
            phase: running.state.phase
        )
        if let reason = decision.refusalReason {
            return refusal(
                verb: BridgeRequest.Action.cancel,
                outcome: ActionOutcome.refusedPhase,
                detail: reason,
                sessionsAttached: sessionsAttached,
                jobID: running.id.rawValue
            )
        }

        guard jobs.cancel(id: running.id) else {
            return refusal(
                verb: BridgeRequest.Action.cancel,
                outcome: ActionOutcome.refusedPhase,
                detail: "the cancel was refused; the job log says why.",
                sessionsAttached: sessionsAttached,
                jobID: running.id.rawValue
            )
        }

        return ActionResult(
            verb: BridgeRequest.Action.cancel,
            // `cancelling`, not `cancelled`. The cancel has reached the job's
            // `Task`; the job still unwinds through `finish(_:)` like any other
            // terminal outcome, which is what makes a cancel indistinguishable
            // downstream from a failure. Wait for `job-done`.
            outcome: ActionOutcome.cancelling,
            detail: "cancelling \(running.id.rawValue) — HandBrakeCLI is being stopped. "
                + "Wait for it with `changeoverctl wait --for job-done --job \(running.id.rawValue)`.",
            sessionsAttached: sessionsAttached,
            jobID: running.id.rawValue
        )
    }

    // MARK: - select

    static func select(
        _ request: SelectionRequest,
        jobs: JobController,
        flow: RipFlowController,
        settings: AppSettings,
        sessionsAttached: Int
    ) async -> ActionResult {
        let decision = AgentSelectionPlan.decide(
            request: request,
            mountedInsertionID: jobs.insertedDisc?.insertionID.uuidString,
            // From `JobController.scanState`, not `RipFlowController
            // .currentScanState`. The latter is a mirror written on reconcile, and
            // a `select` arriving between a scan settling and the next reconcile
            // would read it as "no scan" and refuse a request that was perfectly
            // good. The controller's own state is what `JobController.start`
            // resolves against, so this is the one that cannot disagree with the
            // encode (#0172).
            scannedTitleIndices: scannedTitleIndices(jobs: jobs),
            isRunning: jobs.isRunning,
            isConfigured: settings.isConfigured
        )
        guard case .apply(let resolved) = decision else {
            guard case .refuse(let outcome, let reason) = decision else {
                preconditionFailure("AgentSelectionPlan.Decision gained a case")
            }
            return refusal(
                verb: BridgeRequest.Action.select,
                outcome: outcome,
                detail: reason,
                sessionsAttached: sessionsAttached
            )
        }

        // The feature first: `selectTitle` recomputes the audio preselection and
        // drops the new feature from the extras set, so an extra ticked before it
        // would be silently un-ticked. Order matters and this is the order the
        // window's own flow uses.
        if let feature = resolved.featureTitle, jobs.selectedTitleIndex != feature {
            jobs.selectTitle(feature, settings: settings)
        }

        // Then the film. `search.select` resolves the movie out of the results the
        // app is holding, which is why an id it has never seen needs a `--query`:
        // `TMDBMovie` carries the release date, `TMDBMovieDetails` does not, and a
        // Plex folder with the wrong year is a folder Plex reads as a different
        // film. Rather than invent a year, the app goes and searches.
        if let movieID = resolved.movieID {
            if flow.search.results.contains(where: { $0.id == movieID }) == false {
                guard let query = resolved.query else {
                    return refusal(
                        verb: BridgeRequest.Action.select,
                        outcome: ActionOutcome.refusedMovieNotFound,
                        detail: "tmdb-\(movieID) is not among the results Changeover is holding, "
                            + "and no --query was given to find it. Add "
                            + "`--query \"<title>\"` so the app can search for it.",
                        sessionsAttached: sessionsAttached
                    )
                }
                let results = await flow.search.probe(query, apiKey: settings.tmdbAPIKey)
                guard results.contains(where: { $0.id == movieID }) else {
                    return refusal(
                        verb: BridgeRequest.Action.select,
                        outcome: ActionOutcome.refusedMovieNotFound,
                        detail: "searching TMDB for \"\(query)\" returned "
                            + "\(results.isEmpty ? "nothing" : "\(results.count) film(s)")"
                            + ", none of them tmdb-\(movieID). Nothing was selected.",
                        sessionsAttached: sessionsAttached
                    )
                }
                flow.search.present(query: query, results: results)
            }
            flow.select(movieID: movieID, jobs: jobs, apiKey: settings.tmdbAPIKey)
        }

        // Then the extras. The tick goes through `toggleExtra`, which refuses the
        // feature title; the label and the kind go into the agent-owned maps
        // `extraLabels` reads first, so `applyBonusFeatures` cannot wipe them on
        // the next reconcile.
        for extra in resolved.extras {
            // Refused against the title the controller is *currently* holding as
            // well as against the one in the request. `AgentSelectionPlan` checks
            // the request's own pair; this catches the case where the request names
            // no feature and the extra happens to be the feature already settled —
            // `ExtrasPlan.make` would drop it anyway, but a tick the pipeline will
            // discard is a selection that disagrees with itself, which is the shape
            // of this window's worst bugs (#0030, #0167, #0172).
            guard extra.titleIndex != jobs.selectedTitleIndex else {
                return refusal(
                    verb: BridgeRequest.Action.select,
                    outcome: ActionOutcome.refusedUnknownTitle,
                    detail: "title \(extra.titleIndex) is already the feature, so it cannot also "
                        + "be one of its own extras. Name a different feature first if that is "
                        + "what you meant.",
                    sessionsAttached: sessionsAttached
                )
            }
            jobs.selectedExtraTitleIndices.insert(extra.titleIndex)
            if let label = extra.label { jobs.agentExtraLabels[extra.titleIndex] = label }
            if let kind = extra.kind { jobs.agentExtraKinds[extra.titleIndex] = kind }
        }

        // Reported back from the resolved plan rather than from the request, so an
        // agent reads what the app will actually do — including the folder a label
        // was derived into, which it did not name.
        let plan = jobs.selectedExtrasPlan
        let extras = plan.items.map { item -> PlannedExtra in
            PlannedExtra(
                titleIndex: item.titleIndex,
                label: item.label,
                folderName: folderName(of: item),
                durationSeconds: item.durationSeconds
            )
        }

        return ActionResult(
            verb: BridgeRequest.Action.select,
            outcome: ActionOutcome.selected,
            detail: describe(resolved: resolved, extras: extras, flow: flow),
            sessionsAttached: sessionsAttached,
            film: currentFilm(flow: flow),
            featureTitle: jobs.selectedTitleIndex,
            extras: extras
        )
    }

    // MARK: - import

    /// Presses Start.
    ///
    /// Four lines of substance and every one of them a call into the flow the
    /// window drives. The no-overwrite guarantee is not restated here because it is
    /// not implementable here: it lives in `JobIntent.featureDestination` returning
    /// `nil`, and this inherits it by not having a path of its own.
    static func importFilm(
        _ request: ImportRequest,
        jobs: JobController,
        flow: RipFlowController,
        settings: AppSettings,
        sessionsAttached: Int
    ) -> ActionResult {
        let disc = BridgeStatusReader.discStatus(
            jobs.insertedDisc,
            isEjecting: jobs.isEjecting,
            unavailable: jobs.discUnavailable,
            hasMoreWork: jobs.discHasMoreWork
        )

        guard settings.isConfigured else {
            return refusal(
                verb: BridgeRequest.Action.import,
                outcome: ActionOutcome.refusedNotConfigured,
                detail: "Changeover has no Plex library root or no TMDB key yet.",
                sessionsAttached: sessionsAttached,
                disc: disc
            )
        }

        guard jobs.insertedDisc != nil else {
            return refusal(
                verb: BridgeRequest.Action.import,
                outcome: ActionOutcome.refusedNoDisc,
                detail: EjectPolicy.noDiscReason,
                sessionsAttached: sessionsAttached
            )
        }

        // The swap check, before the gate. An import decided for a disc that has
        // left is not a gate question — every title index in the selection belongs
        // to something else — and it is the one refusal here whose absence costs a
        // file in the library.
        if let mismatch = discMismatch(request.discInsertionID, jobs: jobs) {
            return refusal(
                verb: BridgeRequest.Action.import,
                outcome: mismatch.outcome,
                detail: mismatch.reason,
                sessionsAttached: sessionsAttached,
                disc: disc
            )
        }

        // The Start gate, read once. `permitsStart`, never `== .ready`: there are
        // two permitting cases, and `readyForExtrasOnly` is the one that imports
        // bonus material beside a film the library already has. Comparing against
        // one of them is exactly the bug that flag exists to prevent.
        let gate = flow.startDecision(jobs: jobs)
        guard gate.permitsStart else {
            return refusal(
                verb: BridgeRequest.Action.import,
                outcome: ActionOutcome.refusedNotPermitted,
                detail: gate.reason ?? gate.plainReason ?? "Start is not available.",
                sessionsAttached: sessionsAttached,
                disc: disc,
                film: currentFilm(flow: flow),
                startDecision: gate.rawValue
            )
        }

        // #0186's intent, read from the gate's own verdict — the same reading
        // `startRipping` takes, so the reported intent cannot disagree with the one
        // that runs.
        let intent: JobIntent = gate == .readyForExtrasOnly ? .extrasOnly : .film

        guard flow.startRipping(jobs: jobs, settings: settings) else {
            return refusal(
                verb: BridgeRequest.Action.import,
                outcome: ActionOutcome.refusedNotPermitted,
                detail: "Start was available but no job began — every film on this disc may "
                    + "already be in Plex. The job log says which.",
                sessionsAttached: sessionsAttached,
                disc: disc,
                film: currentFilm(flow: flow),
                startDecision: gate.rawValue
            )
        }

        let jobID = jobs.current?.id.rawValue
        return ActionResult(
            verb: BridgeRequest.Action.import,
            outcome: ActionOutcome.started,
            detail: (jobID.map { "started \($0)" } ?? "started")
                + (intent == .extrasOnly
                    ? " — extras only. The film already in Plex is not touched: an extras-only "
                        + "job has no feature destination at all."
                    : "")
                + (jobID.map {
                    " Wait for it with `changeoverctl wait --for job-done --job \($0)`."
                } ?? ""),
            sessionsAttached: sessionsAttached,
            jobID: jobID,
            disc: disc,
            film: BridgeStatusReader.filmStatus(
                jobs.currentMetadata,
                resolvedBy: nil,
                chosenByUser: false,
                libraryCheck: .idle
            ),
            intent: intent.rawValue
        )
    }

    // MARK: - report

    static func report(
        jobs: JobController,
        flow: RipFlowController
    ) -> JobReport {
        var facts = jobs.history.map {
            AgentJobReport.JobFacts(snapshot: $0.snapshot, request: $0.request)
        }
        if let current = jobs.current {
            facts.append(AgentJobReport.JobFacts(snapshot: current.snapshot, request: current.request))
        }
        return AgentJobReport.make(
            disc: BridgeStatusReader.discStatus(
                jobs.insertedDisc,
                isEjecting: jobs.isEjecting,
                unavailable: jobs.discUnavailable,
                hasMoreWork: jobs.discHasMoreWork
            ),
            plan: flow.ripPlan,
            history: facts,
            reliability: DiscReliabilityLog.recentRecords()
        )
    }

    // MARK: - Helpers

    /// The title indices of the scan the controller is **holding right now**.
    ///
    /// Empty when there is no completed scan, which `AgentSelectionPlan` reads as a
    /// different refusal from "that index is not on the disc" — an agent that
    /// arrived early should wait, and one that named title 99 should not.
    private static func scannedTitleIndices(jobs: JobController) -> [Int] {
        guard case .scanned(let scan) = jobs.scanState else { return [] }
        return scan.disc.titles.map(\.index)
    }

    /// Whether the named disc is the one in the drive.
    ///
    /// Compared on the **insertion token**, not on `discID` or the label. Two discs
    /// with no resolvable identity mount at the same path with the same device
    /// node, and catalogue-number labels like `7000078778_1` are common and tell
    /// you nothing; the insertion token is minted once per insertion, so it is the
    /// only value that is never equal across two visits. That is what
    /// `DiscStatus.insertionID` is reported for.
    private static func discMismatch(
        _ named: String?,
        jobs: JobController
    ) -> (outcome: String, reason: String)? {
        guard let named else { return nil }
        guard let mounted = jobs.insertedDisc?.insertionID.uuidString else {
            return (ActionOutcome.refusedNoDisc, EjectPolicy.noDiscReason)
        }
        guard named != mounted else { return nil }
        return (
            ActionOutcome.refusedDiscSwapped,
            AgentSelectionPlan.discSwappedReason(named: named, mounted: mounted)
        )
    }

    /// Waits, bounded, for a cancelled job to actually end.
    ///
    /// Polled rather than awaited on the job's `Task`, which `JobController` keeps
    /// private — and polling is honest here in a way it is not in the CLI: this is
    /// one bounded wait inside one request, not a client hammering an app it cannot
    /// see into. The bound is what matters: an unbounded wait in an XPC handler is
    /// a hung CLI, and the handler's own `--timeout` would fire first and report a
    /// transport failure for something that was merely slow.
    private static func waitForJobToEnd(jobs: JobController, within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while jobs.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func refusal(
        verb: String,
        outcome: String,
        detail: String,
        sessionsAttached: Int,
        jobID: String? = nil,
        disc: DiscStatus? = nil,
        film: FilmStatus? = nil,
        startDecision: String? = nil
    ) -> ActionResult {
        ActionResult(
            verb: verb,
            outcome: outcome,
            detail: detail,
            sessionsAttached: sessionsAttached,
            jobID: jobID,
            disc: disc,
            film: film,
            startDecision: startDecision
        )
    }

    private static func currentFilm(flow: RipFlowController) -> FilmStatus? {
        BridgeStatusReader.filmStatus(
            flow.chosenMovie.map { MovieMetadata(from: $0, edition: flow.edition) },
            resolvedBy: flow.resolvedBy,
            chosenByUser: false,
            libraryCheck: flow.libraryCheckForThisEdition
        )
    }

    /// The Plex folder one planned extra will land in.
    ///
    /// Read off `ExtrasPlan.Item.filing`, which is the value the pipeline hands to
    /// `PlexOrganizer.move`, rather than re-derived from the label. A second
    /// derivation would be a second answer, and this one is reported to an agent as
    /// a fact about where the file is going.
    private static func folderName(of item: ExtrasPlan.Item) -> String {
        switch item.filing {
        case .bonusFeature(let kind, _): kind.folderName
        }
    }

    private static func describe(
        resolved: AgentSelectionPlan.Resolved,
        extras: [PlannedExtra],
        flow: RipFlowController
    ) -> String {
        var parts: [String] = []
        if let film = flow.chosenMovie {
            parts.append("\(film.title) (\(film.yearText))")
        }
        if let feature = resolved.featureTitle {
            parts.append("feature on title \(feature)")
        }
        if !extras.isEmpty {
            parts.append("\(extras.count) extra(s): "
                + extras.map { "t\($0.titleIndex)→\($0.folderName)" }.joined(separator: ", "))
        }
        return parts.isEmpty ? "nothing changed." : parts.joined(separator: ", ") + "."
    }
}
