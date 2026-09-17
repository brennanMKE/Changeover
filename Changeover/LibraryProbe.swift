import Foundation

/// #0062 — the one place that touches the Plex library's filesystem to answer
/// "is this film already there?".
///
/// Cost, deliberately: **one** `contentsOfDirectory` of `Movies/` (names
/// only), then one of each folder carrying the movie's `{tmdb-ID}` tag —
/// normally zero or one. Never a deep walk, never a hash, never a byte of
/// media read. `Preflight` already lists the same root at job start, so this
/// is not a new class of access.
///
/// `@concurrent` for the reason `PlexOrganizer.move` is: an SMB listing is
/// blocking work with no `await` of its own, and under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a plain `nonisolated async`
/// function would still run it on the caller's actor — freezing the Confirm
/// step for as long as the NAS takes to answer.
/// #0062 — the probe as an injectable seam, the `JobController.ScanRunner`
/// pattern: `RipFlowControllerTests` drives the whole flow with a fake, so a
/// test never lists a real directory.
typealias LibraryProbeRunner = @Sendable (_ moviesPath: String, _ tmdbID: String) async -> LibraryLookup

nonisolated enum LibraryProbe {

    /// The production runner. A plain, context-free `static let` (the reason
    /// `JobController.defaultScanRunner` is one) that also pins the default
    /// timeout, since a function value can't carry default arguments.
    static let defaultRunner: LibraryProbeRunner = { moviesPath, tmdbID in
        await lookup(moviesPath: moviesPath, tmdbID: tmdbID)
    }

    /// The probe's default patience. A dead SMB mount must never hold the
    /// Confirm step hostage: past this, the answer is `.unreachable`, Start
    /// is *not* blocked, and the notice says so with a "Check again" link.
    static let defaultTimeout: Duration = .seconds(5)

    /// - Parameter onBegin: called on whatever thread the listing actually
    ///   runs on, so a test can prove this never happens on the main actor —
    ///   the same seam `PlexOrganizer.move` uses for the same assertion.
    @concurrent
    static func lookup(
        moviesPath: String,
        tmdbID: String,
        timeout: Duration = LibraryProbe.defaultTimeout,
        onBegin: @escaping @Sendable () -> Void = {}
    ) async -> LibraryLookup {
        let seconds = max(1, Int(timeout.components.seconds))
        return await withCheckedContinuation { continuation in
            let box = FirstAnswer(continuation)
            Task.detached(priority: .utility) {
                onBegin()
                box.resume(listing(moviesPath: moviesPath, tmdbID: tmdbID))
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: timeout)
                box.resume(.unreachable(reason: "The Plex library did not answer in \(seconds) s."))
            }
        }
    }

    /// Part 1's optional "Size" fact for a finished job's filed copy. Fails
    /// soft to `nil`: a job whose destination volume has since gone away
    /// simply shows no size, never a spinner and never an error.
    @concurrent
    static func fileFacts(at path: String) async -> LibraryFile? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return LibraryFile(
            name: url.lastPathComponent,
            sizeBytes: values.fileSize.map(Int64.init),
            modified: values.contentModificationDate
        )
    }

    // MARK: - The listing itself (synchronous, blocking, off the main actor)

    /// A missing or unlistable `moviesPath` is `.unreachable`, **never**
    /// `.absent` — see `LibraryLookup`.
    static func listing(moviesPath: String, tmdbID: String) -> LibraryLookup {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: moviesPath, isDirectory: &isDirectory) else {
            return .unreachable(reason: "\(moviesPath) isn't available.")
        }
        guard isDirectory.boolValue else {
            return .unreachable(reason: "\(moviesPath) isn't a folder.")
        }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: moviesPath)
        } catch {
            return .unreachable(reason: "\(moviesPath) couldn't be read: \(error.localizedDescription)")
        }

        let matched = LibraryMatch.folders(in: names.sorted(), tmdbID: tmdbID)
        let folders: [(name: String, path: String, files: [LibraryFile])] = matched.map { name in
            let path = (moviesPath as NSString).appendingPathComponent(name)
            return (name: name, path: path, files: files(in: path))
        }
        return LibraryMatch.lookup(folders: folders)
    }

    private static func files(in folderPath: String) -> [LibraryFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folderPath) else { return [] }
        return names.compactMap { name in
            guard LibraryMatch.isVideoFile(name) else { return nil }
            let url = URL(fileURLWithPath: (folderPath as NSString).appendingPathComponent(name))
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LibraryFile(
                name: name,
                sizeBytes: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate
            )
        }
    }

    /// Whichever of the listing and the timeout finishes first wins, and the
    /// loser is dropped on the floor.
    ///
    /// Deliberately **not** a `TaskGroup`: a group waits for every child
    /// before its scope returns, and the whole point here is that a listing
    /// wedged in an uninterruptible syscall against a dead mount must not
    /// keep the caller waiting past the timeout.
    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LibraryLookup, Never>?

        init(_ continuation: CheckedContinuation<LibraryLookup, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: LibraryLookup) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
