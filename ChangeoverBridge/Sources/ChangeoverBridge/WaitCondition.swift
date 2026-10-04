// WaitCondition.swift

import Foundation

/// #0196 — what `changeoverctl wait` blocks on.
///
/// **Why this exists at all.** An agent without it polls. A disc takes forty
/// minutes to encode, so `status` once a second is 2,400 round trips to learn one
/// fact, each of them a `@MainActor` hop into an app that is also driving a
/// `HandBrakeCLI` process and a progress bar. One blocking call with a timeout is
/// what a script actually wants, and the transport already pushes events — the
/// only thing missing was a predicate to stop on.
///
/// **Why the predicate is over `BridgeStatus` and not over event kinds.** The
/// obvious implementation watches for `disc.inserted` and exits. It is wrong for
/// the same reason `watch` alone is not enough to start from: an agent that
/// attaches with the disc already in the drive would wait forever for an event
/// that already happened. So the condition is evaluated against the *snapshot* —
/// which the session's opening event carries in full, and which every subsequent
/// event updates. A condition that is already true is met immediately, which is
/// the only honest answer.
///
/// Pure, so every condition is asserted in `ChangeoverTests` against a fixture
/// snapshot. UI tests are forbidden in this project, and the transport is
/// verified by hand, so this is the whole of the available coverage.
public enum WaitCondition: String, CaseIterable, Sendable, Equatable {
    /// Genuine optical media with a `VIDEO_TS` on it is mounted and actionable.
    case discInserted = "disc-inserted"
    /// The drive is empty.
    case discEjected = "disc-ejected"
    /// The HandBrake scan **settled**, scanned or failed.
    ///
    /// Settled, not succeeded. A scan that fails is an answer, and an agent that
    /// waited only for success would sit out its whole timeout on a disc whose
    /// title set is unreadable — a disc the user needs told about, not waited on.
    case scanComplete = "scan-complete"
    /// The app has settled on a film: a title, a year and a TMDB id.
    case identified = "identified"
    /// The job reached a terminal phase.
    case jobDone = "job-done"
    /// Nothing is in flight: no job, no scan, no eject.
    case idle = "idle"

    /// The accepted spellings, for the usage error.
    public static var names: [String] { allCases.map(\.rawValue) }

    /// A one-line description, for `help`.
    public var summary: String {
        switch self {
        case .discInserted: "A disc is in the drive and the app can act on it."
        case .discEjected: "The drive is empty."
        case .scanComplete: "The HandBrake scan settled — scanned or failed."
        case .identified: "The app has settled on a film."
        case .jobDone: "The job reached a terminal phase."
        case .idle: "No job, no scan and no eject in flight."
        }
    }

    /// Whether this condition holds for `status`.
    ///
    /// - Parameter boundJobID: `wait --job <id>`. Only `jobDone` reads it, and it
    ///   closes the one race this command has. `import` returns the job id it
    ///   started; without binding to it, `wait --for job-done` on a disc holding
    ///   two films can be satisfied by the *first* film's terminal job while the
    ///   second is still queued, and an agent would eject a disc with a film
    ///   still on it — which is #0163's reported bug, reached by a new road.
    public func isMet(status: BridgeStatus, boundJobID: String? = nil) -> Bool {
        switch self {
        case .discInserted:
            // Not merely `disc != nil`. A disc on its way out of the drive, or
            // one whose mount path died in a half-eject (#0049), is present and
            // not something to start work on — reporting it as "inserted" would
            // hand an agent a disc every other verb will refuse.
            guard let disc = status.disc else { return false }
            return !disc.isEjecting && !disc.unavailable

        case .discEjected:
            return status.disc == nil

        case .scanComplete:
            return ScanStatus.State.isTerminal(status.scan.state)

        case .identified:
            return status.film != nil

        case .jobDone:
            guard let job = status.job else { return false }
            guard !job.running, JobStatus.isTerminal(job.phase) else { return false }
            guard let boundJobID else { return true }
            return job.id == boundJobID

        case .idle:
            // A terminal job is not "in flight"; `job == nil` and a finished job
            // are both idle. The eject check is what stops an agent inserting
            // the next disc into a drive that has not opened yet.
            let jobBusy = status.job?.running ?? false
            let scanBusy = status.scan.state == ScanStatus.State.scanning
            let ejectBusy = status.disc?.isEjecting ?? false
            return !jobBusy && !scanBusy && !ejectBusy
        }
    }

    /// The sentence a met condition reports, drawn from the snapshot that met it.
    ///
    /// Said in terms of the evidence rather than in terms of the condition: "a
    /// disc is in the drive" is something a caller already knows it asked for,
    /// and `GARDEN_STATE at /Volumes/GARDEN_STATE` is the part worth printing.
    public func metDetail(status: BridgeStatus) -> String {
        switch self {
        case .discInserted:
            guard let disc = status.disc else { return "a disc is in the drive" }
            return "\(disc.label) at \(disc.mountPath)"
        case .discEjected:
            return "the drive is empty"
        case .scanComplete:
            if let failure = status.scan.failure { return "the scan failed — \(failure)" }
            let titles = status.scan.titleCount.map { "\($0) title(s)" } ?? "no title count"
            return "the scan finished with \(titles)"
        case .identified:
            guard let film = status.film else { return "a film is identified" }
            return "\(film.title) (\(film.year)) {tmdb-\(film.tmdbID)}"
        case .jobDone:
            guard let job = status.job else { return "the job finished" }
            let which = job.id.map { "\($0) " } ?? ""
            return "\(which)\(job.outcome ?? job.phase)"
                + (job.failureReason.map { " — \($0)" } ?? "")
        case .idle:
            return "nothing is in flight"
        }
    }

    /// The sentence a timeout reports: what it was still looking at.
    ///
    /// The *state*, not the condition. "timed out waiting for job-done" tells a
    /// caller nothing it did not already know; "the job is still encoding, 61%"
    /// tells it whether to wait longer or go and look.
    public func unmetDetail(status: BridgeStatus?) -> String {
        guard let status else { return "no snapshot was ever received" }
        switch self {
        case .discInserted, .discEjected:
            guard let disc = status.disc else { return "the drive is empty" }
            var detail = "\(disc.label) is in the drive"
            if disc.isEjecting { detail += ", being ejected" }
            if disc.unavailable { detail += ", unavailable" }
            return detail
        case .scanComplete:
            return "the scan is \(status.scan.state)"
        case .identified:
            return "no film is identified; the scan is \(status.scan.state)"
        case .jobDone:
            guard let job = status.job else { return "no job has run this launch" }
            let percent = job.percent.map { String(format: ", %.0f%%", $0) } ?? ""
            return "the job is \(job.phase)\(percent)"
        case .idle:
            var busy: [String] = []
            if status.job?.running ?? false { busy.append("a job is running") }
            if status.scan.state == ScanStatus.State.scanning { busy.append("a scan is running") }
            if status.disc?.isEjecting ?? false { busy.append("an eject is in flight") }
            return busy.isEmpty ? "nothing is in flight" : busy.joined(separator: " and ")
        }
    }
}
