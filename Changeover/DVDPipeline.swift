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
    let log: @MainActor (String) -> Void

    /// Where `DiscReliabilityLog.append` writes. Defaulted so existing call
    /// sites (`JobController.pipelineRunner`, `EncodeControllerTests`)
    /// compile unchanged; tests that care about the reliability log point
    /// this at a temp file instead of `DiscReliabilityLog.defaultURL`.
    var reliabilityLogURL: URL = DiscReliabilityLog.defaultURL

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
        let volumeName        = disc.lastPathComponent
        let logURL            = reliabilityLogURL

        // Phase 1 always asks HandBrake for the main feature (#0014 G1); a
        // single named `let` so the policy is visible and swappable. Phase
        // 2's scanner (#0023/#0025) replaces this with `.index(n)` at this
        // one call site — the whole migration.
        let titleSelection: EncodeController.TitleSelection = .mainFeature

        let mp4Path = (workingEncodePath as NSString)
            .appendingPathComponent(metadata.fileName)

        // Reliability-log bookkeeping, filled in as the run progresses so
        // every `return` below can pass through `finish(_:)` — no path
        // skips the record.
        var producedBy: ProducedBy?
        var primaryRecord: DiscReliabilityLog.StageReason?
        var decisionRecord: String?
        var fallbackRecord: DiscReliabilityLog.StageReason?

        func finish(_ outcome: JobOutcome) -> JobOutcome {
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

            let record = DiscReliabilityLog.Record(
                date:           ISO8601DateFormatter().string(from: Date()),
                volumeName:     volumeName,
                movie:          metadata.folderName,
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
            return finish(.failed(preflightFailure))
        }
        log("✓ Preflight passed")

        // Step 1: Encode, straight from the disc's VIDEO_TS — no rip stage
        // on the happy path.
        let mp4URL: URL
        switch await EncodeController.encode(
            source:        discPath,
            title:         titleSelection,
            output:        mp4Path,
            handbrakePath: handbrakePath,
            log:           log
        ) {
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
                return finish(.failed(primaryFailure))

            case .unavailable(let path):
                decisionRecord = "unavailable"
                log("✗ FALLBACK UNAVAILABLE disc=\"\(volumeName)\" handbrake=\(String(describing: primaryFailure.reason)) makemkvcon=\(path) (not installed)")
                return finish(.failed(JobFailure(
                    stage:    primaryFailure.stage,
                    reason:   primaryFailure.reason,
                    logTail:  primaryFailure.logTail,
                    fallback: .unavailable(makemkvconPath: path)
                )))

            case .attempt:
                decisionRecord = "attempted"
                log("⚠︎ FALLBACK disc=\"\(volumeName)\" handbrake=\(String(describing: primaryFailure.reason)) makemkvcon=\(makemkvconPath) → ripping with MakeMKV")

                switch await runFallback(
                    primaryFailure: primaryFailure,
                    discPath:       discPath,
                    workingRipPath: workingRipPath,
                    makemkvconPath: makemkvconPath,
                    handbrakePath:  handbrakePath,
                    mp4Path:        mp4Path,
                    volumeName:     volumeName
                ) {
                case .failure(let runFailure):
                    fallbackRecord = runFailure.record
                    return finish(.failed(runFailure.failure))
                case .success(let url):
                    mp4URL = url
                    producedBy = .makemkvFallback
                }
            }
        }
        log("✓ Encode complete: \(mp4URL.path)")

        // Step 2: Move into Plex
        let destination: URL
        do {
            destination = try PlexOrganizer.move(
                encodedFile:    mp4URL.path,
                metadata:       metadata,
                plexMoviesPath: plexMoviesPath,
                log:            log
            )
        } catch {
            log("✗ Moving into Plex failed. Aborting.")
            return finish(.failed(error))
        }

        if producedBy == .makemkvFallback {
            log("✓ Produced by: MakeMKV fallback, then HandBrake")
        } else {
            log("✓ Produced by: HandBrake, direct from disc")
        }

        log("── Done. Scan your Plex Movies library to pick up the new title.")
        return finish(.succeeded(destination: destination))
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
        volumeName:     String
    ) async -> Result<URL, FallbackRunFailure> {
        let jobDirectory = (workingRipPath as NSString)
            .appendingPathComponent(JobController.makeJobID())

        switch await MakeMKVRipper.rip(
            discMountPath:  discPath,
            jobDirectory:   jobDirectory,
            makemkvconPath: makemkvconPath,
            log:            log
        ) {
        case .failure(let ripFailure):
            // `.destinationUnwritable` is the one rip failure that means this
            // job never created a fresh `jobDirectory` — either the working
            // root itself couldn't be created, or (the #0003-shaped
            // collision case) `jobDirectory` already existed and step (a)
            // refused to adopt it. Either way, this job did not create
            // whatever is at that path, so it must never delete it — leave
            // it for #0004's launch-time sweep — and logging "could not
            // clean up" here would be spurious, not a real cleanup failure.
            if case .destinationUnwritable = ripFailure.reason {
                // Nothing to clean up: never created, never touched.
            } else if !MakeMKVRipper.removeJobDirectory(jobDirectory, under: workingRipPath) {
                log("⚠︎ Could not clean up \(jobDirectory)")
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
            let secondResult = await EncodeController.encode(
                source:        mkvURL.path,
                title:         .index(1),
                output:        mp4Path,
                handbrakePath: handbrakePath,
                log:           log
            )

            // Cleanup happens before inspecting `secondResult`, whatever its
            // result (#0015 §6).
            if !MakeMKVRipper.removeJobDirectory(jobDirectory, under: workingRipPath) {
                log("⚠︎ Could not clean up \(jobDirectory)")
            }

            switch secondResult {
            case .failure(let encodeFailure):
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
