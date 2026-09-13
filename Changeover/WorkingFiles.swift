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

    // MARK: - Job marker

    /// The marker file's name inside an encode job directory (#0004 §3).
    /// Rip job directories carry no marker — a `.mkv` is never the only copy
    /// of anything.
    static let markerName = ".changeover-job"

    enum JobMarkerState: String, Codable, Sendable, CaseIterable {
        case encoding
        case encoded
        case kept
    }

    /// The small JSON document at `<jobDirectory>/.changeover-job`. The
    /// `movie` field makes the sweep's reminder line readable (#0004 §3).
    nonisolated struct JobMarker: Codable, Equatable, Sendable {
        let state: JobMarkerState
        let movie: String
    }

    enum MarkerRead: Equatable, Sendable {
        case marker(JobMarker)
        case unreadable
    }

    /// Pure: an unknown `state` string is `.unreadable`, never a default
    /// state (#0004 §3) — a marker the app can't vouch for must never
    /// authorize a deletion.
    nonisolated static func parseMarker(_ data: Data) -> MarkerRead {
        guard let marker = try? JSONDecoder().decode(JobMarker.self, from: data) else {
            return .unreadable
        }
        return .marker(marker)
    }

    nonisolated static func readMarker(inJobDirectory jobDirectory: String) -> MarkerRead {
        let path = (jobDirectory as NSString).appendingPathComponent(markerName)
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return .unreadable
        }
        return parseMarker(data)
    }

    /// Writes the marker atomically. Returns `false` on any failure — the
    /// caller decides which safe side to land on (#0004 §3): a failed
    /// `encoding` write leaves no marker (the sweep never auto-deletes a
    /// directory without one), and a failed `encoded`/`kept` write is
    /// followed by `deleteMarker` so a stale `encoding` marker can never sit
    /// in front of a complete `.mp4`.
    @concurrent
    nonisolated static func writeMarker(_ marker: JobMarker, inJobDirectory jobDirectory: String) async -> Bool {
        let path = (jobDirectory as NSString).appendingPathComponent(markerName)
        guard let data = try? JSONEncoder().encode(marker) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes the marker. `true` also when there was no marker to remove —
    /// the caller only needs to know whether a stale marker is gone. `false`
    /// means a removal error the caller must log with the job directory path.
    @concurrent
    nonisolated static func deleteMarker(inJobDirectory jobDirectory: String) async -> Bool {
        let path = (jobDirectory as NSString).appendingPathComponent(markerName)
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
                return true
            }
            return false
        }
    }

    // MARK: - Disposition

    /// What `finish(_:)` should do with the job directory, decided purely
    /// from the typed outcome (#0004 §1's table). Exhaustive over `JobStage`
    /// with **no `default`**, so a future stage is a compile error until
    /// someone decides.
    enum Disposition: Equatable, Sendable {
        case removeJobDirectory
        case keepJobDirectory
        case nothingCreated
    }

    nonisolated static func disposition(
        for outcome: JobOutcome,
        jobDirectoryCreated: Bool
    ) -> Disposition {
        guard jobDirectoryCreated else { return .nothingCreated }
        guard let failure = outcome.failure else {
            // .succeeded — the .mp4 has already been moved into the library.
            return .removeJobDirectory
        }
        switch failure.stage {
        case .preflight:
            // The job directory is created after preflight, so none exists.
            return .nothingCreated
        case .rip, .encode:
            // A partial or fallback-failed encode is unplayable and nothing
            // in the app can use it; the disc is still the source.
            return .removeJobDirectory
        case .organize:
            // The working .mp4 is the only copy (#0012) — never delete it.
            return .keepJobDirectory
        }
    }

    /// What `dispose` did. `keptAmbiguousContent` is the succeeded-job case
    /// where the directory still holds something besides the marker — kept
    /// and logged, never deleted (#0004 §1).
    enum DisposeOutcome: Equatable, Sendable {
        case nothingToDo
        case keptAmbiguousContent(names: [String])
        case removed
        case refused(RefusalReason)
        case failed(String)
    }

    /// Executes a disposition: the one place a job's own working directory
    /// is deleted at the end of a run. Never throws, never changes the
    /// outcome — the caller logs whatever comes back (#0004 §6).
    ///
    /// `jobDirectoryCreated` is the pipeline's own tracked flag, not a
    /// filesystem probe: a refused `createJobDirectory` can leave a
    /// pre-existing directory on disk that this job did **not** create and
    /// must never delete (#0004 §2).
    ///
    /// `remover` is the pipeline's test seam (`DVDPipeline.removeJobDirectory`),
    /// defaulted to the real guard chain so production needs no parameter.
    @concurrent
    nonisolated static func dispose(
        outcome: JobOutcome,
        jobDirectoryCreated: Bool,
        jobDirectory: String,
        under root: String,
        forbidding moviesPath: String,
        remover: @escaping @Sendable (String, String, String) -> RemovalResult = {
            WorkingFiles.removeJobDirectory($0, under: $1, forbidding: $2)
        }
    ) async -> DisposeOutcome {
        guard jobDirectoryCreated else { return .nothingToDo }
        switch disposition(for: outcome, jobDirectoryCreated: true) {
        case .nothingCreated, .keepJobDirectory:
            return .nothingToDo
        case .removeJobDirectory:
            break
        }

        // A succeeded job's directory must hold nothing except the marker —
        // the .mp4 has already been moved. Anything else is ambiguous: keep
        // it and let the caller log a warning (#0004 §1).
        if outcome.failure == nil {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: jobDirectory)) ?? []
            let unexpected = children.filter { $0 != markerName }.sorted()
            if !unexpected.isEmpty {
                return .keptAmbiguousContent(names: unexpected)
            }
        }

        switch remover(jobDirectory, root, moviesPath) {
        case .removed:
            return .removed
        case .refused(let reason):
            return .refused(reason)
        case .failed(let message):
            return .failed(message)
        }
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
