import Foundation

/// Orchestrates the rip → encode → move pipeline on MainActor.
///
/// Declared as a plain struct so it inherits the module-wide @MainActor default
/// isolation. The log callback is a simple (String) -> Void called on MainActor;
/// RipController and EncodeController dispatch their own log calls back to
/// MainActor internally before invoking it.
struct DVDPipeline {
    let metadata: MovieMetadata
    let settings: AppSettings
    let log: @MainActor (String) -> Void

    // MARK: - Run

    func run() async {
        log("── Starting: \(metadata.folderName)")

        // Capture paths on MainActor before entering nonisolated functions
        let makemkvconPath   = settings.makemkvconPath
        let workingRipPath   = settings.workingRipPath
        let handbrakePath    = settings.handbrakePath
        let workingEncodePath = settings.workingEncodePath
        let plexMoviesPath   = settings.plexMoviesPath

        // Step 1: Rip
        guard let mkvPath = await RipController.rip(
            makemkvconPath: makemkvconPath,
            outputDir:      workingRipPath,
            log:            log
        ) else {
            log("✗ Ripping failed. Aborting.")
            return
        }
        log("✓ Rip complete: \(mkvPath)")

        // Step 2: Encode
        let mp4Path = (workingEncodePath as NSString)
            .appendingPathComponent(metadata.fileName)

        let encoded = await EncodeController.encode(
            input:         mkvPath,
            output:        mp4Path,
            handbrakePath: handbrakePath,
            log:           log
        )
        guard encoded else {
            log("✗ Encoding failed. Aborting.")
            return
        }
        log("✓ Encode complete: \(mp4Path)")

        // Step 3: Move into Plex
        PlexOrganizer.move(
            encodedFile:    mp4Path,
            metadata:       metadata,
            plexMoviesPath: plexMoviesPath,
            log:            log
        )

        log("── Done. Scan your Plex Movies library to pick up the new title.")
    }
}
