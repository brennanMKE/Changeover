import Darwin
import Foundation

/// #0004 — the working-file safety guards. Every deletion under the working
/// roots goes through `removeJobDirectory` or `removeFile`, and every job
/// encodes into a fresh per-job directory made by `createJobDirectory`. The
/// guards are deliberately paranoid: a cleanup helper that deletes the wrong
/// thing is worse than one that deletes nothing, so every refusal is a
/// `RemovalResult.refused` the caller logs — never a throw, never a silent
/// pass, and never a failed job.
///
/// `nonisolated` throughout, structured like `EncodeController`/`PlexOrganizer`:
/// filesystem work belongs off the main actor. The entry points `DVDPipeline`
/// calls from MainActor (`createJobDirectory`, and later `sweep`/`dispose`/
/// `writeMarker`) are `@concurrent` for the same reason as `Preflight.check` —
/// with `NonisolatedNonsendingByDefault` a plain `nonisolated async` function
/// would otherwise run on its caller's actor.
nonisolated enum WorkingFiles {

    // MARK: - Job-id shape

    /// The exact shape `JobController.makeJobID()` produces:
    /// `job-<yyyyMMdd>-<HHmmss>-<4 hex>`. Pinned by a round-trip test against
    /// `makeJobID` itself (WorkingFilesTests T1).
    static let jobIDPattern = "^job-[0-9]{8}-[0-9]{6}-[0-9A-Fa-f]{4}$"

    /// 4 + 1 + 8 + 1 + 6 + 1 + 4 — the anchored pattern's exact length, so a
    /// trailing newline (ICU `$` also matches before one) can't sneak through.
    private static let jobIDLength = 24

    nonisolated static func isJobID(_ name: String) -> Bool {
        guard name.count == jobIDLength else { return false }
        return name.range(of: jobIDPattern, options: .regularExpression) != nil
    }

    // MARK: - Results

    /// Why a deletion was refused. Every case is a guard in `removeJobDirectory`'s
    /// check order; a refusal is expected, logged, and never a job failure.
    enum RefusalReason: Equatable, Sendable {
        case emptyPath
        case notAbsolute
        case dotDotComponent
        case missing
        case isSymlink
        case isRegularFile
        case notADirectory
        case notAJobID
        case notAnMP4
        case outsideRoot
        case rootIsForbidden
    }

    enum RemovalResult: Equatable, Sendable {
        case removed
        case refused(RefusalReason)
        case failed(String)

        var isRemoved: Bool {
            if case .removed = self { return true }
            return false
        }
    }

    // MARK: - Removal

    /// Removes `path` only if it is a job-id-shaped **real directory** that is
    /// a direct child of `root`, where `root` itself is safe to clean inside.
    /// Never follows a symlink, never touches `root`, never deletes anything
    /// under the Movies library, and never throws (#0004 §6).
    ///
    /// Check order matters and is tested one guard at a time (T7): shape of
    /// the raw path → `lstat` kind → canonical containment → root safety →
    /// job-id shape → `removeItem`.
    nonisolated static func removeJobDirectory(
        _ path: String,
        under root: String,
        forbidding moviesPath: String = ""
    ) -> RemovalResult {
        if let refusal = validatedJobDirectory(path, under: root, forbidding: moviesPath) {
            return .refused(refusal)
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - File removal

    /// Removes a regular `.mp4` file directly inside a job directory — the
    /// primary encode's partial output, removed before the MakeMKV fallback
    /// rips (#0004 §1). The job directory itself must pass every guard
    /// `removeJobDirectory` applies (checks 1–6, without deleting it), and
    /// the file must be a regular `.mp4` whose canonical parent is that
    /// directory.
    nonisolated static func removeFile(
        _ path: String,
        inJobDirectory jobDirectory: String,
        under root: String,
        forbidding moviesPath: String = ""
    ) -> RemovalResult {
        if let refusal = validatedJobDirectory(jobDirectory, under: root, forbidding: moviesPath) {
            return .refused(refusal)
        }

        guard let kind = kind(of: path) else { return .refused(.missing) }
        switch kind {
        case .file:
            break
        case .symlink:
            return .refused(.isSymlink)
        case .directory, .other:
            return .refused(.notADirectory)
        }

        guard (path as NSString).pathExtension.lowercased() == "mp4" else {
            return .refused(.notAnMP4)
        }

        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = canonicalPath(parent),
              let realJobDirectory = canonicalPath(jobDirectory),
              realParent == realJobDirectory else {
            return .refused(.outsideRoot)
        }

        do {
            try FileManager.default.removeItem(atPath: path)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Creation

    /// Creates `root` (with intermediates) and then `root/jobID` **without**
    /// intermediates, so an existing directory is never adopted — the same
    /// provenance mechanism as `MakeMKVRipper.rip` step (a) (#0004 §2). The
    /// second call throws if `root/jobID` already exists.
    ///
    /// `@concurrent` because `run()` (MainActor) calls it and both
    /// `createDirectory` calls can block on an SMB volume.
    @concurrent
    nonisolated static func createJobDirectory(root: String, jobID: String) async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let jobDirectory = (root as NSString).appendingPathComponent(jobID)
        try fm.createDirectory(atPath: jobDirectory, withIntermediateDirectories: false)
        return jobDirectory
    }

    // MARK: - Guards (shared by both removal entry points)

    /// Checks 1–6 of #0004 §6, in order, without deleting anything. Returns
    /// `nil` when every guard passes. Shared by `removeJobDirectory` (which
    /// then removes the directory) and `removeFile` (which validates the
    /// *containing* job directory first).
    private static func validatedJobDirectory(
        _ path: String,
        under root: String,
        forbidding moviesPath: String
    ) -> RefusalReason? {
        // 1. Non-empty and absolute.
        guard !path.isEmpty, !root.isEmpty else { return .emptyPath }
        guard path.hasPrefix("/"), root.hasPrefix("/") else { return .notAbsolute }

        // 2. No `.` or `..` component in the raw path. Reject it before any
        // normalisation; never "fix" it.
        let rawComponents = path.split(separator: "/").map(String.init)
        if rawComponents.contains(".") || rawComponents.contains("..") {
            return .dotDotComponent
        }

        // 3. `lstat` — a real directory. A symlink is refused, never
        // followed: a symlink named `job-…` pointing into `Movies` must
        // survive, and so must its target. A regular file is refused. A
        // missing path is `.missing` (e.g. a volume unmounted mid-job).
        guard let entryKind = kind(of: path) else { return .missing }
        switch entryKind {
        case .directory:
            break
        case .symlink:
            return .isSymlink
        case .file:
            return .isRegularFile
        case .other:
            return .notADirectory
        }

        // 4. Canonical containment: `realpath(3)` of the path's parent must
        // equal `realpath(root)` exactly — a direct child only. Darwin
        // `realpath`, not `NSString.resolvingSymlinksInPath`: that API strips
        // `/private` only when the result exists, and every test temp
        // directory lives under `/var → /private/var`.
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = canonicalPath(parent),
              let realRoot = canonicalPath(root) else {
            return .outsideRoot
        }
        guard realParent == realRoot else { return .outsideRoot }

        // 5. The root itself must be safe: never `/`, and never equal to,
        // inside, or containing the Movies library.
        guard realRoot != "/" else { return .rootIsForbidden }
        if !moviesPath.isEmpty, rootsOverlap(realRoot, moviesPath) {
            return .rootIsForbidden
        }

        // 6. The name must be job-id shaped — the exact shape
        // `JobController.makeJobID()` produces.
        let lastComponent = (path as NSString).lastPathComponent
        guard isJobID(lastComponent) else { return .notAJobID }

        return nil
    }

    /// True when `realRoot` equals, is inside, or contains the Movies path.
    /// When `moviesPath` doesn't exist (no `realpath`), compare standardised
    /// strings instead (#0004 §6 check 5).
    private static func rootsOverlap(_ realRoot: String, _ moviesPath: String) -> Bool {
        let realMovies = canonicalPath(moviesPath) ?? (moviesPath as NSString).standardizingPath
        return realMovies == realRoot
            || realRoot.hasPrefix(realMovies + "/")
            || realMovies.hasPrefix(realRoot + "/")
    }

    // MARK: - Filesystem primitives

    enum EntryKind: Equatable, Sendable {
        case directory
        case symlink
        case file
        case other
    }

    /// `lstat` — reports the entry itself, never a symlink's target.
    nonisolated static func kind(of path: String) -> EntryKind? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        case S_IFREG: return .file
        default:      return .other
        }
    }

    /// Darwin `realpath(3)`, not `NSString.resolvingSymlinksInPath` — see
    /// guard 4 above for why.
    nonisolated static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
