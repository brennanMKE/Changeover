import Foundation

/// #0228 — everything this disc is importing, and where each item got to.
///
/// The user, on the window during a rip: "if we select the main feature and 1 or
/// more extras it would show which ones are currently being imported, what is
/// done and what is pending."
///
/// The app already knew all of it and showed almost none of it. During a rip
/// the Ripping step says "film 2 of 3" and gives a bar for whatever is encoding
/// now; the per-item list exists only on the **Done** step, only for films, and
/// only once everything has finished. So the one moment the list is most useful
/// — while forty minutes of encoding runs — is the moment it was absent.
///
/// Two sources, deliberately kept apart rather than merged:
///
/// - **Films** come from `DiscRipPlan.Entry.State`, which has tracked
///   waiting/running/done/failed/skipped since #0163. One job per film.
/// - **Extras** come from `Job.extraOutcomes` (#0227), which is the same five
///   states one level down, inside a single job.
///
/// Merging the two models was the obvious move and is the wrong one. A film is
/// a job and an extra is a step inside a job; they fail differently (a failed
/// extra does not fail its job, #0031), they are planned at different moments,
/// and #0186's no-overwrite guarantee lives in a film's `JobIntent` having no
/// feature destination. A single mutable plan spanning both would put that
/// guarantee behind a shared type. So this reads both and presents one list.
nonisolated enum ImportProgressList {

    /// What an item is, which decides how it is named and indented.
    nonisolated enum Kind: Equatable, Sendable {
        case film
        /// Filed inside a film's folder, so it is shown under one.
        case extra(folderName: String)
    }

    nonisolated enum State: Equatable, Sendable {
        case waiting
        case running
        case done
        case failed(reason: String?)
        case skipped(reason: String?)

        /// The dot beside the row. Named rather than drawn here so a view
        /// chooses the symbol and this stays testable.
        var tone: Tone {
            switch self {
            case .done: return .good
            case .running: return .active
            case .failed: return .bad
            case .skipped: return .muted
            case .waiting: return .pending
            }
        }
    }

    nonisolated enum Tone: Equatable, Sendable {
        case good, bad, active, muted, pending
    }

    nonisolated struct Row: Equatable, Sendable, Identifiable {
        /// Stable across refreshes: a title index is unique on one disc, and a
        /// film and an extra can never share one.
        var id: Int { titleIndex }
        var titleIndex: Int
        var name: String
        var kind: Kind
        var state: State

        /// The sentence beside the name. Plain register — `docs/plain-language-ui.md`
        /// — because this list is on screen during a rip, where nothing is
        /// being decided and detail is noise.
        var status: String {
            switch state {
            case .waiting: return "Waiting"
            case .running: return "Importing now"
            case .done: return "Added to Plex"
            case .failed(let reason):
                return reason.map { "Didn't finish — \($0)" } ?? "Didn't finish"
            case .skipped(let reason):
                return reason.map { "Skipped — \($0)" } ?? "Skipped"
            }
        }
    }

    /// The whole list: films in disc order, each followed by the extras that
    /// will be filed inside it.
    ///
    /// `extras` is the *resolved* plan the running job carries, and `outcomes`
    /// its progress — both read from the job rather than from the live
    /// selection, which can move on while an encode runs (#0225).
    static func rows(
        films: [FilmRow],
        extras: [ExtraRow]
    ) -> [Row] {
        films.flatMap { film -> [Row] in
            [Row(titleIndex: film.titleIndex, name: film.name, kind: .film, state: film.state)]
                + extras
                    .filter { $0.filmTitleIndex == film.titleIndex }
                    .map { Row(titleIndex: $0.titleIndex, name: $0.name,
                               kind: .extra(folderName: $0.folderName), state: $0.state) }
        }
    }

    /// One film and where its job got to.
    nonisolated struct FilmRow: Equatable, Sendable {
        var titleIndex: Int
        var name: String
        var state: State
    }

    /// One extra, the film it belongs to, and where it got to.
    nonisolated struct ExtraRow: Equatable, Sendable {
        var titleIndex: Int
        var name: String
        var folderName: String
        /// Which film's folder this lands in. On a single-film disc that is the
        /// only film; on a double feature an extra currently belongs to *every*
        /// film (#0226), so it appears once under each — which is exactly what
        /// the disc will produce, and showing it twice is the honest picture
        /// rather than a glitch.
        var filmTitleIndex: Int
        var state: State
    }

    /// `ExtraOutcome` as a list state. A separate type because the list also
    /// carries films, whose states come from `DiscRipPlan`.
    static func state(of outcome: ExtraOutcome) -> State {
        switch outcome {
        case .waiting: return .waiting
        case .running: return .running
        case .done: return .done
        case .failed(let reason): return .failed(reason: reason)
        case .skipped(let reason): return .skipped(reason: reason)
        }
    }

    /// One line summarising the list, for the place a full table does not fit.
    ///
    /// Counts what was *produced*, not what was planned: "3 of 4" is the
    /// sentence that makes a lost extra visible, and a lost extra used to exist
    /// only in the log.
    static func summary(_ rows: [Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        let done = rows.filter { $0.state == .done }.count
        let unproduced = rows.filter {
            if case .failed = $0.state { return true }
            if case .skipped = $0.state { return true }
            return false
        }.count
        if done == rows.count { return "All \(rows.count) added to Plex." }
        if unproduced > 0 {
            return "\(done) of \(rows.count) added to Plex — \(unproduced) didn't make it."
        }
        return "\(done) of \(rows.count) added to Plex."
    }
}
