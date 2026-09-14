import Darwin
import Foundation
import Testing
@testable import Changeover

/// Covers #0004's working-file safety guards: the job-id shape, the
/// `removeJobDirectory`/`removeFile` guard chain, and `createJobDirectory`'s
/// never-adopt rule. Every test uses its own temp directory under
/// `FileManager.default.temporaryDirectory` — never a real volume, never
/// `/Volumes`, never the user's `plexMediaRoot`.
struct WorkingFilesTests {

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkingFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A syntactically valid, job-id-shaped name (not produced by
    /// `makeJobID`, so tests don't depend on the clock).
    private static let jobName = "job-20260101-000000-abcd"

    private static func makeJobDir(named name: String = jobName, in root: URL) throws -> URL {
        let job = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
        return job
    }

    /// Plants a sentinel file inside `dir` and returns its path. A wrong
    /// deletion that reaches `dir` destroys the sentinel, so a surviving
    /// sentinel proves the deletion never got there.
    private static func plantSentinel(in dir: URL) throws -> URL {
        let sentinel = dir.appendingPathComponent("sentinel.txt")
        try Data("keep me".utf8).write(to: sentinel)
        return sentinel
    }

    /// Backdates `path`'s mtime (and, recursively, its children's) — the
    /// sweep's age input, without ever sleeping.
    private static func backdate(_ path: String, to date: Date) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            for child in try FileManager.default.contentsOfDirectory(atPath: path) {
                try backdate((path as NSString).appendingPathComponent(child), to: date)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private static func writeMarker(_ state: WorkingFiles.JobMarkerState, movie: String, in dir: URL) throws {
        let marker = WorkingFiles.JobMarker(state: state, movie: movie)
        try JSONEncoder().encode(marker).write(to: dir.appendingPathComponent(WorkingFiles.markerName))
    }

    // MARK: - T1. isJobID round-trips makeJobID

    @Test func isJobIDAcceptsMakeJobIDOutput() async {
        // 50 ids over varied dates — different years, months, days, times —
        // plus the uppercase/lowercase hex spread `UUID().uuidString.prefix(4)`
        // actually produces.
        var dates: [Date] = []
        for i in 0..<50 {
            dates.append(Date(timeIntervalSince1970: TimeInterval(i * 9_731_527)))
        }
        for date in dates {
            let id = await JobController.makeJobID(date: date)
            #expect(WorkingFiles.isJobID(id), "makeJobID output rejected: \(id)")
        }
    }

    // MARK: - T2. isJobID rejects near-misses

    @Test func isJobIDRejectsNearMisses() {
        let nearMisses = [
            "job-",
            "job-x",
            "Job-20260101-000000-abcd",          // wrong case on the prefix
            "xjob-20260101-000000-abcd",         // junk before the prefix
            "job-20260101-000000-abcde",         // 5 hex digits
            "job-20260101-000000-abcd.mp4",      // a file name, not a job id
            "job-20260101-000000-abcd/..",       // traversal
            "job-2026-0101-000000-abcd",         // wrong date shape
            "job-20260101-00000-abcd",           // 5-digit time
            "",
        ]
        for nearMiss in nearMisses {
            #expect(!WorkingFiles.isJobID(nearMiss), "accepted a near-miss: \(nearMiss)")
        }
    }

    // MARK: - T6. removeJobDirectory removes a job-shaped direct child

    @Test func removeJobDirectoryRemovesAJobShapedDirectChild() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try Self.makeJobDir(in: root)

        #expect(WorkingFiles.removeJobDirectory(job.path, under: root.path) == .removed)
        #expect(!FileManager.default.fileExists(atPath: job.path))
    }

    // MARK: - T7. One guard per refusal, each with a surviving sentinel

    @Test func removeJobDirectoryRefusesTheRootItself() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = try Self.plantSentinel(in: root)

        #expect(WorkingFiles.removeJobDirectory(root.path, under: root.path) == .refused(.outsideRoot))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func removeJobDirectoryRefusesAGrandchild() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try Self.makeJobDir(in: root)
        let nested = try Self.makeJobDir(named: Self.jobName, in: job)
        let sentinel = try Self.plantSentinel(in: nested)

        #expect(WorkingFiles.removeJobDirectory(nested.path, under: root.path) == .refused(.outsideRoot))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func removeJobDirectoryRefusesADotDotPath() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.makeJobDir(in: root)
        let realSibling = try Self.makeJobDir(named: "job-20260202-020202-beef", in: root)
        let sentinel = try Self.plantSentinel(in: realSibling)

        // The raw path traverses through `..` — refused before any
        // normalisation, never "fixed".
        let traversing = root.path + "/" + Self.jobName + "/../job-20260202-020202-beef"
        #expect(WorkingFiles.removeJobDirectory(traversing, under: root.path) == .refused(.dotDotComponent))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func removeJobDirectoryRefusesASymlinkNamedLikeAJob() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = try Self.makeJobDir(named: "precious", in: outside)
        let sentinel = try Self.plantSentinel(in: target)

        let symlink = root.appendingPathComponent(Self.jobName)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        #expect(WorkingFiles.removeJobDirectory(symlink.path, under: root.path) == .refused(.isSymlink))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func removeJobDirectoryRefusesARegularFile() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(Self.jobName)
        try Data("x".utf8).write(to: file)

        #expect(WorkingFiles.removeJobDirectory(file.path, under: root.path) == .refused(.isRegularFile))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func removeJobDirectoryRefusesARootInsideMovies() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        // The working root itself sits inside the Movies library — the whole
        // root is forbidden, whatever the entry looks like.
        let working = movies.appendingPathComponent("Working")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let job = try Self.makeJobDir(in: working)
        let sentinel = try Self.plantSentinel(in: job)

        #expect(
            WorkingFiles.removeJobDirectory(job.path, under: working.path, forbidding: movies.path)
                == .refused(.rootIsForbidden)
        )
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func removeJobDirectoryRefusesAnEmptyRoot() {
        #expect(WorkingFiles.removeJobDirectory("/tmp/\(Self.jobName)", under: "") == .refused(.emptyPath))
    }

    @Test func removeJobDirectoryRefusesAMissingPath() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent(Self.jobName)

        #expect(WorkingFiles.removeJobDirectory(gone.path, under: root.path) == .refused(.missing))
    }

    // MARK: - T8. A root reached through a symlink is still the root

    @Test func removeJobDirectoryAcceptsARootReachedThroughASymlink() throws {
        let realRoot = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: realRoot) }
        let job = try Self.makeJobDir(in: realRoot)

        let linkRoot = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: linkRoot) }
        let symlinkRoot = linkRoot.appendingPathComponent("working-link")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)

        // The root given via a symlink, and the job directory addressed
        // through it: `realpath` resolves both sides to the same directory,
        // so this is a genuine direct child and must be removed.
        #expect(
            WorkingFiles.removeJobDirectory(
                symlinkRoot.appendingPathComponent(Self.jobName).path,
                under: symlinkRoot.path
            ) == .removed
        )
        #expect(!FileManager.default.fileExists(atPath: job.path))
    }

    // MARK: - T9. createJobDirectory never adopts

    @Test func createJobDirectoryRefusesToAdoptAnExistingDirectory() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let preExisting = root.appendingPathComponent(Self.jobName)
        try FileManager.default.createDirectory(at: preExisting, withIntermediateDirectories: false)
        let sentinel = try Self.plantSentinel(in: preExisting)

        do {
            _ = try await WorkingFiles.createJobDirectory(root: root.path, jobID: Self.jobName)
            Issue.record("createJobDirectory adopted an existing directory")
        } catch {
            // Expected: the leaf `createDirectory(withIntermediateDirectories: false)`
            // throws because the directory already exists.
        }

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func createJobDirectoryCreatesAFreshDirectory() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobDirectory = try await WorkingFiles.createJobDirectory(root: root.path, jobID: Self.jobName)
        #expect(jobDirectory == root.appendingPathComponent(Self.jobName).path)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: jobDirectory, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    // MARK: - T3. disposition follows the outcome table

    /// Parameterised over #0004 §1's table. The `.organize → keep` row is
    /// the safety-critical one: the working `.mp4` is the only copy (#0012).
    @Test(arguments: [
        (JobOutcome.succeeded(destination: URL(fileURLWithPath: "/tmp/movies/Movie (Year)/Movie (Year).mp4")), true, WorkingFiles.Disposition.removeJobDirectory),
        (JobOutcome.failed(JobFailure(stage: .encode, reason: .toolExited(code: 1))), true, WorkingFiles.Disposition.removeJobDirectory),
        (JobOutcome.failed(JobFailure(stage: .encode, reason: .toolExited(code: 1), fallback: .failed(stage: .rip, reason: .activationExpired, logTail: []))), true, WorkingFiles.Disposition.removeJobDirectory),
        (JobOutcome.failed(JobFailure(stage: .rip, reason: .noTitlesProduced)), true, WorkingFiles.Disposition.removeJobDirectory),
        (JobOutcome.failed(JobFailure(stage: .organize, reason: .destinationUnwritable(path: "/tmp/movies"))), true, WorkingFiles.Disposition.keepJobDirectory),
        (JobOutcome.failed(JobFailure(stage: .preflight, reason: .toolMissing(path: "/x"))), true, WorkingFiles.Disposition.nothingCreated),
        (JobOutcome.succeeded(destination: URL(fileURLWithPath: "/tmp/movies/Movie (Year)/Movie (Year).mp4")), false, WorkingFiles.Disposition.nothingCreated),
        (JobOutcome.failed(JobFailure(stage: .encode, reason: .toolExited(code: 1))), false, WorkingFiles.Disposition.nothingCreated),
        (JobOutcome.failed(JobFailure(stage: .encode, reason: .destinationUnwritable(path: "/tmp/working/job-x"))), false, WorkingFiles.Disposition.nothingCreated),
        (JobOutcome.failed(JobFailure(stage: .organize, reason: .destinationUnwritable(path: "/tmp/movies"))), false, WorkingFiles.Disposition.nothingCreated),
        (JobOutcome.failed(JobFailure(stage: .preflight, reason: .toolMissing(path: "/x"))), false, WorkingFiles.Disposition.nothingCreated),
    ])
    func dispositionFollowsTheOutcomeTable(
        _ outcome: JobOutcome,
        _ jobDirectoryCreated: Bool,
        _ expected: WorkingFiles.Disposition
    ) {
        #expect(WorkingFiles.disposition(for: outcome, jobDirectoryCreated: jobDirectoryCreated) == expected)
    }

    // MARK: - T4. marker round-trip; garbage is unreadable

    @Test func markerRoundTripsEveryState() throws {
        for state in WorkingFiles.JobMarkerState.allCases {
            let marker = WorkingFiles.JobMarker(state: state, movie: "Blade Runner (1982) {tmdb-78}")
            let data = try JSONEncoder().encode(marker)
            guard case .marker(let parsed) = WorkingFiles.parseMarker(data) else {
                Issue.record("marker with state \(state) did not round-trip")
                continue
            }
            #expect(parsed == marker)
        }
    }

    @Test func markerGarbageIsUnreadableNeverADefaultState() throws {
        let garbage: [Data] = [
            Data(),
            Data("".utf8),
            Data("{".utf8),
            Data(#"{"state":"bogus","movie":"x"}"#.utf8),
            Data(#"{"state":"encoding"}"#.utf8), // missing the movie field
            Data("not json at all".utf8),
        ]
        for data in garbage {
            #expect(WorkingFiles.parseMarker(data) == .unreadable, "garbage parsed as a marker: \(String(decoding: data, as: UTF8.self))")
        }
    }

    @Test func readMarkerDistinguishesMissingFromUnreadable() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try Self.makeJobDir(in: root)

        // No marker file at all — the sweep's `.missing` state.
        #expect(WorkingFiles.readMarker(inJobDirectory: job.path) == .missing)

        let marker = WorkingFiles.JobMarker(state: .encoding, movie: "Blade Runner (1982) {tmdb-78}")
        let written = await WorkingFiles.writeMarker(marker, inJobDirectory: job.path)
        #expect(written)
        #expect(WorkingFiles.readMarker(inJobDirectory: job.path) == .marker(marker))

        // A marker file that exists but can't be trusted — `.unreadable`.
        try Data("{".utf8).write(to: job.appendingPathComponent(WorkingFiles.markerName))
        #expect(WorkingFiles.readMarker(inJobDirectory: job.path) == .unreadable)

        let deleted = await WorkingFiles.deleteMarker(inJobDirectory: job.path)
        #expect(deleted)
        #expect(WorkingFiles.readMarker(inJobDirectory: job.path) == .missing)
    }

    // MARK: - T5. sweepDecision — the §4 tables, both roots

    private static let sweepNow = Date(timeIntervalSince1970: 1_800_000_000)
    private static let sweepStaleAfter: TimeInterval = 24 * 60 * 60

    private static func encodeEntry(
        name: String,
        kind: WorkingFiles.EntryKind,
        marker: WorkingFiles.MarkerRead,
        newest: Date?,
        hasContentBesidesMarker: Bool = false
    ) -> WorkingFiles.SweepEntry {
        WorkingFiles.SweepEntry(
            name: name, kind: kind, marker: marker,
            newestModification: newest, hasContentBesidesMarker: hasContentBesidesMarker
        )
    }

    @Test(arguments: [
        // Encode root — legacy loose files are reported, never deleted.
        ("legacy loose .mp4", WorkingFiles.SweepDecision.report(WorkingFiles.KeptReason.legacyLooseFile),
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: "Old Movie (1999).mp4", kind: .file, marker: .missing, newest: Self.sweepNow)),
        ("not-job-shaped file", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: "notes.txt", kind: .file, marker: .missing, newest: Self.sweepNow)),
        ("not-job-shaped directory", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: "something-else", kind: .directory, marker: .missing, newest: Self.sweepNow)),
        ("job-shaped symlink", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .symlink, marker: .missing, newest: Self.sweepNow)),
        ("job-shaped regular file", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .file, marker: .missing, newest: Self.sweepNow)),
        ("job dir, marker missing", WorkingFiles.SweepDecision.report(WorkingFiles.KeptReason.unrecognised),
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .missing, newest: Self.sweepNow)),
        ("job dir, marker unreadable", WorkingFiles.SweepDecision.report(WorkingFiles.KeptReason.unrecognised),
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .unreadable, newest: Self.sweepNow)),
        ("encoding, age exactly staleAfter", WorkingFiles.SweepDecision.delete,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .marker(WorkingFiles.JobMarker(state: .encoding, movie: "m")),
                newest: Self.sweepNow.addingTimeInterval(-sweepStaleAfter))),
        ("encoding, age 23h59m", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .marker(WorkingFiles.JobMarker(state: .encoding, movie: "m")),
                newest: Self.sweepNow.addingTimeInterval(-sweepStaleAfter + 60))),
        ("encoding, unreadable mtime", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .marker(WorkingFiles.JobMarker(state: .encoding, movie: "m")),
                newest: nil)),
        ("encoding, mtime in the future", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .marker(WorkingFiles.JobMarker(state: .encoding, movie: "m")),
                newest: Self.sweepNow.addingTimeInterval(3600))),
        ("encoded never moved", WorkingFiles.SweepDecision.report(WorkingFiles.KeptReason.encodedNeverMoved),
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .marker(WorkingFiles.JobMarker(state: .encoded, movie: "m")),
                newest: Self.sweepNow.addingTimeInterval(-10 * sweepStaleAfter))),
        ("kept with content", WorkingFiles.SweepDecision.report(WorkingFiles.KeptReason.keptAfterFailedMove),
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .marker(WorkingFiles.JobMarker(state: .kept, movie: "m")),
                newest: Self.sweepNow.addingTimeInterval(-10 * sweepStaleAfter), hasContentBesidesMarker: true)),
        ("kept, only the marker", WorkingFiles.SweepDecision.delete,
            WorkingFiles.SweepEntry.Root.encode,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .marker(WorkingFiles.JobMarker(state: .kept, movie: "m")),
                newest: Self.sweepNow.addingTimeInterval(-10 * sweepStaleAfter), hasContentBesidesMarker: false)),
        // Rip root — job-shaped real directories expire; everything else stays.
        ("rip job dir, stale", WorkingFiles.SweepDecision.delete,
            WorkingFiles.SweepEntry.Root.rip,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .missing,
                newest: Self.sweepNow.addingTimeInterval(-sweepStaleAfter))),
        ("rip job dir, fresh", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.rip,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .missing, newest: Self.sweepNow)),
        ("rip, not job-shaped", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.rip,
            encodeEntry(name: "stale.mkv", kind: .file, marker: .missing, newest: Self.sweepNow)),
        ("rip, job-shaped symlink", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.rip,
            encodeEntry(name: Self.jobName, kind: .symlink, marker: .missing, newest: Self.sweepNow)),
        ("rip, future mtime", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.rip,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .missing,
                newest: Self.sweepNow.addingTimeInterval(3600))),
        ("rip, unreadable mtime", WorkingFiles.SweepDecision.leave,
            WorkingFiles.SweepEntry.Root.rip,
            encodeEntry(name: Self.jobName, kind: .directory, marker: .missing, newest: nil)),
    ])
    func sweepDecisionTable(
        _ label: String,
        _ expected: WorkingFiles.SweepDecision,
        _ root: WorkingFiles.SweepEntry.Root,
        _ entry: WorkingFiles.SweepEntry
    ) {
        #expect(
            WorkingFiles.sweepDecision(for: entry, in: root, now: Self.sweepNow, staleAfter: Self.sweepStaleAfter)
                == expected,
            "row: \(label)"
        )
    }

    // MARK: - T10. sweep deletes exactly what the table says

    @Test func sweepDeletesExactlyWhatTheTableSays() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let movies = root.appendingPathComponent("Movies")
        let working = root.appendingPathComponent("Working")
        let encodeRoot = working.appendingPathComponent("encoding")
        let ripRoot = working.appendingPathComponent("ripping")
        for dir in [movies, encodeRoot, ripRoot] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let staleDate = Date().addingTimeInterval(-25 * 60 * 60)

        // Stale `encoding` job dir → deleted.
        let staleEncoding = encodeRoot.appendingPathComponent("job-20240101-000000-aaaa")
        try FileManager.default.createDirectory(at: staleEncoding, withIntermediateDirectories: false)
        try Self.writeMarker(.encoding, movie: "Stale Movie (2001)", in: staleEncoding)
        try Self.backdate(staleEncoding.path, to: staleDate)

        // Fresh `encoding` job dir → survives.
        let freshEncoding = encodeRoot.appendingPathComponent("job-20240102-000000-bbbb")
        try FileManager.default.createDirectory(at: freshEncoding, withIntermediateDirectories: false)
        try Self.writeMarker(.encoding, movie: "Fresh Movie (2002)", in: freshEncoding)

        // `kept` with an .mp4 → survives, reported.
        let keptWithMP4 = encodeRoot.appendingPathComponent("job-20240103-000000-cccc")
        try FileManager.default.createDirectory(at: keptWithMP4, withIntermediateDirectories: false)
        try Data("movie".utf8).write(to: keptWithMP4.appendingPathComponent("Kept Movie (2003).mp4"))
        try Self.writeMarker(.kept, movie: "Kept Movie (2003) {tmdb-78}", in: keptWithMP4)

        // `kept` holding only the marker → deleted (the user moved the .mp4 out).
        let keptOnlyMarker = encodeRoot.appendingPathComponent("job-20240104-000000-dddd")
        try FileManager.default.createDirectory(at: keptOnlyMarker, withIntermediateDirectories: false)
        try Self.writeMarker(.kept, movie: "Moved Movie (2004)", in: keptOnlyMarker)

        // `encoded` (died between encode and move) → survives, reported.
        let encoded = encodeRoot.appendingPathComponent("job-20240105-000000-eeee")
        try FileManager.default.createDirectory(at: encoded, withIntermediateDirectories: false)
        try Data("movie".utf8).write(to: encoded.appendingPathComponent("Encoded Movie (2005).mp4"))
        try Self.writeMarker(.encoded, movie: "Encoded Movie (2005)", in: encoded)

        // Markerless job dir → survives, reported unrecognised.
        let markerless = encodeRoot.appendingPathComponent("job-20240106-000000-ffff")
        try FileManager.default.createDirectory(at: markerless, withIntermediateDirectories: false)

        // Legacy loose .mp4 → survives, reported.
        try Data("movie".utf8).write(to: encodeRoot.appendingPathComponent("Old Movie (1999).mp4"))

        // Not ours at all → survives, unreported.
        try Data("notes".utf8).write(to: encodeRoot.appendingPathComponent("notes.txt"))

        // Job-shaped symlink to an outside sentinel dir → survives; the
        // target is untouched.
        let outside = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = try Self.plantSentinel(in: target)
        try FileManager.default.createSymbolicLink(
            at: encodeRoot.appendingPathComponent("job-20240110-000000-beef"),
            withDestinationURL: target
        )

        // Rip root: stale job dir → deleted; fresh → survives.
        let staleRip = ripRoot.appendingPathComponent("job-20240107-000000-d00d")
        try FileManager.default.createDirectory(at: staleRip, withIntermediateDirectories: false)
        try Data("mkv".utf8).write(to: staleRip.appendingPathComponent("ripped.mkv"))
        try Self.backdate(staleRip.path, to: staleDate)
        let freshRip = ripRoot.appendingPathComponent("job-20240108-000000-c0de")
        try FileManager.default.createDirectory(at: freshRip, withIntermediateDirectories: false)

        // A job-shaped directory inside Movies is never visited.
        let inMovies = movies.appendingPathComponent("job-20240109-000000-f00d")
        try FileManager.default.createDirectory(at: inMovies, withIntermediateDirectories: false)

        let report = await WorkingFiles.sweep(WorkingFiles.SweepInput(
            plexMediaRoot:     root.path,
            workingEncodePath: encodeRoot.path,
            workingRipPath:    ripRoot.path,
            plexMoviesPath:    movies.path,
            staleAfter:        WorkingFiles.staleAfter
        ))

        let removed = report.removed.map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(removed == ["job-20240101-000000-aaaa", "job-20240104-000000-dddd", "job-20240107-000000-d00d"])

        // Exact survivor set under the encode root.
        let encodeSurvivors = try FileManager.default.contentsOfDirectory(atPath: encodeRoot.path).sorted()
        #expect(encodeSurvivors == [
            "Old Movie (1999).mp4",
            "job-20240102-000000-bbbb",
            "job-20240103-000000-cccc",
            "job-20240105-000000-eeee",
            "job-20240106-000000-ffff",
            "job-20240110-000000-beef",
            "notes.txt",
        ])
        // Rip root: only the fresh job dir survives.
        #expect(try FileManager.default.contentsOfDirectory(atPath: ripRoot.path) == ["job-20240108-000000-c0de"])

        // The report names every kept entry with its reason and movie.
        #expect(report.kept.count == 4)
        #expect(report.kept.contains {
            $0.reason == .keptAfterFailedMove && $0.movie == "Kept Movie (2003) {tmdb-78}"
        })
        #expect(report.kept.contains {
            $0.reason == .encodedNeverMoved && $0.movie == "Encoded Movie (2005)"
        })
        #expect(report.kept.contains { $0.reason == .unrecognised })
        #expect(report.kept.contains { $0.reason == .legacyLooseFile })
        #expect(report.failed.isEmpty)
        #expect(report.refusal == nil)

        // The symlink's target was never touched.
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        // The Movies library was never visited.
        #expect(FileManager.default.fileExists(atPath: inMovies.path))
    }

    // MARK: - T11. sweep creates nothing

    @Test func sweepCreatesNothingWhenRootsAreMissingOrUnset() async throws {
        // A nonexistent plexMediaRoot: nothing is created, nothing reported.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkingFilesTests-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: missing) }

        let report = await WorkingFiles.sweep(WorkingFiles.SweepInput(
            plexMediaRoot:     missing.path,
            workingEncodePath: missing.appendingPathComponent("Working/encoding").path,
            workingRipPath:    missing.appendingPathComponent("Working/ripping").path,
            plexMoviesPath:    missing.appendingPathComponent("Movies").path,
            staleAfter:        WorkingFiles.staleAfter
        ))
        #expect(report.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.appendingPathComponent("Working").path))

        // An empty plexMediaRoot: a silent no-op.
        let empty = await WorkingFiles.sweep(WorkingFiles.SweepInput(
            plexMediaRoot:     "",
            workingEncodePath: "/tmp/Working/encoding",
            workingRipPath:    "/tmp/Working/ripping",
            plexMoviesPath:    "/tmp/Movies",
            staleAfter:        WorkingFiles.staleAfter
        ))
        #expect(empty.isEmpty)
    }

    // MARK: - T12. the sweep refuses when a working root resolves into Movies

    @Test func sweepRefusesWhenTheEncodeRootResolvesIntoMovies() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let working = root.appendingPathComponent("Working")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)

        // `Working/encoding` is a symlink to the Movies library itself.
        try FileManager.default.createSymbolicLink(
            at: working.appendingPathComponent("encoding"),
            withDestinationURL: movies
        )

        // A stale-shaped job directory under Movies must survive.
        let inMovies = movies.appendingPathComponent("job-20240101-000000-aaaa")
        try FileManager.default.createDirectory(at: inMovies, withIntermediateDirectories: false)
        try Self.writeMarker(.encoding, movie: "m", in: inMovies)
        try Self.backdate(inMovies.path, to: Date().addingTimeInterval(-25 * 60 * 60))

        let report = await WorkingFiles.sweep(WorkingFiles.SweepInput(
            plexMediaRoot:     root.path,
            workingEncodePath: working.appendingPathComponent("encoding").path,
            workingRipPath:    working.appendingPathComponent("ripping").path,
            plexMoviesPath:    movies.path,
            staleAfter:        WorkingFiles.staleAfter
        ))

        #expect(report.refusal != nil)
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: inMovies.path))
    }

    // MARK: - T13. the sweep never runs on the main actor

    private final class SweepThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func record() {
            lock.lock()
            defer { lock.unlock() }
            values.append(Thread.isMainThread)
        }
        var recorded: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// Same shape as `JobOutcomeTests.moveNeverRunsOnTheMainActor`: the
    /// caller is MainActor (this test), and `onBegin` must observe a
    /// non-main thread — without `@concurrent` on `sweep`, it would not.
    @MainActor
    @Test func sweepNeverRunsOnTheMainActor() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let encodeRoot = root.appendingPathComponent("Working/encoding")
        try FileManager.default.createDirectory(at: encodeRoot, withIntermediateDirectories: true)
        let job = encodeRoot.appendingPathComponent(Self.jobName)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
        try Self.writeMarker(.encoding, movie: "m", in: job)

        let recorder = SweepThreadRecorder()
        _ = await WorkingFiles.sweep(
            WorkingFiles.SweepInput(
                plexMediaRoot:     root.path,
                workingEncodePath: encodeRoot.path,
                workingRipPath:    root.appendingPathComponent("Working/ripping").path,
                plexMoviesPath:    root.appendingPathComponent("Movies").path,
                staleAfter:        WorkingFiles.staleAfter
            ),
            onBegin: { recorder.record() }
        )

        #expect(!recorder.recorded.isEmpty)
        #expect(recorder.recorded.allSatisfy { $0 == false })
    }
}
