import Foundation

/// §7.4/§7.5 — the upgrade as a **job**: probe, stage, remux, verify, swap.
///
/// Shaped exactly like `DVDPipeline` so nothing new touches the state machine:
/// a MainActor `struct` (never an `actor` — it has no reason to leave the main
/// actor), path strings captured on MainActor and handed to `nonisolated`
/// workers as plain parameters, one `log` callback, `reportPhase`/
/// `reportProgress` closures bound to the job, and a `JobOutcome` at the end.
///
/// It takes its `UpgradePlan` **as a value**. Nothing here knows about a disc,
/// a scan, a menu read or a view — which is what will let a library sweep
/// drive the same job from a list of files, with no second code path.
///
/// The order of the five steps is the safety argument, and it is the same one
/// #0012 made for `PlexOrganizer.move`: the library file is the **last** thing
/// touched, and a failure anywhere above leaves it exactly as it was.
struct UpgradePipeline {
    let metadata: MovieMetadata
    let plan: UpgradePlan
    let jobID: JobID
    let log: @MainActor (String) -> Void
    var steps: UpgradeSteps
    var reportPhase: @MainActor (JobPhase) -> Void = { _ in }
    var reportProgress: @MainActor (JobProgress) -> Void = { _ in }

    func run() async -> JobOutcome {
        log("── Upgrading metadata: \(metadata.folderName)")
        log("▶ Job \(jobID)")
        log("▶ File: \(plan.filePath)")

        reportPhase(.encoding)
        reportProgress(.remux())

        // 1. What is actually in the file right now. Never the inventory the
        // Confirm step was showing: that was read before the user pressed the
        // button, and the plan is about to be applied to whatever is there.
        let original: LibraryFileInventory
        switch await steps.probe(plan.filePath) {
        case .failure(let failure):
            log("✗ Could not read \(plan.filePath).")
            return .failed(failure)
        case .success(let inventory):
            original = inventory
        }

        // 2. The point-of-harm check. `UpgradeProposal` already applied the
        // count-equality rule when the card was drawn; this applies it again
        // against the file as it is now, because between then and here the
        // file could have been replaced by a re-rip with a different chapter
        // count — and names written by number against somebody else's markers
        // is the one failure this feature must never have.
        if !plan.chapters.isEmpty {
            guard plan.chapters.count == original.chapters.count else {
                return refuse(
                    "the file has \(original.chapters.count) chapters and the plan carries \(plan.chapters.count) names"
                )
            }
            guard plan.chapters.map(\.number) == Array(1...original.chapters.count) else {
                return refuse("the plan's chapter numbers are not 1…\(original.chapters.count)")
            }
        }
        for tag in plan.audio where !original.audio.contains(where: { $0.track == tag.track }) {
            return refuse("audio track \(tag.track + 1) is not in the file")
        }

        if Task.isCancelled { return .failed(JobFailure(stage: .encode, reason: .cancelled)) }

        // 3. Stage on the destination's own volume.
        let staging: UpgradeStaging
        switch await steps.stage(plan.filePath) {
        case .failure(let failure):
            log("✗ Could not make a staging folder beside \(plan.filePath).")
            return .failed(failure)
        case .success(let value):
            staging = value
        }
        let stagingDirectory = staging.directory.path
        func cleanUp() { steps.cleanUp(stagingDirectory) }

        // 4. The ffmetadata file, carrying the file's **own** chapter timings
        // with the disc's names attached. No moment is moved, added or
        // removed.
        var metadataPath: String?
        if !plan.chapters.isEmpty {
            guard let text = FFMetadata.text(chapters: original.chapters, names: plan.chapters) else {
                cleanUp()
                return refuse("the chapter names and the file's own chapter timings do not line up")
            }
            guard await steps.write(text, staging.metadata.path) else {
                cleanUp()
                log("✗ Could not write \(staging.metadata.path).")
                return .failed(JobFailure(
                    stage: .encode,
                    reason: .destinationUnwritable(path: staging.metadata.path)
                ))
            }
            metadataPath = staging.metadata.path
            log("▶ Chapter names: \(plan.chapters.count), attached to the file's own timings")
        }
        if !plan.audio.isEmpty {
            log("▶ Audio tags: \(plan.audio.count) track(s)")
        }

        // 5. The remux itself. `-c copy`: no frame is decoded.
        log("▶ Remuxing (no re-encode) → \(staging.output.lastPathComponent)")
        switch await steps.remux(plan.filePath, metadataPath, plan.audio, staging.output.path) {
        case .failure(let failure):
            cleanUp()
            log("✗ The remux failed. The file in Plex is unchanged.")
            return .failed(failure)
        case .success:
            break
        }

        // 6. Verify before replacing — the step that makes "never a
        // re-encode" something the app checks rather than something the
        // command line promised.
        let upgraded: LibraryFileInventory
        switch await steps.probe(staging.output.path) {
        case .failure(let failure):
            cleanUp()
            log("✗ Could not read the rewritten file back. The file in Plex is unchanged.")
            return .failed(failure)
        case .success(let inventory):
            upgraded = inventory
        }

        switch RemuxVerification.verify(original: original, upgraded: upgraded, plan: plan) {
        case .refused(let reason):
            cleanUp()
            return refuse(reason)
        case .ok:
            log("✓ Verified: same duration, same streams, same chapter times, the new names present")
        }

        if Task.isCancelled {
            cleanUp()
            return .failed(JobFailure(stage: .encode, reason: .cancelled))
        }

        // 7. The swap. From here on there is no cancel — `CancelPolicy`
        // refuses during `.organizing` for exactly this reason.
        reportPhase(.organizing)
        switch await steps.replace(staging.output.path, plan.filePath) {
        case .failure(let failure):
            cleanUp()
            log("✗ The swap failed. The file in Plex is unchanged.")
            return .failed(failure)
        case .success:
            break
        }

        cleanUp()
        log("✓ Upgraded: \(plan.changeSummary). Video and audio untouched.")
        log("── Done. Plex will pick the new chapter names up on its next refresh.")
        return .succeeded(destination: URL(fileURLWithPath: plan.filePath))
    }

    /// A refused upgrade is a failure whose reason is the check that failed,
    /// said in full — never a bare exit code, and always with the sentence
    /// that matters most: the original is unchanged.
    private func refuse(_ reason: String) -> JobOutcome {
        log("✗ Not upgraded — \(reason). The file in Plex is unchanged.")
        return .failed(JobFailure(
            stage: .encode,
            reason: .unknown("Not upgraded — \(reason). The original is unchanged.")
        ))
    }
}
