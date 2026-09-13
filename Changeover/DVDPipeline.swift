import Foundation

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
/// #0014 removed the rip stage: HandBrakeCLI reads the disc
/// directly, so `makemkvcon`/`RipController` are no longer part of the happy
/// path and there is no intermediate `.mkv`.
struct DVDPipeline {
    let metadata: MovieMetadata
    let settings: AppSettings
    /// The mounted disc's volume root, e.g. `/Volumes/FARGO_SE__16X9` — what
    /// HandBrakeCLI is pointed at with `--input`. Supplied by `DVDMonitor`
    /// via `JobController.insertedDisc.mountURL`.
    let disc: URL
    let log: @MainActor (String) -> Void

    // MARK: - Run

    func run() async -> JobOutcome {
        log("── Starting: \(metadata.folderName)")

        // Capture paths on MainActor before entering nonisolated functions
        let discPath          = disc.path
        let handbrakePath     = settings.handbrakePath
        let workingEncodePath = settings.workingEncodePath
        let plexMoviesPath    = settings.plexMoviesPath

        // Step 1: Encode, straight from the disc's VIDEO_TS — no rip stage.
        // Phase 1 always asks HandBrake for the main feature (#0014 G1); a
        // single named `let` so the policy is visible and swappable. Phase
        // 2's scanner (#0023/#0025) replaces this with `.index(n)` at this
        // one call site — the whole migration.
        let titleSelection: EncodeController.TitleSelection = .mainFeature

        let mp4Path = (workingEncodePath as NSString)
            .appendingPathComponent(metadata.fileName)

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
        case .failure(let failure):
            log("✗ Encoding failed. Aborting.")
            return .failed(failure)
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
            return .failed(error)
        }

        log("── Done. Scan your Plex Movies library to pick up the new title.")
        return .succeeded(destination: destination)
    }
}
