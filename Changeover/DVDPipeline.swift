import Foundation

/// Orchestrates the rip → encode → move pipeline on MainActor.
///
/// Declared as a plain struct so it inherits the module-wide @MainActor default
/// isolation. The log callback is a simple (String) -> Void called on MainActor;
/// RipController and EncodeController dispatch their own log calls back to
/// MainActor internally before invoking it.
///
/// `run()` returns a `JobOutcome`. The log is the human channel, the outcome is
/// the machine channel — cleanup (#0004), eject (#0005) and the notification
/// (#0006) all read the outcome rather than inferring anything from the log.
struct DVDPipeline {
    let metadata: MovieMetadata
    let settings: AppSettings
    let log: @MainActor (String) -> Void

    // MARK: - Run

    func run() async -> JobOutcome {
        log("── Starting: \(metadata.folderName)")

        // Capture paths on MainActor before entering nonisolated functions
        let makemkvconPath   = settings.makemkvconPath
        let workingRipPath   = settings.workingRipPath
        let handbrakePath    = settings.handbrakePath
        let workingEncodePath = settings.workingEncodePath
        let plexMoviesPath   = settings.plexMoviesPath

        // Step 1: Rip
        let mkvURL: URL
        switch await RipController.rip(
            makemkvconPath: makemkvconPath,
            outputDir:      workingRipPath,
            log:            log
        ) {
        case .success(let url):
            mkvURL = url
        case .failure(let failure):
            log("✗ Ripping failed. Aborting.")
            return .failed(failure)
        }
        log("✓ Rip complete: \(mkvURL.path)")

        // Step 2: Encode
        let mp4Path = (workingEncodePath as NSString)
            .appendingPathComponent(metadata.fileName)

        let mp4URL: URL
        switch await EncodeController.encode(
            input:         mkvURL.path,
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

        // Step 3: Move into Plex
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
