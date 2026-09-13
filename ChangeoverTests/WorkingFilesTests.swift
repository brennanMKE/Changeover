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
}
