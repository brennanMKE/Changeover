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
    ///
    /// #0012 follow-up: `async` + `@concurrent`. `DVDPipeline.run()` is
    /// MainActor, and the staging `moveItem` below (see the big comment
    /// further down) can be a real cross-volume copy of the whole encoded
    /// file — about 1 GB for a typical feature (#0018) — onto an SMB/NAS
    /// `plexMediaRoot`. `FileManager`'s copy/move calls are plain
    /// synchronous, blocking work with no `await` of their own to suspend
    /// on, unlike `EncodeController.encode`'s `Process`, which yields the
    /// actor for the length of the encode via a checked continuation. With
    /// `SWIFT_APPROACHABLE_CONCURRENCY` (`NonisolatedNonsendingByDefault`)
    /// enabled on this target, a plain `nonisolated async` function still
    /// runs on its *caller's* actor rather than hopping off it — so without
    /// `@concurrent` this whole body, staging copy included, would run on
    /// MainActor and freeze the menu bar, the popover and the log view for
    /// the length of the copy, exactly the bug this pass fixes. `@concurrent`
    /// forces this function onto the global concurrent executor regardless
    /// of the caller, matching `Preflight.check`'s identical fix (#0008
    /// review fix 2) and `CLAUDE.md`'s concurrency rules. Pinned by
    /// `JobOutcomeTests.moveNeverRunsOnTheMainActor` — falsify by removing
    /// `@concurrent` and rerunning it.
    ///
    /// `log` is `@MainActor`, and every call below `await`s it directly
    /// rather than the fire-and-forget `Task { @MainActor in … }` wrapper
    /// `EncodeController`/`MakeMKVRipper` use — those dispatch from
    /// synchronous `Process` callback contexts that can't `await`; `move` is
    /// already `async`, so awaiting `log` directly hops to MainActor same as
    /// CLAUDE.md asks, keeps every line's ordering deterministic, and means
    /// the existing tests only needed `async`/`await` added at their call
    /// sites, not rewritten.
    ///
    /// `onBegin` is a test-only hook, defaulted to a no-op so no production
    /// call site changes — the same defaulted-closure-hook shape as
    /// `EncodeController.encode`'s `readerDelay`. It runs synchronously as
    /// the very first statement in the body, before any `FileManager` call,
    /// so a test can record `Thread.isMainThread` there and prove
    /// `@concurrent` actually moved this work off the caller's actor.
    @discardableResult
    @concurrent
    nonisolated static func move(
        encodedFile:    String,
        metadata:       MovieMetadata,
        plexMoviesPath: String,
        log:            @MainActor (String) -> Void,
        onBegin:        @Sendable () -> Void = {}
    ) async throws(JobFailure) -> URL {
        onBegin()

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
            await log("✗ ERROR moving file: \(error.localizedDescription)")
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
            await log("✗ ERROR moving file: \(error.localizedDescription)")
            throw JobFailure(stage: .organize,
                             reason: reason(for: error, destination: folderPath))
        }
        let stagedURL = stagingDir.appendingPathComponent(destURL.lastPathComponent)

        do {
            try fm.moveItem(at: encodedURL, to: stagedURL)
        } catch {
            try? fm.removeItem(at: stagingDir)
            await log("✗ ERROR moving file: \(error.localizedDescription)")
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
                await log("⚠️ Could not restore encoded file to \(encodedFile); it remains at \(stagedURL.path)")
            }
            await log("✗ ERROR moving file: \(replaceError.localizedDescription)")
            throw JobFailure(stage: .organize,
                             reason: reason(for: replaceError, destination: folderPath))
        }

        try? fm.removeItem(at: stagingDir)

        await log("✓ Moved to: \(destPath)")
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
