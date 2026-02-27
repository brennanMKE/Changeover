import Foundation

enum PlexOrganizer {
    /// Moves `encodedFile` into the correct Plex Movies folder structure
    /// based on `metadata.folderName` and `metadata.fileName`.
    ///
    /// Result path: `Movies/<Title (Year) {tmdb-ID}>/<Title (Year).mp4>`
    nonisolated static func move(
        encodedFile:    String,
        metadata:       MovieMetadata,
        plexMoviesPath: String,
        log:            (String) -> Void
    ) {
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
            log("✓ Moved to: \(destPath)")
        } catch {
            log("✗ ERROR moving file: \(error.localizedDescription)")
        }
    }
}
