import Foundation

enum PlexOrganizer {
    /// Moves `encodedFile` into the correct library folder structure — the
    /// Plex `Movies` tree for `.feature`, or the non-Plex `Clips` tree for
    /// `.extra` (#0031). The destination `String` is computed once, by
    /// `LibraryPaths.resolve`, from a `LibraryDestination` + `LibraryRoots`
    /// the caller supplies — there is no way for a caller to hand this
    /// function a bare path, so there is no code path that can file an extra
    /// under `Movies/`.
    ///
    /// `.feature` result path: `Movies/<Title (Year) {tmdb-ID}>/<Title (Year).mp4>`
    /// `.extra` result path: `Clips/<Title (Year) {tmdb-ID}>/<Title (Year)> - tNN.<ext>`
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
    /// #0031 — true when an `.extra` folder at `folderPath` would really sit
    /// inside `Movies/` or `TV Shows/`, whatever the strings say.
    ///
    /// Two checks, both before anything is created:
    /// 1. `Clips` itself canonically equals, contains or sits inside either
    ///    library (the original guard — e.g. `Clips` → `Movies`).
    /// 2. The folder's *real* location — its deepest existing ancestor run
    ///    through `realpath(3)`, plus the components not created yet — is
    ///    equal to or inside either library. This catches a symlink at any
    ///    depth (`Clips/<Title (Year) {tmdb-ID}>` → `Movies/…`), which
    ///    check 1 alone missed. Darwin's `realpath` returns on-disk case, so
    ///    `Clips` → `movies` on a case-insensitive volume resolves to
    ///    `…/Movies` and is caught too.
    ///
    /// An entry that exists but does not resolve (a dangling symlink) is
    /// refused outright rather than letting `createDirectory` meet it.
    nonisolated static func extraFolderAliasesLibrary(_ folderPath: String, roots: LibraryRoots) -> Bool {
        if let realClips = WorkingFiles.canonicalPath(roots.clipsPath),
           WorkingFiles.rootsOverlap(realClips, roots.moviesPath)
               || WorkingFiles.rootsOverlap(realClips, roots.tvPath) {
            return true
        }

        var existing = folderPath
        var missing: [String] = []
        while true {
            if let real = WorkingFiles.canonicalPath(existing) {
                let realFolder = missing.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
                for library in [roots.moviesPath, roots.tvPath] {
                    let realLibrary = WorkingFiles.canonicalPath(library) ?? (library as NSString).standardizingPath
                    if realFolder == realLibrary || realFolder.hasPrefix(realLibrary + "/") {
                        return true
                    }
                }
                return false
            }
            if WorkingFiles.kind(of: existing) != nil {
                return true
            }
            let parent = (existing as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == existing {
                return false
            }
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
    }

    @discardableResult
    @concurrent
    nonisolated static func move(
        encodedFile: String,
        metadata:    MovieMetadata,
        destination: LibraryDestination,
        roots:       LibraryRoots,
        log:         @MainActor (String) -> Void,
        onBegin:     @Sendable () -> Void = {}
    ) async throws(JobFailure) -> URL {
        onBegin()

        let fm = FileManager.default

        let sourceExtension = (encodedFile as NSString).pathExtension
        let resolved = LibraryPaths.resolve(
            destination,
            metadata:        metadata,
            roots:           roots,
            sourceExtension: sourceExtension
        )
        let folderPath = resolved.folder
        let destPath = resolved.file
        let destURL = URL(fileURLWithPath: destPath)
        let encodedURL = URL(fileURLWithPath: encodedFile)

        // #0031: an extra must never land inside `Movies/` or `TV Shows/`,
        // even by way of a symlink pointing into either — checked before any
        // filesystem mutation (see `extraFolderAliasesLibrary`). `.feature`
        // never runs this: `roots.moviesPath` is its own destination root,
        // so "overlaps Movies" is trivially true and meaningless there.
        if case .extra = destination,
           extraFolderAliasesLibrary(folderPath, roots: roots) {
            await log("✗ ERROR moving file: the Clips folder overlaps the Plex library — refusing to move an extra there")
            throw JobFailure(stage: .organize,
                             reason: .destinationUnwritable(path: folderPath))
        }

        // #0062 — a replacement is never invisible in the log. `replaceItemAt`
        // below overwrites an existing library copy on purpose (#0012), which
        // is exactly what the Confirm step's duplicate check warns about
        // *before* a 40-minute encode; this is the same fact stated at the
        // point of harm, so a log read after the fact still shows it. Checked
        // here rather than in `DVDPipeline.run()` because this function is
        // already `@concurrent` and already about to stat this path — the
        // pipeline is MainActor, and a `fileExists` against a slow SMB mount
        // there would block the UI.
        if let warning = replaceWarning(destinationPath: destPath, exists: fm.fileExists(atPath: destPath)) {
            await log(warning)
        }

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

    /// §7.5 step 4 — swaps a staged, already-verified file over a library file
    /// that is already there, and nothing else.
    ///
    /// The other half of `move` for the upgrade path: the staged copy was
    /// written by `ffmpeg` **into an `itemReplacementDirectory` on the
    /// destination's own volume** (`UpgradeController.stage`), so this is
    /// always a same-volume `replaceItemAt` — the #0012 lesson, met again by
    /// hand on 2026-09-18 where `os.replace` across devices simply cannot
    /// work. `replaceItemAt` performs the destructive swap only once staging
    /// has fully succeeded, so a failure here leaves the library file exactly
    /// as it was, which is the whole safety argument for the upgrade.
    ///
    /// Deliberately **not** a variant of `move`: `move` resolves a
    /// destination from `MovieMetadata` and creates folders. An upgrade
    /// rewrites a file that already exists at a path the library probe
    /// already found, and must never create anything.
    @concurrent
    nonisolated static func replaceInPlace(
        stagedFile: String,
        destination: String,
        log: @MainActor (String) -> Void
    ) async -> Result<Void, JobFailure> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedFile) else {
            await log("✗ ERROR: the rewritten file is not where it was staged (\(stagedFile))")
            return .failure(JobFailure(stage: .organize, reason: .unknown("the rewritten file was not staged")))
        }
        guard fm.fileExists(atPath: destination) else {
            // An upgrade never creates a library file — if the original has
            // gone since the probe, the honest answer is to do nothing.
            await log("✗ ERROR: \(destination) is no longer there, so nothing was replaced")
            return .failure(JobFailure(stage: .organize, reason: .destinationUnwritable(path: destination)))
        }
        do {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: stagedFile))
        } catch {
            await log("✗ ERROR replacing \(destination): \(error.localizedDescription)")
            return .failure(JobFailure(stage: .organize, reason: reason(for: error, destination: destination)))
        }
        await log("✓ Replaced: \(destination)")
        return .success(())
    }

    /// #0062 — the warning logged when the move is about to replace a file
    /// that is already in the library. Pure, so the wording and the "only
    /// when something is actually there" rule are unit-tested without a
    /// filesystem. `⚠︎` (U+FE0E), so `LogClassifier` files it as `.warning`
    /// and the History window paints it orange.
    nonisolated static func replaceWarning(destinationPath: String, exists: Bool) -> String? {
        guard exists else { return nil }
        return "⚠︎ Replacing the existing copy at \(destinationPath)"
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
