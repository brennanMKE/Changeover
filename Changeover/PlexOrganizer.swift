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
        let destURL = URL(fileURLWithPath: destPath)
        let encodedURL = URL(fileURLWithPath: encodedFile)

        do {
            try fm.createDirectory(atPath: folderPath,
                                   withIntermediateDirectories: true)
        } catch {
            log("✗ ERROR moving file: \(error.localizedDescription)")
            throw JobFailure(stage: .organize,
                             reason: reason(for: error, destination: folderPath))
        }

        // `replaceItemAt` requires both items on the *same volume* — a
        // cross-volume call throws error 512 "couldn't be saved" even when
        // nothing exists at the destination yet (see #0012's review notes,
        // reproduced with a throwaway APFS disk image). `plexMoviesPath` and
        // the working-encode folder `encodedFile` lives in are not
        // guaranteed to be on the same volume — they're only co-located
        // today because both derive from `plexMediaRoot`.
        //
        // Fix: stage the encoded file on the *destination's* volume first,
        // via `itemReplacementDirectory`, which the API guarantees resolves
        // to a directory on the same volume as `destURL`. `moveItem` into
        // that staging directory is the only step that can cross a volume
        // boundary, and `FileManager.moveItem` already handles that safely —
        // same-volume it's a rename, cross-volume it's copy-then-delete, and
        // if the copy fails the source is left untouched. Once the encoded
        // file is staged, `replaceItemAt(destURL, withItemAt:)` is always a
        // same-volume call, so it stays atomic where the filesystem supports
        // it and never hits the cross-volume error.
        //
        // `replaceItemAt` never deletes an existing destination up front —
        // it performs the destructive swap only once staging has fully
        // succeeded, so a failure anywhere leaves a pre-existing library
        // file exactly as it was. When nothing exists at `destURL` yet, it
        // degrades to a plain move. If the swap itself fails *after*
        // staging succeeded, the staged file is moved back to its original
        // `encodedFile` location so it is never stranded in a hidden
        // replacement directory.
        let stagingDir: URL
        do {
            stagingDir = try fm.url(for: .itemReplacementDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: destURL,
                                     create: true)
        } catch {
            log("✗ ERROR moving file: \(error.localizedDescription)")
            throw JobFailure(stage: .organize,
                             reason: reason(for: error, destination: folderPath))
        }
        let stagedURL = stagingDir.appendingPathComponent(destURL.lastPathComponent)

        do {
            try fm.moveItem(at: encodedURL, to: stagedURL)
        } catch {
            try? fm.removeItem(at: stagingDir)
            log("✗ ERROR moving file: \(error.localizedDescription)")
            throw JobFailure(stage: .organize,
                             reason: reason(for: error, destination: folderPath))
        }

        do {
            _ = try fm.replaceItemAt(destURL, withItemAt: stagedURL)
        } catch {
            let replaceError = error
            do {
                // Undo the staging move so the encoded file ends up back
                // where the caller left it rather than in a hidden
                // itemReplacementDirectory nothing else will ever look at.
                try fm.moveItem(at: stagedURL, to: encodedURL)
                try? fm.removeItem(at: stagingDir)
            } catch {
                log("⚠️ Could not restore encoded file to \(encodedFile); it remains at \(stagedURL.path)")
            }
            log("✗ ERROR moving file: \(replaceError.localizedDescription)")
            throw JobFailure(stage: .organize,
                             reason: reason(for: replaceError, destination: folderPath))
        }

        try? fm.removeItem(at: stagingDir)

        log("✓ Moved to: \(destPath)")
        return destURL
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
