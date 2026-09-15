import Foundation

/// Who ultimately produced the encoded `.mp4`. Private to the pipeline — not
/// part of `JobOutcome` (#0015 §3: adding a "produced by" value to
/// `.succeeded` would change that case's wire encoding and break older
/// decoders; #0006/#0060 decide the wire shape if a notification ever needs
/// it).
private enum ProducedBy: String {
    case handbrake
    case makemkvFallback
}

/// Wraps a top-level `JobFailure` (already carrying `.fallback`) together
/// with the reliability-log record for what the fallback itself did. A plain
/// tuple can't conform to `Error`, hence this.
private struct FallbackRunFailure: Error {
    let failure: JobFailure
    let record: DiscReliabilityLog.StageReason
}

/// Orchestrates the encode → move pipeline on MainActor.
///
/// Declared as a plain struct so it inherits the module-wide @MainActor default
/// isolation. The log callback is a simple (String) -> Void called on MainActor;
/// EncodeController dispatches its own log calls back to MainActor internally
/// before invoking it.
///
/// `run()` returns a `JobOutcome`. The log is the human channel, the outcome is
/// the machine channel — cleanup (#0004), eject (#0005) and the notification
/// (#0006) all read the outcome rather than inferring anything from the log.
///
/// #0014 removed the rip stage: HandBrakeCLI reads the disc directly, so
/// there is no intermediate `.mkv` on the happy path. #0015 adds `makemkvcon`
/// back in, but only as an optional fallback tried after a disc-shaped
/// HandBrake failure — see `FallbackPolicy` and `MakeMKVRipper`. Only the
/// *primary* HandBrake failure is ever handed to `FallbackPolicy`; the
/// fallback's own result never goes back through it, so a second fallback
/// can never happen.
struct DVDPipeline {
    let metadata: MovieMetadata
    let settings: AppSettings
    /// The mounted disc's volume root, e.g. `/Volumes/FARGO_SE__16X9` — what
    /// HandBrakeCLI is pointed at with `--input`. Supplied by `DVDMonitor`
    /// via `JobController.insertedDisc.mountURL`.
    let disc: URL
    /// #0041 — the one id for this job, minted once by `JobController.start`
    /// and threaded through here instead of this type minting its own (which
    /// is what it used to do, independently of `JobController`'s
    /// `currentJobID` — the exact inconsistency #0041 fixes). Names the
    /// encode job directory, the `▶ Job` log line, and — via
    /// `JobController.start` — the notification identifier and the
    /// fallback's rip job directory, all with the same value. Defaulted so
    /// the ~25 existing construction sites in `EncodeControllerTests`,
    /// `MakeMKVFallbackTests`, `PreflightTests`, `OutputDurationCheckTests`
    /// and `ExtrasPipelineTests` compile unchanged; production always
    /// passes the id `JobController.start` minted.
    var jobID: JobID = JobID.make()
    /// The title, audio tracks and deinterlace filter to encode with.
    /// Defaulted to `.phase1` so the ~25 existing construction sites in
    /// `EncodeControllerTests`, `MakeMKVFallbackTests` and `PreflightTests`
    /// compile unchanged; production always passes a selection built by
    /// `EncodeSelection.make(request:disc:)` via `JobController.pipelineRunner`.
    var selection: EncodeSelection = .phase1
    /// #0031 Step B — the extras to encode and move after the feature.
    /// Defaulted to empty so every existing construction site (tests
    /// included) is unaffected; production always passes the plan
    /// `JobController.start` resolved against the held scan.
    var extras: ExtrasPlan = ExtrasPlan()
    let log: @MainActor (String) -> Void

    /// Where `DiscReliabilityLog.append` writes. Defaulted so existing call
    /// sites (`JobController.pipelineRunner`, `EncodeControllerTests`)
    /// compile unchanged; tests that care about the reliability log point
    /// this at a temp file instead of `DiscReliabilityLog.defaultURL`.
    var reliabilityLogURL: URL = DiscReliabilityLog.defaultURL

    /// #0004 §7 step 10: the test seam for the end-of-job disposal. A test
    /// can force a removal failure (`{ _, _, _ in .failed("boom") }`) to
    /// prove a cleanup failure never changes the outcome (T19). Production
    /// uses the real guard chain.
    var removeJobDirectory: @Sendable (String, String, String) -> WorkingFiles.RemovalResult = {
        WorkingFiles.removeJobDirectory($0, under: $1, forbidding: $2)
    }

    /// #0037: the test seam for the post-encode duration check. Defaulted
    /// to the real `AVURLAsset`-backed measurer so every existing
    /// construction site compiles unchanged; a test injects a fake to
    /// exercise `.short`/`.consistent` without a real media file.
    var measureDuration: @Sendable (URL) async throws -> Int = OutputDurationCheck.measureSeconds

    /// #0041 — reports a mid-job phase transition to whoever is watching
    /// (production: `JobController.applyPhase`, via the `Runner`'s
    /// phase-report closure). Defaulted to a no-op so every existing
    /// construction site compiles unchanged; a test can inject a recording
    /// closure to assert the exact sequence of phases a run reports, with no
    /// `JobController` involved. Called at the four points `run()` actually
    /// crosses a `JobPhase` boundary — before the primary encode
    /// (`.encoding`), before the MakeMKV fallback (`.fallback`), before the
    /// move into Plex (`.organizing`), and before the extras loop
    /// (`.extras`, only when extras run). Terminal phases are never
    /// reported here — `JobController.finish` derives those from the
    /// `JobOutcome` this method returns, through `JobState.finishing(with:)`.
    var reportPhase: @MainActor (JobPhase) -> Void = { _ in }

    // MARK: - Run

    func run() async -> JobOutcome {
        log("── Starting: \(metadata.folderName)")

        // Capture paths on MainActor before entering nonisolated functions
        let discPath          = disc.path
        let handbrakePath     = settings.handbrakePath
        let makemkvconPath    = settings.makemkvconPath
        let workingEncodePath = settings.workingEncodePath
        let workingRipPath    = settings.workingRipPath
        let plexMediaRoot     = settings.plexMediaRoot
        let plexMoviesPath    = settings.plexMoviesPath
        let libraryRoots      = settings.libraryRoots
        let volumeName        = disc.lastPathComponent
        let logURL            = reliabilityLogURL
        let remover           = removeJobDirectory

        // #0004 §2 / #0041: one job id for this run — the encode job
        // directory and, on the fallback path, the rip job directory share
        // it, so the two always correlate. `jobID` is now a caller-supplied
        // property (`JobController.start` mints it) rather than minted here.
        let jobID = self.jobID
        log("▶ Job \(jobID)")

        // #0004 §2: this job encodes into its own fresh directory, so two
        // jobs for the same movie — or a retry after an organize failure —
        // can never share an output path, and HandBrake can never overwrite
        // a kept file.
        let jobDirectory = (workingEncodePath as NSString)
            .appendingPathComponent(jobID.rawValue)
        let mp4Path = (jobDirectory as NSString)
            .appendingPathComponent(metadata.fileName)
        var jobDirectoryCreated = false

        // #0026/#0027/#0029: `selection` is now a caller-supplied property,
        // not a hardcoded `.mainFeature`/default audio — `JobController
        // .pipelineRunner` passes the real `EncodeSelection.make(request:
        // disc:)` result. `.phase1` only survives as the property's default
        // for tests that don't care.

        // Reliability-log bookkeeping, filled in as the run progresses so
        // every `return` below can pass through `finish(_:)` — no path
        // skips the record.
        var producedBy: ProducedBy?
        var primaryRecord: DiscReliabilityLog.StageReason?
        var decisionRecord: String?
        var fallbackRecord: DiscReliabilityLog.StageReason?

        func finish(_ outcome: JobOutcome) async -> JobOutcome {
            // #0009 §4.1: the presenter's rendering of *any* failure, right
            // before it's recorded — this is what replaces a bare exit code
            // with an actual explanation. Every `FALLBACK …` line above stays
            // byte for byte; this only adds to what's already been logged.
            if let failure = outcome.failure {
                let message = FailurePresenter.message(for: failure)
                log("✗ " + message.headline)
                for detail in message.details {
                    log("   " + detail)
                }
            }

            // #0004 §7 step 9: dispose of this job's working directory by
            // the typed outcome. A cleanup refusal or failure is logged and
            // never changes the outcome being returned.
            let disposeOutcome = await WorkingFiles.dispose(
                outcome:              outcome,
                jobDirectoryCreated:  jobDirectoryCreated,
                jobDirectory:         jobDirectory,
                under:                workingEncodePath,
                forbidding:           plexMoviesPath,
                remover:              remover
            )
            switch disposeOutcome {
            case .nothingToDo, .removed:
                break
            case .keptAmbiguousContent(let names):
                log("⚠︎ Kept \(jobDirectory): a successful job's directory should hold nothing but its marker, and it still holds \(names.joined(separator: ", "))")
            case .refused(let reason):
                log("⚠︎ Could not remove \(jobDirectory): \(reason)")
            case .failed(let message):
                log("⚠︎ Could not remove \(jobDirectory): \(message)")
            }

            let record = DiscReliabilityLog.Record(
                date:           ISO8601DateFormatter().string(from: Date()),
                volumeName:     volumeName,
                movie:          metadata.folderName,
                jobID:          jobID.rawValue,
                producedBy:     producedBy?.rawValue,
                primary:        primaryRecord,
                decision:       decisionRecord,
                fallback:       fallbackRecord,
                // Capturing MSG:1005's version string would require widening
                // MakeMKVRipper.rip's return type beyond the plan's given
                // signature; left `nil` here rather than doing that — see
                // `## Gotchas`.
                makemkvVersion: nil,
                outcome:        outcome.failure == nil ? "succeeded" : "failed"
            )
            DiscReliabilityLog.append(record, to: logURL, log: log)
            return outcome
        }

        // #0004 §4: the sweep's report, capped at 5 lines per category so a
        // neglected working folder can't flood the log. None of these lines
        // can fail the job.
        func logSweepReport(_ report: WorkingFiles.SweepReport) {
            if let refusal = report.refusal {
                log("⚠︎ Working-folder sweep refused: \(refusal)")
            }
            for path in report.removed.prefix(5) {
                log("✓ Removed stale working folder \(path)")
            }
            if report.removed.count > 5 {
                log("   …and \(report.removed.count - 5) more removed")
            }
            for kept in report.kept.prefix(5) {
                let movieText = kept.movie.map { " (\($0))" } ?? ""
                switch kept.reason {
                case .keptAfterFailedMove:
                    log("⚠︎ Kept from an earlier job: \(kept.path)\(movieText). The move into Plex failed. Move the .mp4 into Plex by hand, then delete the folder.")
                case .encodedNeverMoved:
                    log("⚠︎ Kept from an earlier job: \(kept.path)\(movieText). Its encode finished but it was never moved into Plex.")
                case .unrecognised:
                    log("⚠︎ Left alone: \(kept.path) — a job folder with no readable marker. Nothing was deleted.")
                case .legacyLooseFile:
                    log("⚠︎ Left alone: \(kept.path) — an older build's loose encode. Nothing was deleted.")
                }
            }
            if report.kept.count > 5 {
                log("   …and \(report.kept.count - 5) more kept")
            }
            for failed in report.failed.prefix(5) {
                log("⚠︎ Could not remove \(failed.path): \(failed.message)")
            }
            if report.failed.count > 5 {
                log("   …and \(report.failed.count - 5) more could not be removed")
            }
        }

        // #0004 §3: advance the job marker. A failed write must land on the
        // safe side: an `encoding` failure just logs (a fresh directory with
        // no marker is never auto-deleted by the sweep); a failed
        // `encoded`/`kept` write removes the marker instead, because a stale
        // `encoding` marker must never sit in front of a complete `.mp4` —
        // and a directory without a marker is kept.
        func advanceMarker(_ state: WorkingFiles.JobMarkerState) async {
            let marker = WorkingFiles.JobMarker(state: state, movie: metadata.folderName)
            if await WorkingFiles.writeMarker(marker, inJobDirectory: jobDirectory) {
                return
            }
            log("⚠︎ Could not write \(jobDirectory)/.changeover-job (state \(state.rawValue))")
            if state == .encoding {
                return
            }
            if await WorkingFiles.deleteMarker(inJobDirectory: jobDirectory) {
                log("⚠︎ Removed the marker instead — the directory will be kept")
            } else {
                log("⚠︎ Could not remove \(jobDirectory)/.changeover-job either")
            }
        }

        // #0037: measures `url` against `expectedSeconds` and logs the
        // verdict — used both for the feature (once, before the marker
        // advances to `.encoded`) and for each extra (before its move).
        // Returns `nil`, having already logged, when the file couldn't be
        // measured at all — a local `.mp4` `AVFoundation` can't open is not
        // one Plex or the Apple TV will play either, so this is treated the
        // same as `.short` by both callers.
        func checkDuration(_ url: URL, expectedSeconds: Int, label: String) async -> OutputDurationCheck.Verdict? {
            let actualSeconds: Int
            do {
                actualSeconds = try await measureDuration(url)
            } catch {
                log("✗ \(label): could not read its duration (\(error.localizedDescription))")
                return nil
            }
            let verdict = OutputDurationCheck.compare(expectedSeconds: expectedSeconds, actualSeconds: actualSeconds)
            let expectedText = DiscTitleFormatting.duration(expectedSeconds)
            let actualText = DiscTitleFormatting.duration(actualSeconds)
            let delta: Int
            let marker: String
            switch verdict {
            case .consistent(let d): delta = d; marker = "✓"
            case .long(let d):       delta = d; marker = "⚠︎"
            case .short(let d):      delta = d; marker = "✗"
            }
            log("\(marker) \(label): runs \(actualText), scan said \(expectedText) (Δ \(String(format: "%+d", delta)) s)")
            return verdict
        }

        // #0037: the feature's check, run on whichever `.mp4` is about to be
        // filed (the primary encode's, then the fallback's). `nil` means
        // the file may proceed. `selection.featureDurationSeconds` is `nil`
        // only for `.phase1` (no scan ever happened); production always sets
        // it via `EncodeSelection.make(request:disc:)`. Never guess a
        // duration: with no scan number, skip the check.
        //
        // A failure is `.encode`-stage, so `WorkingFiles.disposition` removes
        // the job directory: the short file is not the movie, and the disc
        // is still the source. The sentence says so, because the user sees
        // it as "Something went wrong: …".
        func featureDurationFailure(_ url: URL) async -> JobFailure? {
            guard let expectedSeconds = selection.featureDurationSeconds else {
                log("Output duration not checked — no scan duration")
                return nil
            }
            let reason: String
            switch await checkDuration(url, expectedSeconds: expectedSeconds, label: "Output") {
            case .consistent, .long:
                return nil
            case .short(let delta):
                let actualSeconds = expectedSeconds + delta
                reason = "The encoded file runs \(DiscTitleFormatting.duration(actualSeconds)) but the scan said this title runs \(DiscTitleFormatting.duration(expectedSeconds)), so it was discarded, not filed. Any copy already in Plex is untouched."
            case .none:
                reason = "The encoded file's duration could not be read, so it was discarded, not filed. Any copy already in Plex is untouched."
            }
            return JobFailure(stage: .encode, reason: .unknown(reason))
        }

        // #0046: a real user cancel (`JobController.cancel(id:)` →
        // `Task.cancel()` on this job's own `Task`) reaches a running
        // subprocess directly, through `ProcessRunner`'s own
        // `withTaskCancellationHandler` — see `EncodeController.encode`'s
        // classified result. What that can't catch is a cancel that lands
        // in one of the gaps *between* subprocesses, where nothing is
        // suspended inside `ProcessRunner.run` for its cancellation handler
        // to act on. `run()` checks `Task.isCancelled` explicitly at the
        // three such gaps that matter — never inside `PlexOrganizer.move`
        // itself (#0012's stage-then-replace must finish once started; that
        // is `organizing`'s whole reason for having no outgoing `cancelled`
        // edge, #0041) — and reports the same `stage: .encode` a
        // directory-creation failure at the same point already does, so the
        // reliability log and `WorkingFiles.disposition`'s `.encode`-stage
        // cleanup both treat it identically to any other encode-stage
        // failure.
        func cancelledDuringEncode() -> JobFailure {
            JobFailure(stage: .encode, reason: .cancelled)
        }

        // #0004 §4: sweep stale working folders before preflight, so
        // reclaimed space counts toward P6's free-space blocker. It runs
        // here rather than at launch: the volume holding `plexMediaRoot` is
        // often not mounted yet at login, `JobController` clears the log at
        // the start of each job (a launch report would be wiped unread),
        // and leftovers only matter when the next job needs the space.
        let sweepReport = await WorkingFiles.sweep(WorkingFiles.SweepInput(
            plexMediaRoot:     plexMediaRoot,
            workingEncodePath: workingEncodePath,
            workingRipPath:    workingRipPath,
            plexMoviesPath:    plexMoviesPath,
            staleAfter:        WorkingFiles.staleAfter
        ))
        logSweepReport(sweepReport)

        // #0008: preflight — check HandBrake, the Plex destinations and free
        // space before anything touches the disc. Runs here (async, off
        // JobController.start's synchronous refusal) rather than in
        // JobController.start, so a bad path fails through the same
        // JobOutcome/FailurePresenter/reliability-log channel as any other
        // failure, and JobController.Runner's contract never changes.
        let preflightReport = await Preflight.check(PreflightInput(
            handbrakePath:     handbrakePath,
            makemkvconPath:    makemkvconPath,
            plexMediaRoot:     plexMediaRoot,
            plexMoviesPath:    plexMoviesPath,
            workingEncodePath: workingEncodePath
        ))
        for warning in preflightReport.warnings {
            log(FailurePresenter.line(for: warning))
        }
        if let preflightFailure = preflightReport.failure {
            if case .diskFull = preflightFailure.reason, let lowSpace = preflightReport.lowSpace {
                let availableText = ByteCountFormatter.string(fromByteCount: lowSpace.available, countStyle: .file)
                let neededText    = ByteCountFormatter.string(fromByteCount: Preflight.minimumFreeBytes, countStyle: .file)
                log("✗ Free space: \(availableText) on \(lowSpace.path) (needs \(neededText))")
            }
            for extraBlocker in preflightReport.blockers.dropFirst() {
                log("✗ Also: " + FailurePresenter.headline(for: extraBlocker, stage: .preflight))
            }
            primaryRecord = DiscReliabilityLog.StageReason(
                stage:  preflightFailure.stage,
                reason: String(describing: preflightFailure.reason)
            )
            return await finish(.failed(preflightFailure))
        }
        log("✓ Preflight passed")

        // #0016/#0027: the deinterlace/detelecine decision now travels on
        // `selection`, resolved by `EncodeSelection.make(request:disc:)`
        // from the real scanned `frameRate`/`interlaceDetected` — this stage
        // only logs the resolved filter, the same way it only ever takes
        // `selection.title` as a plain parameter rather than reading a scan
        // itself.
        let deinterlaceFilter = selection.filter
        log("▶ Deinterlace: filter=\(deinterlaceFilter)")

        // #0046 boundary 1: before anything is created for this job. A
        // cancel requested this early (still `.starting`) never launches
        // HandBrakeCLI at all.
        if Task.isCancelled {
            let failure = cancelledDuringEncode()
            primaryRecord = DiscReliabilityLog.StageReason(stage: failure.stage, reason: String(describing: failure.reason))
            return await finish(.failed(failure))
        }

        // #0004 §7 step 4: create this job's encode directory — fresh, never
        // adopted — and mark it `encoding` before HandBrake launches. On a
        // creation failure this job created nothing, so it must never delete
        // whatever is at that path: return early with
        // `jobDirectoryCreated == false` and let `finish`'s disposition do
        // nothing.
        do {
            _ = try await WorkingFiles.createJobDirectory(root: workingEncodePath, jobID: jobID.rawValue)
            jobDirectoryCreated = true
        } catch {
            primaryRecord = DiscReliabilityLog.StageReason(
                stage:  .encode,
                reason: String(describing: FailureReason.destinationUnwritable(path: jobDirectory))
            )
            return await finish(.failed(JobFailure(
                stage:  .encode,
                reason: .destinationUnwritable(path: jobDirectory)
            )))
        }
        await advanceMarker(.encoding)
        reportPhase(.encoding)

        // Step 1: Encode, straight from the disc's VIDEO_TS — no rip stage
        // on the happy path.
        var primaryResult = await EncodeController.encode(
            source:        discPath,
            title:         selection.title,
            output:        mp4Path,
            handbrakePath: handbrakePath,
            filter:        deinterlaceFilter,
            audio:         selection.audio,
            log:           log
        )

        // #0037 review: an exit-0 encode that is materially shorter than the
        // scan (or can't be measured) is a primary encode failure, decided
        // *before* `FallbackPolicy` sees the result. A disc read error is
        // exactly what MakeMKV's read recovery exists for, and a manual retry
        // would only repeat HandBrake's read of the same disc. `.unknown` at
        // `.encode` is already disc-shaped ("exit 0 with no output" is the
        // same anomaly, whole rather than partial). The fallback's own output
        // is checked once more below and never goes back through the policy,
        // so a short file can neither loop nor be moved.
        if case .success(let url) = primaryResult,
           let durationFailure = await featureDurationFailure(url) {
            primaryResult = .failure(durationFailure)
        }

        let mp4URL: URL
        switch primaryResult {
        case .success(let url):
            mp4URL = url
            producedBy = .handbrake

        case .failure(let primaryFailure):
            primaryRecord = DiscReliabilityLog.StageReason(
                stage:  primaryFailure.stage,
                reason: String(describing: primaryFailure.reason)
            )

            let decision = FallbackPolicy.decide(
                primary:        primaryFailure,
                makemkvconPath: makemkvconPath,
                // #0008: a directory (or anything else `isExecutableFile`
                // alone would misjudge) at `makemkvconPath` now yields
                // `.notExecutable` → not `.ready`, so the fallback reports
                // `.unavailable` instead of attempting a launch that would
                // just fail.
                isExecutable:   { Preflight.optionalToolState(path: $0) == .ready },
                discStillPresent: {
                    FileManager.default.fileExists(
                        atPath: (discPath as NSString).appendingPathComponent("VIDEO_TS")
                    )
                }
            )

            switch decision {
            case .notEligible:
                decisionRecord = "notEligible"
                // #0009: `finish(_:)` now says this better than a fixed
                // string ever could — no replacement line needed here.
                return await finish(.failed(primaryFailure))

            case .unavailable(let path):
                decisionRecord = "unavailable"
                log("✗ FALLBACK UNAVAILABLE disc=\"\(volumeName)\" handbrake=\(String(describing: primaryFailure.reason)) makemkvcon=\(path) (not installed)")
                return await finish(.failed(JobFailure(
                    stage:    primaryFailure.stage,
                    reason:   primaryFailure.reason,
                    logTail:  primaryFailure.logTail,
                    fallback: .unavailable(makemkvconPath: path)
                )))

            case .attempt:
                // #0046 boundary 2: checked before touching anything the
                // fallback attempt itself would (the partial-encode
                // cleanup, the rip job directory, `makemkvcon`) — a cancel
                // here must end the job as `.cancelled`, never start ripping
                // with MakeMKV to satisfy a request to stop.
                //
                // Belt and suspenders with `MakeMKVRipper.rip`'s own
                // cancelled-termination check: this boundary is what keeps a
                // cancel that arrives right here from ever creating a rip
                // job directory at all, rather than creating one and
                // immediately failing it.
                if Task.isCancelled {
                    decisionRecord = "cancelled"
                    return await finish(.failed(cancelledDuringEncode()))
                }

                decisionRecord = "attempted"
                log("⚠︎ FALLBACK disc=\"\(volumeName)\" handbrake=\(String(describing: primaryFailure.reason)) makemkvcon=\(makemkvconPath) → ripping with MakeMKV")

                // #0004 §1: the primary's partial `.mp4` is useless — the
                // second encode overwrites this path anyway — and removing
                // it now frees about 1 GB before the fallback's 5–8 GB rip.
                // Refusal or failure only logs a warning; a missing file is
                // normal (the primary may have failed before writing).
                switch WorkingFiles.removeFile(
                    mp4Path,
                    inJobDirectory: jobDirectory,
                    under:           workingEncodePath,
                    forbidding:      plexMoviesPath
                ) {
                case .removed, .refused(.missing):
                    break
                case .refused, .failed:
                    log("⚠︎ Could not remove the partial encode at \(mp4Path)")
                }

                if selection.audio != selection.fallbackAudio {
                    log("⚠︎ The MakeMKV fallback does not carry over the audio tracks chosen for this disc; it keeps HandBrake's default audio (#0035).")
                }
                reportPhase(.fallback)
                switch await runFallback(
                    primaryFailure: primaryFailure,
                    discPath:       discPath,
                    workingRipPath: workingRipPath,
                    makemkvconPath: makemkvconPath,
                    handbrakePath:  handbrakePath,
                    mp4Path:        mp4Path,
                    volumeName:     volumeName,
                    jobID:          jobID,
                    fallbackAudio:  selection.fallbackAudio,
                    targetDurationSeconds: selection.featureDurationSeconds
                ) {
                case .failure(let runFailure):
                    fallbackRecord = runFailure.record
                    return await finish(.failed(runFailure.failure))
                case .success(let url):
                    // #0037: the fallback's second encode gets the same
                    // check, once. A short result here ends the job — it is
                    // never handed back to `FallbackPolicy` — with the
                    // original failure as the headline, the same shape as
                    // `runFallback`'s own failures.
                    if let durationFailure = await featureDurationFailure(url) {
                        log("✗ FALLBACK FAILED disc=\"\(volumeName)\" handbrake=\(String(describing: primaryFailure.reason)) fallback=\(durationFailure.stage.rawValue):\(String(describing: durationFailure.reason))")
                        fallbackRecord = DiscReliabilityLog.StageReason(
                            stage:  durationFailure.stage,
                            reason: String(describing: durationFailure.reason)
                        )
                        return await finish(.failed(JobFailure(
                            stage:    primaryFailure.stage,
                            reason:   primaryFailure.reason,
                            logTail:  primaryFailure.logTail,
                            fallback: .failed(stage: durationFailure.stage, reason: durationFailure.reason, logTail: [])
                        )))
                    }
                    mp4URL = url
                    producedBy = .makemkvFallback
                }
            }
        }
        log("✓ Encode complete: \(mp4URL.path)")

        // #0046 boundary 3: the encode (primary or fallback) already
        // returned — nothing is running — so a cancel requested in this gap
        // would otherwise go unnoticed until the next subprocess, which for
        // a feature with no extras is never. Still `.encoding` here
        // (`reportPhase(.organizing)` hasn't run yet), so `encoding →
        // cancelled` is legal. Never checked past this point: the move
        // itself must finish once started (#0012, #0041).
        if Task.isCancelled {
            return await finish(.failed(cancelledDuringEncode()))
        }

        // #0004 §3: mark the directory `encoded` before the move, so the
        // sweep can always tell a complete, unmoved `.mp4` from a stale
        // partial.
        await advanceMarker(.encoded)
        reportPhase(.organizing)

        // Step 2: Move into Plex
        let destination: URL
        do {
            destination = try await PlexOrganizer.move(
                encodedFile: mp4URL.path,
                metadata:    metadata,
                destination: .feature,
                roots:       libraryRoots,
                log:         log
            )
        } catch {
            log("✗ Moving into Plex failed. Aborting.")

            // #0004 §3/§5: the working `.mp4` is now the only copy (#0012).
            // Mark the directory `kept` and tell the user where the file is
            // and what to do with it — twice, if they don't act: the sweep
            // repeats the reminder at the start of every later job.
            await advanceMarker(.kept)
            if FileManager.default.fileExists(atPath: mp4Path) {
                log("⚠︎ The encoded file was kept at \(mp4Path). Move it into \"\(plexMoviesPath)/\(metadata.folderName)/\" by hand, or delete \(jobDirectory) to discard it.")
            } else {
                log("⚠︎ The encoded file is not in the working folder — see PlexOrganizer's log line above for where it was left.")
            }

            return await finish(.failed(error))
        }

        if producedBy == .makemkvFallback {
            log("✓ Produced by: MakeMKV fallback, then HandBrake")
        } else {
            log("✓ Produced by: HandBrake, direct from disc")
        }

        // Step 2.5: Extras (#0031 Step B). One by one, after the feature has
        // already moved — the feature is already safely in Plex by this
        // point, so a failed extra must never change the outcome being
        // returned, and never reaches `FallbackPolicy` (that only ever sees
        // the feature's primary failure). The disc stays mounted until every
        // extra is done; eject moves after this loop for exactly that
        // reason.
        //
        // #0035 (orchestrator decision from the #0031 handoff): when the
        // feature was produced by the MakeMKV fallback, HandBrake already
        // failed once against this disc, and extras would go straight back
        // to HandBrake against the same disc — probably failing the same
        // way, possibly slowly. Skip them entirely, log why, and leave the
        // feature outcome (already `.succeeded`) unchanged.
        if producedBy == .makemkvFallback {
            if !extras.items.isEmpty {
                log("⚠︎ Skipping \(extras.items.count) extra(s): the feature came from the MakeMKV fallback, and extras still go straight to HandBrake against the same disc HandBrake already failed on (#0035).")
            }
        } else if !extras.items.isEmpty {
            // The marker goes back to `.encoding`: the feature (the only
            // copy #0012 cares about) has already moved, and anything an
            // extra leaves behind on a mid-loop crash is re-derivable from
            // the disc. Leaving it at `.encoded` would make the sweep report
            // `encodedNeverMoved` forever for a directory that in fact holds
            // no unmoved feature at all.
            await advanceMarker(.encoding)
            // #0041 review: a HandBrake encode per extra is not "moving into
            // Plex" — report its own phase, only when extras actually run.
            reportPhase(.extras)

            var succeededExtras = 0
            extrasLoop: for (index, item) in extras.items.enumerated() {
                // #0046: a cancel requested between extras — nothing running
                // for `ProcessRunner`'s own cancellation handling to catch —
                // stops the remaining ones here. Per the #0046 handoff
                // (orchestrator decision): the feature is already filed in
                // Plex, so the job still ends `.succeeded` (`extras →
                // succeeded` is a legal edge, #0041; there is no `extras →
                // cancelled` edge) — it just stops encoding more of them.
                if Task.isCancelled {
                    let remaining = extras.items.count - index
                    log("⚠︎ Cancelled — skipping the remaining \(remaining) extra(s). The feature is already in Plex.")
                    break extrasLoop
                }

                let extraFilter = DeinterlaceDecision.decide(
                    frameRate:         item.frameRate,
                    interlaceDetected: item.interlaceDetected
                )
                let paddedIndex = String(format: "%02d", item.titleIndex)
                let extraOutput = (jobDirectory as NSString)
                    .appendingPathComponent("\(metadata.baseName) - t\(paddedIndex).mp4")

                log("▶ Extra: title \(item.titleIndex)")

                // #0031: extras use `.sourceDefault` audio — the disc's
                // default track, same encoder settings as the feature — and
                // there is no per-extra audio picker in this phase.
                switch await EncodeController.encode(
                    source:        discPath,
                    title:         .index(item.titleIndex),
                    output:        extraOutput,
                    handbrakePath: handbrakePath,
                    filter:        extraFilter,
                    audio:         .sourceDefault,
                    log:           log
                ) {
                case .failure(let extraFailure):
                    switch WorkingFiles.removeFile(
                        extraOutput,
                        inJobDirectory: jobDirectory,
                        under:           workingEncodePath,
                        forbidding:      plexMoviesPath
                    ) {
                    case .removed, .refused(.missing):
                        break
                    case .refused, .failed:
                        log("⚠︎ Could not remove the partial extra at \(extraOutput)")
                    }

                    // #0046: this extra's own `HandBrakeCLI` was killed by
                    // the same cancel — stop here rather than logging a
                    // generic failure and moving on to the next extra.
                    if extraFailure.reason == .cancelled {
                        let remainingAfterThis = extras.items.count - index - 1
                        log("⚠︎ Cancelled during extra title \(item.titleIndex) — skipping the remaining \(remainingAfterThis) extra(s). The feature is already in Plex.")
                        break extrasLoop
                    }

                    log("✗ Extra title \(item.titleIndex) failed to encode: \(String(describing: extraFailure.reason)) — skipping")

                case .success(let extraURL):
                    // #0037: the same check as the feature, log-only — a
                    // short extra is skipped exactly like a failed extra
                    // (#0031's rules), and never changes the job's outcome.
                    let verdict = await checkDuration(
                        extraURL,
                        expectedSeconds: item.durationSeconds,
                        label: "Extra title \(item.titleIndex)"
                    )
                    let durationOK: Bool
                    switch verdict {
                    case .consistent, .long:
                        durationOK = true
                    case .short, .none:
                        durationOK = false
                    }

                    guard durationOK else {
                        switch WorkingFiles.removeFile(
                            extraURL.path,
                            inJobDirectory: jobDirectory,
                            under:           workingEncodePath,
                            forbidding:      plexMoviesPath
                        ) {
                        case .removed, .refused(.missing):
                            break
                        case .refused, .failed:
                            log("⚠︎ Could not remove the partial extra at \(extraURL.path)")
                        }
                        continue
                    }

                    do {
                        _ = try await PlexOrganizer.move(
                            encodedFile: extraURL.path,
                            metadata:    metadata,
                            destination: .extra(titleIndex: item.titleIndex),
                            roots:       libraryRoots,
                            log:         log
                        )
                        succeededExtras += 1
                    } catch {
                        log("✗ Extra title \(item.titleIndex) failed to move into \(libraryRoots.clipsPath) — deleting")
                        // #0031 decision: an extra whose move failed is
                        // deleted, not kept — the disc remains the source,
                        // unlike the feature (#0012), so there is nothing to
                        // preserve here.
                        switch WorkingFiles.removeFile(
                            extraURL.path,
                            inJobDirectory: jobDirectory,
                            under:           workingEncodePath,
                            forbidding:      plexMoviesPath
                        ) {
                        case .removed, .refused(.missing):
                            break
                        case .refused, .failed:
                            log("⚠︎ Could not remove the partial extra at \(extraURL.path)")
                        }
                    }
                }
            }
            log("✓ Extras: \(succeededExtras) of \(extras.items.count) → \(libraryRoots.clipsPath)")
        }

        // Step 3: Eject (#0005). Only ever reached on a typed success — the
        // encode (and, on the fallback path, the rip) has already returned by
        // this point, so nothing still holds the disc open. A failed eject is
        // reported but never turns this successful job into a failed one:
        // the movie is already in Plex, so `outcome` stays `.succeeded`
        // regardless of what `DiscEjector` reports.
        switch await DiscEjector.eject(volumeURL: disc) {
        case .ejected:
            log("✓ Disc ejected — safe to insert the next one")
        case .busy(let message):
            log("⚠︎ \(message)")
        case .failed(let message):
            log("⚠︎ \(message)")
        }

        log("── Done. Scan your Plex Movies library to pick up the new title.")
        return await finish(.succeeded(destination: destination))
    }

    // MARK: - Fallback

    /// Runs the MakeMKV fallback: rip one title into a fresh per-job
    /// directory, then a second HandBrakeCLI pass over the ripped `.mkv`.
    /// The job directory is deleted as soon as the second encode returns
    /// (pass or fail), and also when the rip itself fails — it is gone
    /// before `PlexOrganizer.move` ever runs. A cleanup failure only logs a
    /// warning; it never fails the job.
    ///
    /// Returns either the produced `.mp4`, or a tuple of the *top-level*
    /// `JobFailure` (the original HandBrake failure, with `.fallback` set —
    /// never masked) and the reliability-log record for what the fallback
    /// itself did.
    private func runFallback(
        primaryFailure: JobFailure,
        discPath:       String,
        workingRipPath: String,
        makemkvconPath: String,
        handbrakePath:  String,
        mp4Path:        String,
        volumeName:     String,
        jobID:          JobID,
        fallbackAudio:  EncodeController.AudioSelection,
        targetDurationSeconds: Int?
    ) async -> Result<URL, FallbackRunFailure> {
        // #0004 §2: the rip job directory shares the run's single job id, so
        // `Working/encoding/<jobID>/` and `Working/ripping/<jobID>/` always
        // correlate.
        let jobDirectory = (workingRipPath as NSString)
            .appendingPathComponent(jobID.rawValue)

        // #0026/#0035: `selection.title`'s HandBrake index still never
        // reaches here — a HandBrake title index is not a makemkvcon index
        // (different base, numbered after makemkvcon's own filtering) — but
        // `selection.featureDurationSeconds` (HandBrake's own scan duration
        // for the chosen title) does, as `targetDurationSeconds` below.
        // `MakeMKVRipper.rip` matches its own `info` scan against that
        // duration (`matchTitle`) instead of always picking the longest
        // title, and refuses rather than guessing when there's no unique
        // match. `nil` (no title was ever explicitly chosen) keeps the
        // pre-#0035 "pick the longest" behaviour.
        //
        // `fallbackAudio` is `.sourceDefault` from `EncodeSelection.make`
        // (#0027 review): the `.mkv`'s track numbers don't match the disc's,
        // and `.languages` is unverified on real HandBrake. `run()` logs
        // that the chosen tracks are not carried over.
        switch await MakeMKVRipper.rip(
            discMountPath:  discPath,
            jobDirectory:   jobDirectory,
            makemkvconPath: makemkvconPath,
            targetDurationSeconds: targetDurationSeconds,
            log:            log
        ) {
        case .failure(let ripFailure):
            // `.destinationUnwritable` is the one rip failure that means this
            // job never created a fresh `jobDirectory` — either the working
            // root itself couldn't be created, or (the #0003-shaped
            // collision case) `jobDirectory` already existed and step (a)
            // refused to adopt it. Either way, this job did not create
            // whatever is at that path, so it must never delete it — leave
            // it for #0004's pre-job sweep — and logging "could not
            // clean up" here would be spurious, not a real cleanup failure.
            if case .destinationUnwritable = ripFailure.reason {
                // Nothing to clean up: never created, never touched.
            } else if !MakeMKVRipper.removeJobDirectory(jobDirectory, under: workingRipPath) {
                log("⚠︎ Could not clean up \(jobDirectory)")
            }
            // #0046: a cancelled rip must surface as `.cancelled` at the
            // *top* level, not masked behind `primaryFailure.reason` — that
            // top-level reason is what `JobState.finishing(with:)` reads to
            // pick the job's terminal phase, and a cancel here has to land
            // on `.cancelled`, not `.failed`. `.fallback` still carries the
            // real detail (stage `.rip`, reason `.cancelled`) for the log.
            if ripFailure.reason == .cancelled {
                log("⚠︎ Cancelled during the MakeMKV fallback rip.")
                let combined = JobFailure(
                    stage:    primaryFailure.stage,
                    reason:   .cancelled,
                    logTail:  primaryFailure.logTail,
                    fallback: .failed(stage: ripFailure.stage, reason: .cancelled, logTail: ripFailure.logTail)
                )
                let record = DiscReliabilityLog.StageReason(stage: ripFailure.stage, reason: String(describing: FailureReason.cancelled))
                return .failure(FallbackRunFailure(failure: combined, record: record))
            }
            log("✗ FALLBACK FAILED disc=\"\(volumeName)\" handbrake=\(String(describing: primaryFailure.reason)) fallback=\(ripFailure.stage.rawValue):\(String(describing: ripFailure.reason))")
            let combined = JobFailure(
                stage:    primaryFailure.stage,
                reason:   primaryFailure.reason,
                logTail:  primaryFailure.logTail,
                fallback: .failed(stage: ripFailure.stage, reason: ripFailure.reason, logTail: ripFailure.logTail)
            )
            let record = DiscReliabilityLog.StageReason(stage: ripFailure.stage, reason: String(describing: ripFailure.reason))
            return .failure(FallbackRunFailure(failure: combined, record: record))

        case .success(let mkvURL):
            // A MakeMKV `.mkv` contains exactly one title.
            //
            // #0016 Risks: the interlace decision for this second pass must
            // come from HandBrake's own scan of `mkvURL`, never from the
            // disc's MakeMKV metadata (MakeMKV reported Fargo at 29.97;
            // HandBrake correctly resolved 23.976). No such scan exists yet
            // (#0022/#0023), so this is `.none` — the same "no scan, no
            // filter" rule `run()` applies to the primary encode — rather
            // than reusing whatever `deinterlaceFilter` the primary attempt
            // computed, which would be exactly the wrong-source mistake this
            // note warns against.
            let fallbackFilter = DeinterlaceDecision.decide(frameRate: nil, interlaceDetected: nil)
            log("▶ Deinterlace (fallback re-encode): frameRate=unknown interlaceDetected=unknown → filter=\(fallbackFilter)")
            let secondResult = await EncodeController.encode(
                source:        mkvURL.path,
                title:         .index(1),
                output:        mp4Path,
                handbrakePath: handbrakePath,
                filter:        fallbackFilter,
                audio:         fallbackAudio,
                log:           log
            )

            // Cleanup happens before inspecting `secondResult`, whatever its
            // result (#0015 §6).
            if !MakeMKVRipper.removeJobDirectory(jobDirectory, under: workingRipPath) {
                log("⚠︎ Could not clean up \(jobDirectory)")
            }

            switch secondResult {
            case .failure(let encodeFailure):
                // #0046 — same reasoning as the rip-failure branch above: a
                // cancelled second (fallback) encode must surface as
                // `.cancelled` at the top level.
                if encodeFailure.reason == .cancelled {
                    log("⚠︎ Cancelled during the MakeMKV fallback's re-encode.")
                    let combined = JobFailure(
                        stage:    primaryFailure.stage,
                        reason:   .cancelled,
                        logTail:  primaryFailure.logTail,
                        fallback: .failed(stage: encodeFailure.stage, reason: .cancelled, logTail: encodeFailure.logTail)
                    )
                    let record = DiscReliabilityLog.StageReason(stage: encodeFailure.stage, reason: String(describing: FailureReason.cancelled))
                    return .failure(FallbackRunFailure(failure: combined, record: record))
                }
                log("✗ FALLBACK FAILED disc=\"\(volumeName)\" handbrake=\(String(describing: primaryFailure.reason)) fallback=\(encodeFailure.stage.rawValue):\(String(describing: encodeFailure.reason))")
                let combined = JobFailure(
                    stage:    primaryFailure.stage,
                    reason:   primaryFailure.reason,
                    logTail:  primaryFailure.logTail,
                    fallback: .failed(stage: encodeFailure.stage, reason: encodeFailure.reason, logTail: encodeFailure.logTail)
                )
                let record = DiscReliabilityLog.StageReason(stage: encodeFailure.stage, reason: String(describing: encodeFailure.reason))
                return .failure(FallbackRunFailure(failure: combined, record: record))
            case .success(let url):
                return .success(url)
            }
        }
    }
}
