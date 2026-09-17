import Foundation

/// #0061 — the disc scan as one line (`docs/ux-step-flow.md` §2, step 2).
///
/// The scan is deliberately *not* a step of its own: it overlaps with the
/// user searching TMDB, and blocking the window on it for tens of seconds
/// would make the loop slower than it is today. It shows as a strip at the
/// top of the Choose-movie step instead, and as the disc panel on Confirm
/// (which is `DiscTitleListView`, unchanged).
///
/// Pure and `nonisolated`: what the strip says and which button it offers is
/// a value, not something a view decides.
nonisolated enum ScanStatusLine {

    /// The one control the strip may offer, if any.
    nonisolated enum Action: Equatable, Sendable {
        case none
        /// #0051 — `JobController.cancelScan()`. A hung scan on a scratched
        /// disc has to have a way out that isn't the 15-minute watchdog.
        case cancelScan
        /// `JobController.startScan(settings:)`.
        case rescan
    }

    nonisolated struct Line: Equatable, Sendable {
        let text: String
        let tone: JobPresentation.Tone
        let action: Action
    }

    /// `nil` at `.idle` — no disc has been scanned, so there is nothing to
    /// say and no empty strip to draw.
    static func line(for scanState: ScanState) -> Line? {
        switch scanState {
        case .idle:
            return nil

        case .scanning:
            return Line(
                text: "Scanning disc — this takes tens of seconds…",
                tone: .active,
                action: .cancelScan
            )

        case .failed(let failure):
            return Line(
                text: DiscTitleFormatting.scanFailureMessage(failure),
                tone: .failure,
                action: .rescan
            )

        case .scanned(let result):
            // #0039: a scan that read zero titles is a success with an empty
            // title list, and the user sees it as a failure — the same
            // message and the same Rescan button `DiscTitleListView` shows.
            guard !result.disc.titles.isEmpty else {
                return Line(
                    text: DiscTitleFormatting.noTitlesMessage(warnings: result.warnings, lastLine: result.lastLine),
                    tone: .failure,
                    action: .rescan
                )
            }
            let count = result.disc.titles.count
            let titles = "\(count) title\(count == 1 ? "" : "s")"
            switch DiscTitleHeuristic.classify(result.disc, mainFeatureIndex: result.mainFeatureIndex) {
            case .single:
                return Line(text: "Scan complete — \(titles), main feature detected", tone: .success, action: .none)
            case .playAll:
                // #0025: nothing is preselected on a Play All disc, and the
                // strip must not imply otherwise.
                return Line(text: "Scan complete — \(titles), none of them looks like a movie", tone: .warning, action: .none)
            case .none, .noTitles:
                return Line(text: "Scan complete — \(titles), choose one on the next step", tone: .warning, action: .none)
            }
        }
    }
}
