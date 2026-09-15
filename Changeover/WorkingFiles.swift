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
        /// No marker file exists — distinct from one that exists but can't
        /// be trusted. The sweep never auto-deletes a `.missing` or
        /// `.unreadable` directory (#0004 §4).
        case missing
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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .missing
        }
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
    ///
    /// Internal, not `private`, since #0031: `PlexOrganizer` reuses this to
    /// refuse an `.extra` destination that canonically aliases into `Movies`
    /// or `TV Shows` (e.g. a `Clips` symlink), rather than reimplementing the
    /// same realpath-based comparison a second time.
    static func rootsOverlap(_ realRoot: String, _ moviesPath: String) -> Bool {
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

    // MARK: - Stale sweep (#0004 §4)

    /// How long an `encoding` job directory (or a rip job directory) can sit
    /// untouched before the sweep deletes it. The longest realistic job is
    /// about 3 h; 24 h is an eightfold margin. `encoded` and `kept`
    /// directories never expire.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    struct SweepInput: Sendable {
        let plexMediaRoot: String
        let workingEncodePath: String
        let workingRipPath: String
        let plexMoviesPath: String
        let staleAfter: TimeInterval
    }

    /// One direct child of a working root, fully described — everything
    /// `sweepDecision` needs, and nothing else.
    struct SweepEntry: Sendable {
        enum Root: Sendable {
            case encode
            case rip
        }

        let name: String
        let kind: EntryKind
        let marker: MarkerRead
        /// The newest `lstat` mtime of the directory, its marker and its
        /// direct children; `nil` if unreadable.
        let newestModification: Date?
        let hasContentBesidesMarker: Bool
    }

    enum KeptReason: Equatable, Sendable {
        /// A regular `.mp4` directly in the encode root — an older build's
        /// loose encode. Reported, never deleted.
        case legacyLooseFile
        /// A job-shaped directory with no readable marker. Ambiguous, so kept.
        case unrecognised
        /// The app died between encode success and the move finishing. The
        /// `.mp4` inside is complete — never deleted.
        case encodedNeverMoved
        /// The move into Plex failed; the `.mp4` inside is the only copy
        /// (#0012). Never deleted.
        case keptAfterFailedMove
    }

    enum SweepDecision: Equatable, Sendable {
        case delete
        case report(KeptReason)
        case leave
    }

    /// Pure and exhaustive: what to do with one sweep entry. The tables are
    /// #0004 §4's, one per root. `now` is injected so tests can backdate
    /// mtimes instead of sleeping.
    nonisolated static func sweepDecision(
        for entry: SweepEntry,
        in root: SweepEntry.Root,
        now: Date,
        staleAfter: TimeInterval
    ) -> SweepDecision {
        switch root {
        case .encode:
            return encodeSweepDecision(for: entry, now: now, staleAfter: staleAfter)
        case .rip:
            return ripSweepDecision(for: entry, now: now, staleAfter: staleAfter)
        }
    }

    private static func encodeSweepDecision(
        for entry: SweepEntry,
        now: Date,
        staleAfter: TimeInterval
    ) -> SweepDecision {
        let jobShaped = isJobID(entry.name)
        if !jobShaped {
            // Legacy loose files are reported, never deleted; anything else
            // that isn't ours (user files, `.DS_Store`, preflight probes)
            // is left entirely alone.
            if entry.kind == .file, (entry.name as NSString).pathExtension.lowercased() == "mp4" {
                return .report(.legacyLooseFile)
            }
            return .leave
        }
        guard entry.kind == .directory else {
            // A job-shaped symlink, file or other — never touched.
            return .leave
        }
        switch entry.marker {
        case .missing, .unreadable:
            // Ambiguous — keep and report.
            return .report(.unrecognised)
        case .marker(let marker):
            switch marker.state {
            case .encoding:
                guard let newest = entry.newestModification else { return .leave }
                let age = now.timeIntervalSince(newest)
                guard age >= 0 else { return .leave } // an mtime in the future
                return age >= staleAfter ? .delete : .leave
            case .encoded:
                // The app died between encode success and the move finishing.
                return .report(.encodedNeverMoved)
            case .kept:
                return entry.hasContentBesidesMarker
                    ? .report(.keptAfterFailedMove)
                    : .delete // the user already moved the .mp4 out
            }
        }
    }

    private static func ripSweepDecision(
        for entry: SweepEntry,
        now: Date,
        staleAfter: TimeInterval
    ) -> SweepDecision {
        guard isJobID(entry.name), entry.kind == .directory else {
            return .leave
        }
        guard let newest = entry.newestModification else { return .leave }
        let age = now.timeIntervalSince(newest)
        guard age >= 0 else { return .leave }
        return age >= staleAfter ? .delete : .leave
    }

    struct SweepReport: Equatable, Sendable {
        struct KeptEntry: Equatable, Sendable {
            let path: String
            let reason: KeptReason
            let movie: String?
        }

        struct FailedEntry: Equatable, Sendable {
            let path: String
            let message: String
        }

        var removed: [String] = []
        var kept: [KeptEntry] = []
        var failed: [FailedEntry] = []
        var refusal: String?

        var isEmpty: Bool {
            removed.isEmpty && kept.isEmpty && failed.isEmpty && refusal == nil
        }
    }

    /// Sweeps stale working folders: first thing in `DVDPipeline.run()`,
    /// before preflight, so reclaimed space counts toward P6's free-space
    /// blocker (#0004 §4). Never throws, never creates anything, never
    /// recurses, never follows a symlink, and never deletes anything the
    /// decision tables don't name — every deletion goes back through
    /// `removeJobDirectory`, which re-checks everything at delete time
    /// (the entry was examined earlier; that gap is a TOCTOU).
    ///
    /// `onBegin` is a test-only hook (the `PlexOrganizer.move` shape) so
    /// T13 can prove the sweep never runs on the main actor.
    @concurrent
    nonisolated static func sweep(
        _ input: SweepInput,
        now: Date = Date(),
        onBegin: @Sendable () -> Void = {}
    ) async -> SweepReport {
        onBegin()
        var report = SweepReport()

        // Whole-sweep guard: no root configured — the derived paths would
        // begin `/Working/…`. No log line, no-op.
        guard !input.plexMediaRoot.isEmpty else { return report }

        for (rootKind, rootPath) in [(SweepEntry.Root.encode, input.workingEncodePath),
                                     (SweepEntry.Root.rip, input.workingRipPath)] {
            // Whole-sweep guard: the root must resolve somewhere real.
            // `realpath` follows symlinks — deliberately, because a root
            // that resolves into the Movies library is refused outright,
            // symlink or not (T12).
            guard let realRoot = canonicalPath(rootPath), realRoot != "/" else {
                if kind(of: rootPath) != nil {
                    // An existing root that resolves to nothing safe.
                    report.refusal = "working root \(rootPath) is not a safe root"
                    return report
                }
                continue
            }
            if !input.plexMoviesPath.isEmpty,
               rootsOverlap(realRoot, input.plexMoviesPath) {
                report.refusal = "working root \(rootPath) overlaps the Movies library"
                return report
            }
            // Whole-sweep guard per root: must be an existing real directory
            // (`lstat`, never following symlinks). A symlinked root is
            // skipped — never cleaned through — and a missing root is never
            // created.
            guard let rootEntryKind = kind(of: rootPath), rootEntryKind == .directory else {
                continue
            }

            let children: [String]
            do {
                children = try FileManager.default.contentsOfDirectory(atPath: rootPath).sorted()
            } catch {
                report.failed.append(.init(path: rootPath, message: error.localizedDescription))
                continue
            }

            for child in children {
                let childPath = (rootPath as NSString).appendingPathComponent(child)
                let entry = sweepEntry(at: childPath, name: child, root: rootKind)
                let decision = sweepDecision(for: entry, in: rootKind, now: now, staleAfter: input.staleAfter)
                switch decision {
                case .leave:
                    continue
                case .report(let reason):
                    report.kept.append(.init(
                        path: childPath,
                        reason: reason,
                        movie: markerMovie(entry.marker)
                    ))
                case .delete:
                    switch removeJobDirectory(childPath, under: rootPath, forbidding: input.plexMoviesPath) {
                    case .removed:
                        report.removed.append(childPath)
                    case .refused(let reason):
                        report.failed.append(.init(path: childPath, message: "refused: \(reason)"))
                    case .failed(let message):
                        report.failed.append(.init(path: childPath, message: message))
                    }
                }
            }
        }

        return report
    }

    /// Builds a `SweepEntry` for one direct child. Direct children only —
    /// no recursion, no symlink-following (`lstat` reports the entry
    /// itself).
    private static func sweepEntry(at path: String, name: String, root: SweepEntry.Root) -> SweepEntry {
        let entryKind = kind(of: path) ?? .other
        let marker: MarkerRead
        switch (root, entryKind) {
        case (.encode, .directory):
            marker = readMarker(inJobDirectory: path)
        case (.rip, .directory):
            // Rip job directories carry no marker — a `.mkv` is never the
            // only copy of anything (#0004 §3).
            marker = .missing
        case (_, .directory):
            marker = .missing
        default:
            marker = .missing
        }

        var newest: Date?
        var hasContentBesidesMarker = false
        if entryKind == .directory {
            newest = modificationDate(of: path)
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for child in children {
                let childPath = (path as NSString).appendingPathComponent(child)
                if let childDate = modificationDate(of: childPath) {
                    if newest == nil || childDate > newest! { newest = childDate }
                }
                if child != markerName {
                    hasContentBesidesMarker = true
                }
            }
            if let markerDate = modificationDate(of: (path as NSString).appendingPathComponent(markerName)) {
                if newest == nil || markerDate > newest! { newest = markerDate }
            }
        } else {
            newest = modificationDate(of: path)
        }

        return SweepEntry(
            name: name,
            kind: entryKind,
            marker: marker,
            newestModification: newest,
            hasContentBesidesMarker: hasContentBesidesMarker
        )
    }

    private static func markerMovie(_ marker: MarkerRead) -> String? {
        if case .marker(let marker) = marker { return marker.movie }
        return nil
    }

    private static func modificationDate(of path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
