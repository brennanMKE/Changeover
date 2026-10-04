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
            let decider: String
            switch film.chosenBy {
            case FilmStatus.Chooser.user:  decider = "the user"
            case FilmStatus.Chooser.agent: decider = "an agent"
            default: decider = film.resolvedBy ?? "nothing recorded"
            }
            rows.append(("identified by", decider))
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
            // #0205 — who stopped it, for the person reading `status` over SSH.
            if let who = job.cancelledBy {
                rows.append(("cancelled by", JobStatus.cancelledByPhrase(who)))
            }
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

// MARK: - #0196, the acting verbs

extension ActionResult {
    /// The human form of an acting verb's result.
    ///
    /// The outcome identifier is printed beside the sentence rather than instead
    /// of it. A person reading a terminal wants the sentence; a person
    /// *debugging a script* wants to see the identifier their `case` statement is
    /// about to be handed, and having to re-run with `--json` to find out is the
    /// friction this avoids.
    public var humanLines: [String] {
        var lines = [done ? "\(verb): \(detail)" : "\(verb) did not happen: \(detail)"]
        lines.append("  outcome  \(outcome)")
        if let jobID { lines.append("  job      \(jobID)") }
        if let intent { lines.append("  intent   \(intent)") }
        if let startDecision { lines.append("  start    \(startDecision)") }
        if let film { lines.append("  film     \(film.title) (\(film.year)) {tmdb-\(film.tmdbID)}") }
        if let featureTitle {
            // #0202 — on an extras-only job this index is nominal: the pipeline
            // resolves a feature either way, but `JobIntent.featureDestination`
            // is `nil`, so nothing encodes it and nothing files it. Labelled,
            // because "feature  title 4" reads as the one thing that is not
            // happening.
            lines.append(
                intent == JobIntentNames.extrasOnly
                    ? "  feature  title \(featureTitle) — nominal, not encoded"
                    : "  feature  title \(featureTitle)")
        }
        for extra in extras ?? [] {
            let name = extra.label ?? "unnamed"
            lines.append("  extra    title \(extra.titleIndex) → \(extra.folderName)/\(name)")
        }
        if let disc { lines.append("  disc     \(disc.label) [\(disc.insertionID)]") }
        return lines
    }
}

extension WaitResult {
    public var humanLines: [String] {
        var lines: [String] = []
        if met {
            lines.append(String(format: "%@ after %.1fs — %@", condition, waitedSeconds, detail))
        } else {
            lines.append(
                String(
                    format: "%@ did not happen within %.0fs — %@",
                    condition, timeoutSeconds, detail
                )
            )
        }
        if let boundJobID { lines.append("  job      \(boundJobID)") }
        lines.append("  events   \(eventCount)")
        return lines
    }
}

extension JobReport {
    /// The human form of a report.
    ///
    /// Films first, because that is the question — what happened to the things I
    /// asked for — and because the skipped ones are the answer people get wrong.
    public var humanLines: [String] {
        var lines: [String] = []

        if let disc {
            lines.append("disc  \(disc.label) [\(disc.insertionID)]")
        }

        lines.append(films.isEmpty ? "films  nothing planned for this disc" : "films")
        for film in films {
            var line = "  title \(film.feature)  \(film.state.padding(toLength: 8, withPad: " ", startingAt: 0))"
                + "  \(film.title) (\(film.year)) {tmdb-\(film.tmdbID)}"
            if let reason = film.reason { line += " — \(reason)" }
            lines.append(line)
        }

        lines.append(jobs.isEmpty ? "jobs  none this launch" : "jobs")
        for job in jobs {
            var line = "  \(job.id)  \(job.outcome ?? job.phase)  \(job.title) (\(job.year))"
            if job.intent != "film" { line += " [\(job.intent)]" }
            if !job.requestedExtras.isEmpty {
                line += " + \(job.requestedExtras.count) extra(s)"
            }
            lines.append(line)
            if let reason = job.failureReason {
                lines.append("    failed at \(job.failureStage ?? "an unknown stage"): \(reason)")
            }
            if job.discUnreadable {
                lines.append("    the disc could not be read — this is common and is not an app fault")
            }
        }

        if !reliability.isEmpty {
            lines.append("reliability log (most recent last)")
            for record in reliability {
                var line = "  \(record.date)  \(record.outcome)  \(record.movie)"
                if let produced = record.producedBy { line += "  via \(produced)" }
                if let reason = record.failureReason {
                    line += "  — \(record.failureStage ?? "?")/\(reason)"
                }
                lines.append(line)
            }
        }

        return lines
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
