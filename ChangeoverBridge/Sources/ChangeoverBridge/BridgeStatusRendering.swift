// BridgeStatusRendering.swift

import Foundation

// The human form of a snapshot.
//
// In the library rather than in the CLI for the same reason the help text is:
// it is a pure function from a value to strings, so it can be asserted in
// `ChangeoverTests` — and the human output is the half a person actually reads,
// so it is the half most likely to say something untrue without anyone noticing.

extension BridgeStatus {
    /// Aligned `key  value` lines, in a fixed order.
    ///
    /// Ordered by how a person reads it — what is in the drive, how far the app
    /// has got, what it thinks the film is, what the job is doing, whether Start
    /// works — rather than sorted. The `--json` form is sorted instead, because
    /// nothing reads that by eye and a stable key order makes two captured runs
    /// diffable.
    public var humanLines: [String] {
        var rows: [(String, String)] = []

        rows.append(("app", "pid \(app.pid), version \(app.version) (\(app.build))"))
        rows.append(("uptime", String(format: "%.0fs", app.uptimeSeconds)))
        if !app.isConfigured {
            rows.append(("configured", "no — Changeover has no Plex root or no TMDB key yet"))
        }
        rows.append(("clients", "\(app.clients) attached, \(app.sessions) watching"))

        if let disc {
            var detail = disc.label
            detail += disc.discID.map { " [\($0)]" } ?? " [identity unknown]"
            if !disc.isMounted { detail += " (never mounted)" }
            if disc.isEjecting { detail += " (ejecting)" }
            if disc.unavailable { detail += " (unavailable)" }
            if disc.hasMoreWork { detail += " (more to import)" }
            rows.append(("disc", detail))
            rows.append(("disc path", disc.mountPath))
            rows.append(("insertion", disc.insertionID))
        } else {
            rows.append(("disc", "none in the drive"))
        }

        rows.append((
            "phase",
            "\(flow.discPhaseNumber) of \(flow.discPhaseCount) — \(flow.discPhaseTitle)"
        ))
        rows.append(("screen", flow.stepDetail.map { "\(flow.step) (\($0))" } ?? flow.step))

        var scanDetail = scan.state
        if let count = scan.titleCount { scanDetail += ", \(count) title(s)" }
        if let main = scan.mainFeatureIndex { scanDetail += ", main feature \(main)" }
        if let seconds = scan.featureDurationSeconds {
            scanDetail += ", \(seconds / 60) min"
        }
        if let failure = scan.failure { scanDetail += " — \(failure)" }
        rows.append(("scan", scanDetail))
        if !scan.warnings.isEmpty {
            rows.append(("scan warnings", scan.warnings.joined(separator: "; ")))
        }
        rows.append(("menus", scan.menuState))

        if let film {
            rows.append(("film", "\(film.title) (\(film.year)) {tmdb-\(film.tmdbID)}"))
            rows.append(("film folder", film.folderName))
            rows.append(("film file", film.fileName))
            rows.append((
                "identified by",
                film.chosenByUser ? "the user" : (film.resolvedBy ?? "nothing recorded")
            ))
            rows.append(("in library", film.libraryStatus))
        } else {
            rows.append(("film", "not identified"))
        }

        if let job {
            var detail = job.running ? "running, \(job.phase)" : job.phase
            if let percent = job.percent {
                detail += String(format: ", %.0f%%", percent)
            } else if job.running {
                detail += ", no percentage for this step"
            }
            if let unit = job.unit { detail += " (\(unit))" }
            if let eta = job.etaSeconds { detail += ", eta \(eta)s" }
            rows.append(("job", detail))
            if let id = job.id { rows.append(("job id", id)) }
            if let reason = job.failureReason { rows.append(("job failure", reason)) }
            if let jobFilm = job.film, jobFilm.identity != film?.identity {
                rows.append(("job film", "\(jobFilm.title) (\(jobFilm.year))"))
            }
        } else {
            rows.append(("job", "none this launch"))
        }

        rows.append(("start", start.permitted ? "available — \(start.decision)" : "refused — \(start.decision)"))
        if let reason = start.reason {
            rows.append(("start reason", reason))
        }
        if let remaining = start.autoStartSecondsRemaining {
            rows.append(("auto start", "in \(remaining)s"))
        }

        // Printed even when nothing is suspended, because its absence is what a
        // confused user would be reading: a disc sitting idle with no line about
        // automation looks like a different bug from one that says why.
        rows.append((
            "automation",
            automation.suspended
                ? "suspended — \(automation.heldBySessions) watch session(s) attached"
                : "running normally"
        ))

        rows.append(("media root", library.mediaRoot.isEmpty ? "not set" : library.mediaRoot))
        rows.append(("movies", library.moviesPath))
        rows.append(("tv shows", library.tvShowsPath))
        rows.append(("clips", library.clipsPath))
        rows.append(("film naming", library.filmPattern))
        rows.append(("extras naming", library.extraPattern))
        rows.append(("extras folders", library.extrasFolders.joined(separator: ", ")))

        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { key, value in
            let padding = String(repeating: " ", count: width - key.count)
            return "  \(key)\(padding)  \(value)"
        }
    }
}

extension BridgeEvent {
    /// One line, as `watch` prints it without `--json`.
    ///
    /// The time is the app's, not the CLI's. A watcher restarted mid-disc would
    /// otherwise renumber everything from zero, and the question "when did the
    /// disc actually go in" has one correct answer.
    public var humanLine: String {
        let padded = kind.padding(toLength: 22, withPad: " ", startingAt: 0)
        return "\(at)  \(padded)  \(summary)"
    }
}
