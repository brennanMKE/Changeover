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

    /// #0062 — where the "already in Plex" check stands for the selected
    /// movie. Never stored across selections: every event that changes what
    /// was checked resets it (see `clearLibraryCheck`).
    private(set) var libraryCheck: LibraryCheck = .idle

    /// #0062 — the user's "Replace the Existing File", keyed on the movie
    /// *and* the folder it was shown for (#0032's `MismatchAcknowledgement`
    /// pattern). A confirmation for one film must never enable Start for
    /// another.
    private(set) var replaceAcknowledgement: ReplaceAcknowledgement?

    /// Bumped by every `checkLibrary`, so a result for a movie that is no
    /// longer selected is discarded — the same generation guard `startScan`
    /// uses for a superseded disc scan.
    private var libraryCheckGeneration = 0

    /// The disc a search-term prefill has already been attempted for
    /// (`SearchPrefill.decide`'s `alreadyAttemptedFor`), whether or not it
    /// actually filled the field — so a disc is only ever offered one
    /// automatic prefill per insertion, and clearing the field is never
    /// fought.
    private(set) var prefillAttemptedFor: DiscInsertion?

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
            // #0062: a different film is a different library question. The
            // #0026 lesson, keyed the same way.
            clearLibraryCheck()
        } else {
            // A re-pick of the same row still drops the confirmation: a round
            // trip through the results list is not proof the user meant the
            // same replacement again. The check itself still stands — it is
            // for this movie, and the view's `.task(id:)` key hasn't changed,
            // so nothing would re-run it.
            replaceAcknowledgement = nil
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
        // #0062: the library answer still applies (same movie, same root, so
        // the view's `.task(id:)` key is unchanged and nothing re-lists), but
        // the confirmation is given on the Confirm step and does not survive
        // leaving it.
        replaceAcknowledgement = nil
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
        clearLibraryCheck()
    }

    // MARK: - "Already in Plex" (#0062)

    /// What `ConfirmStepView.task(id:)` keys on: the probe re-runs only when
    /// the movie or the library root changes. `nil` with no movie selected —
    /// there is nothing to look up.
    func libraryCheckKey(settings: AppSettings) -> LibraryCheckKey? {
        guard let movie = search.selectedMovie else { return nil }
        return LibraryCheckKey(movieID: movie.id, moviesPath: settings.plexMoviesPath)
    }

    /// Runs the probe for the movie currently selected, and stores the answer
    /// — unless the selection moved on while it was in flight, in which case
    /// the result is dropped (the generation guard `startScan` established).
    ///
    /// Called from the Confirm step's `.task(id:)`, which fires the moment
    /// the step appears for a movie. That is the whole point: the answer is on
    /// screen seconds after the film is chosen, tens of minutes before an
    /// encode would have found out.
    func checkLibrary(settings: AppSettings, probe: LibraryProbeRunner = LibraryProbe.defaultRunner) async {
        guard let movie = search.selectedMovie else { return }
        let tmdbID = String(movie.id)
        let moviesPath = settings.plexMoviesPath

        libraryCheckGeneration += 1
        let generation = libraryCheckGeneration
        libraryCheck = .checking(tmdbID: tmdbID)

        let lookup = await probe(moviesPath, tmdbID)

        guard generation == libraryCheckGeneration, search.selectedMovie?.id == movie.id else { return }
        libraryCheck = .done(tmdbID: tmdbID, lookup)
    }

    /// "Replace the Existing File" — records the movie *and* the folder the
    /// notice was showing, which is what `StartGate` compares. A no-op unless
    /// there is a completed check with a match in it, so the button can never
    /// record a confirmation for something that isn't on screen.
    func acknowledgeReplace() {
        guard case .done(let tmdbID, .present(let entries)) = libraryCheck,
              let first = entries.first,
              let movieID = Int(tmdbID) else { return }
        replaceAcknowledgement = ReplaceAcknowledgement(movieID: movieID, folderPath: first.folderPath)
    }

    /// Both halves, together: the answer and any confirmation given for it.
    /// Bumps the generation so a probe already in flight lands on nothing.
    private func clearLibraryCheck() {
        libraryCheckGeneration += 1
        libraryCheck = .idle
        replaceAcknowledgement = nil
    }

    // MARK: - Disc swap (#0034)

    /// Applies `SelectionReset.reconcile`. Called from the root view's
    /// `onChange` of `jobs.insertedDisc`/`jobs.isRunning` — the observation
    /// trigger stays in SwiftUI, the decision stays in the pure function.
    ///
    /// A `.reset` also clears `movieConfirmed`: the Confirm step's whole
    /// content (title, tracks, runtime verdict) belonged to the disc that
    /// just left.
    ///
    /// `apiKey` is only needed for the search-prefill below (`fill` runs the
    /// search); it defaults to `""` so every existing caller — including the
    /// tests that predate the prefill — keeps compiling. The real call site,
    /// `RipFlowView`, always passes `settings.tmdbAPIKey`.
    func reconcile(jobs: JobController, apiKey: String = "") {
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
            // #0062: "per disc" comes from living here — a disc swap wipes
            // the library answer and its confirmation exactly as it wipes
            // `selectionDisc`.
            clearLibraryCheck()
        }
        attemptSearchPrefill(jobs: jobs, apiKey: apiKey)
    }

    // MARK: - Search prefill from the disc name

    /// The disc-name auto-search: turns the volume name of the disc now in
    /// the drive into a TMDB search term (`DiscNameSearchTerm.derive`) and,
    /// if `SearchPrefill.decide` says to, fills the search field with it and
    /// runs the search immediately — so results are waiting by the time the
    /// user looks at the Choose-movie step, the way typing the title by hand
    /// used to make them wait for it.
    ///
    /// A no-op with no disc in the drive. Runs on every `reconcile` (every
    /// insertion, and every job start/finish), but `SearchPrefill.decide`'s
    /// `alreadyAttemptedFor` check makes every call after the first for a
    /// given disc a no-op too.
    private func attemptSearchPrefill(jobs: JobController, apiKey: String) {
        guard let disc = jobs.insertedDisc else { return }
        let term = DiscNameSearchTerm.derive(volumeName: disc.mountURL.lastPathComponent)
        switch SearchPrefill.decide(disc: disc, term: term, query: search.query, alreadyAttemptedFor: prefillAttemptedFor) {
        case .skip:
            break
        case .markAttempted:
            prefillAttemptedFor = disc
        case .fill(let term):
            prefillAttemptedFor = disc
            search.query = term
            runSearchNow(apiKey: apiKey)
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
            audioTrackNumbers: jobs.selectedAudioTrackNumbers,
            // Menu intelligence: the disc's own chapter names, only when the
            // read finished before Start and only when their count matches
            // this title's. `nil` — the usual case — is today's bare
            // `--markers`, and a read still in flight is simply not waited
            // for.
            chapterMarkers: jobs.chapterMarkerRows
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
