import Foundation

enum PlexOrganizer {
    /// Moves `encodedFile` into the correct Plex Movies folder structure
    /// based on `metadata.folderName` and `metadata.fileName`.
    ///
    /// Result path: `Movies/<Title (Year) {tmdb-ID}>/<Title (Year).mp4>`
    ///
    /// Returns the destination the file landed at. Throws a `JobFailure` rather
    /// than swallowing the error — the log stays, it just stops being the only
    /// channel.
    @discardableResult
    nonisolated static func move(
        encodedFile:    String,
        metadata:       MovieMetadata,
        plexMoviesPath: String,
        log:            (String) -> Void
    ) throws(JobFailure) -> URL {
        let fm = FileManager.default

        let folderPath = (plexMoviesPath as NSString)
            .appendingPathComponent(metadata.folderName)
        let destPath = (folderPath as NSString)
            .appendingPathComponent(metadata.fileName)

        do {
            try fm.createDirectory(atPath: folderPath,
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destPath) {
                try fm.removeItem(atPath: destPath)
            }
            try fm.moveItem(atPath: encodedFile, toPath: destPath)
        } catch {
            log("✗ ERROR moving file: \(error.localizedDescription)")
            throw JobFailure(stage: .organize,
                             reason: reason(for: error, destination: folderPath))
        }

        log("✓ Moved to: \(destPath)")
        return URL(fileURLWithPath: destPath)
    }

    /// Maps a Cocoa file error to a `FailureReason`. Deliberately minimal —
    /// turning a reason into human text belongs to #0009.
    nonisolated private static func reason(for error: Error, destination: String) -> FailureReason {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return .unknown(error.localizedDescription)
        }
        switch nsError.code {
        case NSFileWriteOutOfSpaceError:
            return .diskFull
        case NSFileWriteNoPermissionError,
             NSFileWriteVolumeReadOnlyError,
             NSFileWriteInvalidFileNameError,
             NSFileNoSuchFileError:
            return .destinationUnwritable(path: destination)
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
