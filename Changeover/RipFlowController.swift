import Foundation
import Observation

/// #0061 — the rip window's own state: which movie is picked, whether the
/// user has confirmed it, and which finished job's outcome card they have
/// dismissed. Everything else the flow needs already lives on
/// `JobController` (`docs/ux-step-flow.md` §4.2).
///
/// Owned by `AppDelegate`, not by a view, for the reason `JobController` is
/// (#0002): closing the window must not throw the selection away mid-job, and
/// Phase 4 will drive this with no window at all.
///
/// A plain `final class` — MainActor for free under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — and `@Observable`, never
/// `ObservableObject` (`CLAUDE.md`). Every *decision* it makes is delegated
/// to a pure function (`FlowStep.derive`, `SelectionReset.reconcile`); the
/// methods below are the one-line state changes the views call.
@Observable
final class RipFlowController {

    /// The search view model, whose lifetime used to be the window's.
    /// Hoisted with the rest of the flow so a reopened window doesn't come
    /// up with a fresh, empty search while a job is still running.
    let search: MovieSearchViewModel

    /// The row selected in the results list — `nil` when nothing is picked.
    private(set) var selectedMovieID: Int?

    /// #0034 — the disc `selectedMovieID`/`search.selectedMovie` were chosen
    /// for. Set alongside the selection (or bound to the first disc inserted
    /// after a selection made with no disc in the drive), and reconciled
    /// against `JobController.insertedDisc` on every insertion and whenever
    /// a job stops, so a *different* disc clears a stale selection instead
    /// of letting Start file the new disc under the previous movie's name.
    private(set) var selectionDisc: DiscInsertion?

    /// Continue was pressed for the current selection. The one bit that
    /// separates "Choose movie" from "Confirm": a single click selects a
    /// row, and only Continue (or Return) advances, so a mis-click on a
    /// 40-row TMDB list can never skip a step.
    private(set) var movieConfirmed = false

    /// The finished job whose outcome card the user dismissed with "Next
    /// Disc". Cleared implicitly: a later job has a different `JobID`, so
    /// its own card shows without anything resetting this.
    private(set) var dismissedJobID: JobID?

    /// `search` is optional rather than defaulted to `MovieSearchViewModel()`
    /// in the signature: a default argument expression is evaluated in a
    /// `nonisolated` context, and the view model is explicitly `@MainActor`.
    init(search: MovieSearchViewModel? = nil) {
        self.search = search ?? MovieSearchViewModel()
    }

    // MARK: - The step

    /// Everything `FlowStep.derive` looks at, read off `jobs` and `self` at
    /// one instant. `hasMovieSelected` is `search.selectedMovie != nil`, the
    /// same fact `StartGate.decide` takes, never `selectedMovieID` — a row
    /// id that no longer resolves against `search.results` is not a movie.
    func inputs(jobs: JobController) -> FlowStep.Inputs {
        FlowStep.Inputs(
            currentJobID: jobs.current?.id,
            lastJob: jobs.history.last.map {
                FlowStep.Inputs.LastJob(id: $0.id, disc: $0.metadata.selectionDisc)
            },
            dismissedJobID: dismissedJobID,
            isEjecting: jobs.isEjecting,
            discUnavailable: jobs.discUnavailable,
            insertedDisc: jobs.insertedDisc,
            hasMovieSelected: search.selectedMovie != nil,
            movieConfirmed: movieConfirmed
        )
    }

    func step(jobs: JobController) -> FlowStep {
        FlowStep.derive(inputs(jobs: jobs))
    }

    // MARK: - Intents

    /// A results row was clicked (or the selection cleared). Binds the pick
    /// to the disc currently in the drive (#0034) and forwards to the view
    /// model, which starts the #0032 runtime lookup.
    ///
    /// Picking a *different* movie drops a previous confirmation: the
    /// Confirm step is about one movie, and the disc title, tracks and
    /// runtime acknowledgement on it were all judged against that one.
    func select(movieID: Int?, jobs: JobController, apiKey: String) {
        if movieID != selectedMovieID {
            movieConfirmed = false
        }
        selectedMovieID = movieID
        search.select(movieID: movieID, apiKey: apiKey)
        selectionDisc = movieID != nil ? jobs.insertedDisc : nil
    }

    /// The Continue button (and Return) on the Choose-movie step. A no-op
    /// without a resolved movie, so a stale row id can never advance the
    /// flow to a Confirm step with no movie on it.
    func continueToConfirm() {
        guard search.selectedMovie != nil else { return }
        movieConfirmed = true
    }

    /// "Change movie" on the Confirm step: back to the results, with the
    /// query, the results and the same row still selected.
    func changeMovie() {
        movieConfirmed = false
    }

    /// "Next Disc" on the Done step — dismisses that job's outcome card, so
    /// the flow falls through to whatever the disc situation actually is.
    func dismissOutcome(jobs: JobController) {
        dismissedJobID = jobs.history.last?.id
    }

    /// "Adjust & Retry": dismiss the outcome card and land straight back on
    /// Confirm with the movie, title, tracks and extras intact, rather than
    /// replaying the recorded request unchanged (`JobController.retry`).
    func adjustAndRetry(jobs: JobController) {
        dismissOutcome(jobs: jobs)
        if search.selectedMovie != nil {
            movieConfirmed = true
        }
    }

    // MARK: - Search (#0030)

    /// Called on every keystroke. Clears the selection first — without it, a
    /// new search leaves `selectedMovieID` pointing at the previous results'
    /// row, so re-picking the same id in the new results never changes it,
    /// `search.selectedMovie` stays as `search` reset it, and Start is
    /// permanently disabled (#0030's handoff bug). Clearing the selection
    /// also clears `movieConfirmed`, so the flow returns to Choose movie
    /// rather than showing a Confirm step for a movie that is no longer
    /// picked.
    func queryChanged(apiKey: String) {
        clearSelection()
        search.queryChanged(apiKey: apiKey)
    }

    /// Return / the Search button: the zero-delay path, with the same
    /// selection clear as the debounced one.
    func runSearchNow(apiKey: String) {
        clearSelection()
        search.runSearchNow(apiKey: apiKey)
    }

    /// #0030 review — the keystroke clears the selection at once, but the
    /// debounced search clears `search.selectedMovie` only when it fires. A
    /// row clicked inside that window would leave `selectedMovieID` set with
    /// no selected movie, which is the stuck re-pick bug again. The view
    /// follows `search.selectedMovie?.id` and calls this whenever the view
    /// model drops the selection.
    func followSelectionDrop() {
        guard search.selectedMovie == nil, selectedMovieID != nil else { return }
        clearSelection()
    }

    private func clearSelection() {
        selectedMovieID = nil
        movieConfirmed = false
    }

    // MARK: - Disc swap (#0034)

    /// Applies `SelectionReset.reconcile`. Called from the root view's
    /// `onChange` of `jobs.insertedDisc`/`jobs.isRunning` — the observation
    /// trigger stays in SwiftUI, the decision stays in the pure function.
    ///
    /// A `.reset` also clears `movieConfirmed`: the Confirm step's whole
    /// content (title, tracks, runtime verdict) belonged to the disc that
    /// just left.
    func reconcile(jobs: JobController) {
        switch SelectionReset.reconcile(
            selectionDisc: selectionDisc,
            hasSelection: selectedMovieID != nil,
            currentDisc: jobs.insertedDisc,
            isRunning: jobs.isRunning
        ) {
        case .keep:
            break
        case .bind(let disc):
            selectionDisc = disc
        case .reset:
            search.resetForNewDisc()
            selectedMovieID = nil
            selectionDisc = nil
            movieConfirmed = false
        }
    }

    // MARK: - Start

    /// The request the Start button hands to `JobController.start` — the
    /// movie (bound to the disc it was chosen for, #0034), the feature
    /// title, the extras and the audio tracks `JobController` currently
    /// holds for this disc. `nil` when there is no movie or no settled
    /// title, which is exactly when `StartGate` already disables Start.
    func ripRequest(jobs: JobController) -> RipRequest? {
        guard let movie = search.selectedMovie, let featureTitleIndex = jobs.selectedTitleIndex else { return nil }
        return RipRequest(
            metadata: MovieMetadata(from: movie, selectionDisc: selectionDisc),
            featureTitleIndex: featureTitleIndex,
            extraTitleIndices: jobs.selectedExtraTitleIndices.sorted(),
            audioTrackNumbers: jobs.selectedAudioTrackNumbers
        )
    }

    /// Starts the job, if there is one to start. Returns whatever
    /// `JobController.start` decided, so a refusal is still logged there.
    @discardableResult
    func startRipping(jobs: JobController, settings: AppSettings) -> Bool {
        guard let request = ripRequest(jobs: jobs) else { return false }
        return jobs.start(request: request, settings: settings)
    }
}
