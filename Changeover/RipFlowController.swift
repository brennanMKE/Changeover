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

    /// §7.2 — where the `ffprobe` read of the matched library file stands.
    /// Only ever started once `libraryCheck` has found one, and cleared by
    /// everything that clears `libraryCheck`.
    private(set) var fileCheck: FileInventoryCheck = .idle

    /// §7.3 — the card's explicit "replace existing chapter names" tick. Off
    /// by default and reset with every other per-selection piece of state: a
    /// permission given for one file must never carry to another.
    var overwriteExistingChapterNames = false

    /// Bumped by every `checkLibrary`, so a result for a movie that is no
    /// longer selected is discarded — the same generation guard `startScan`
    /// uses for a superseded disc scan.
    private var libraryCheckGeneration = 0

    /// The same guard for the file probe, bumped independently: the library
    /// listing and the `ffprobe` read finish at different times and one must
    /// not discard the other's answer.
    private var fileCheckGeneration = 0

    /// The disc a search-term prefill has already been attempted for
    /// (`SearchPrefill.decide`'s `alreadyAttemptedFor`), whether or not it
    /// actually filled the field — so a disc is only ever offered one
    /// automatic prefill per insertion, and clearing the field is never
    /// fought.
    private(set) var prefillAttemptedFor: DiscInsertion?

    /// The disc whose printed menu title has already been tried as a search
    /// term, so the retry happens once rather than on every reconcile.
    private var menuTitleTriedFor: DiscInsertion?

    /// The disc the model has already been asked about. One question per
    /// disc, whatever the answer.
    private var inferenceTriedFor: DiscInsertion?

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
        // §7: the file probe, its answer and the overwrite permission are all
        // about the file the library check found. When that goes, so do they.
        fileCheckGeneration += 1
        fileCheck = .idle
        overwriteExistingChapterNames = false
    }

    // MARK: - Upgrading an existing import (docs/menu-intelligence.md §7)

    /// The library file an upgrade would rewrite: the first video file in the
    /// first matched folder. `nil` when the check found nothing — which is
    /// the common case and costs nothing.
    var upgradeTargetPath: String? {
        guard case .done(_, .present(let entries)) = libraryCheck,
              let entry = entries.first,
              let file = entry.files.first else { return nil }
        return (entry.folderPath as NSString).appendingPathComponent(file.name)
    }

    /// What `ConfirmStepView.task(id:)` keys the file probe on. `nil` when
    /// there is no matched file or no `ffprobe` — in both cases there is
    /// nothing to read.
    func fileInventoryKey(settings: AppSettings) -> FileInventoryKey? {
        guard let path = upgradeTargetPath, settings.isFFmpegAvailable else { return nil }
        return FileInventoryKey(path: path, ffprobePath: settings.ffprobePath)
    }

    /// Reads what the matched library file already has. Runs off the main
    /// actor (`UpgradeController.probe` is `@concurrent`), and its answer is
    /// dropped if the selection moved on while it was in flight.
    ///
    /// Never blocks Start and never affects a rip: a probe that fails leaves
    /// `.unavailable` and the upgrade simply is not offered.
    func checkFile(
        settings: AppSettings,
        probe: @Sendable (String, String) async -> Result<LibraryFileInventory, JobFailure> = { path, ffprobePath in
            await UpgradeController.probe(path: path, ffprobePath: ffprobePath)
        }
    ) async {
        guard let path = upgradeTargetPath else { return }
        let ffprobePath = settings.ffprobePath

        fileCheckGeneration += 1
        let generation = fileCheckGeneration
        fileCheck = .checking(path: path)

        let result = await probe(path, ffprobePath)

        guard generation == fileCheckGeneration, upgradeTargetPath == path else { return }
        switch result {
        case .success(let inventory):
            fileCheck = .done(path: path, inventory)
        case .failure(let failure):
            fileCheck = .unavailable(path: path, reason: FailurePresenter.message(for: failure).headline)
        }
    }

    /// The comparison for the file the library check found and the disc in
    /// the drive. `nil` until both halves are in.
    ///
    /// The two halves are deliberately separate values: `LibraryFileGaps`
    /// answers "what does this file lack?" from the file alone — which is
    /// what a library-wide sweep would list, with no disc anywhere — and
    /// `DiscUpgradeOffer` answers "what can this disc supply?". This is the
    /// one place today that joins them.
    func upgradeProposal(jobs: JobController) -> UpgradeProposal.Result? {
        guard case .done(let path, let inventory) = fileCheck else { return nil }
        let offer = jobs.menuState.intelligence.map(DiscUpgradeOffer.make(menu:)) ?? DiscUpgradeOffer()
        return UpgradeProposal.compare(
            filePath: path,
            inventory: inventory,
            offer: offer,
            overwriteExistingNames: overwriteExistingChapterNames
        )
    }

    /// Whether the Upgrade button is live, and if not, why.
    ///
    /// - Parameter ffmpegAvailable: defaults to the real filesystem check.
    ///   Passed explicitly by tests so the decision never depends on whether
    ///   the host they run on happens to have `brew install ffmpeg`.
    func upgradeDecision(jobs: JobController, settings: AppSettings, ffmpegAvailable: Bool? = nil) -> StartDecision {
        StartGate.decideUpgrade(
            isRunning: jobs.isRunning,
            hasMovieSelected: search.selectedMovie != nil,
            ffmpegAvailable: ffmpegAvailable ?? settings.isFFmpegAvailable,
            libraryCheck: libraryCheck,
            fileCheck: fileCheck,
            proposal: upgradeProposal(jobs: jobs),
            replaceAcknowledgement: replaceAcknowledgement
        )
    }

    /// The request the Upgrade button hands to `JobController.start`: the
    /// same shape a rip uses, with the plan attached and no extras.
    func upgradeRequest(jobs: JobController) -> RipRequest? {
        guard let plan = upgradeProposal(jobs: jobs)?.plan, var request = ripRequest(jobs: jobs) else { return nil }
        request.extraTitleIndices = []
        request.chapterMarkers = nil
        request.upgrade = plan
        return request
    }

    /// Starts the upgrade, if there is one to start.
    @discardableResult
    func startUpgrade(jobs: JobController, settings: AppSettings, ffmpegAvailable: Bool? = nil) -> Bool {
        guard upgradeDecision(jobs: jobs, settings: settings, ffmpegAvailable: ffmpegAvailable) == .ready,
              let request = upgradeRequest(jobs: jobs) else { return false }
        return jobs.start(request: request, settings: settings)
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
    func reconcile(jobs: JobController, apiKey: String = "", settings: AppSettings? = nil) {
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
        attemptMenuTitleFallback(jobs: jobs, apiKey: apiKey)
        if let settings { attemptInferredTitle(jobs: jobs, settings: settings) }
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
            searchThenTryTheDiscsOwnTitle(jobs: jobs, disc: disc, apiKey: apiKey)
        }
    }

    /// Retry the search with the disc's own printed title, once the menu read
    /// has produced one.
    ///
    /// The timing is why this exists separately from the prefill. The scan
    /// finishes, the box is prefilled from the volume label and searched —
    /// and the menu read, which is what knows the disc's printed title, only
    /// finishes about a minute later. The first search's own completion is
    /// therefore too early to ask: on Enemy at the Gates the fallback ran,
    /// found `titleText` still nil, and did nothing, which looked exactly
    /// like the fallback not working at all.
    ///
    /// Driven instead by the menus arriving. Once per disc, and never over a
    /// search that worked or a query the user has touched.
    private func attemptMenuTitleFallback(jobs: JobController, apiKey: String) {
        guard let disc = jobs.insertedDisc,
              menuTitleTriedFor != disc,
              search.lastSearchedQuery != nil,
              search.results.isEmpty,
              !search.isLoading,
              search.errorMessage == nil,
              search.selectedMovie == nil,
              let printed = jobs.menuState.intelligence?.titleText?.text,
              !printed.isEmpty,
              // The box still holds what we put there, so nothing the user
              // typed is about to be overwritten.
              search.query == search.lastSearchedQuery,
              MenuArchive.fold(printed) != MenuArchive.fold(search.query)
        else { return }

        menuTitleTriedFor = disc
        search.query = printed
        search.runSearchNow(apiKey: apiKey)
    }

    /// Ask the on-device model what film this is, from everything the disc
    /// printed on its menus.
    ///
    /// Last of all, and only when every deterministic route has produced a
    /// term TMDB does not recognise. The rules read structure — word
    /// boundaries in a label, the tallest text on an entry menu — and a disc
    /// that hides its title from both of those is asking a language question:
    /// a person reading SCENE SELECTION, THE WOLF HUNTER and INSIDE ENEMY AT
    /// THE GATES names the film at once.
    ///
    /// The answer is searched, never selected. If TMDB knows no such film,
    /// nothing changes and the user types as they do today.
    private func attemptInferredTitle(jobs: JobController, settings: AppSettings) {
        guard settings.usesAppleIntelligence,
              let disc = jobs.insertedDisc,
              inferenceTriedFor != disc,
              search.lastSearchedQuery != nil,
              search.results.isEmpty,
              !search.isLoading,
              search.errorMessage == nil,
              search.selectedMovie == nil,
              search.query == search.lastSearchedQuery,
              let question = DiscTitleInference.question(
                  volumeName: disc.mountURL.lastPathComponent,
                  ocr: jobs.menuState.intelligence?.ocr
              )
        else { return }

        inferenceTriedFor = disc
        let apiKey = settings.tmdbAPIKey
        Task { [weak self] in
            let answer = await DiscTitleInference.answer(for: question)
            guard let self, jobs.insertedDisc == disc else { return }
            // Everything that was true when the question was asked has to
            // still be true: a minute has passed and the user may have typed,
            // searched or chosen in it.
            guard let title = answer.title,
                  self.search.results.isEmpty,
                  self.search.selectedMovie == nil,
                  self.search.query == self.search.lastSearchedQuery,
                  MenuArchive.fold(title) != MenuArchive.fold(self.search.query)
            else { return }

            self.search.query = title
            self.search.runSearchNow(apiKey: apiKey)
        }
    }

    /// Search the volume-derived term, and if it matches nothing, search the
    /// title the disc printed on its own menu.
    ///
    /// The volume label is a filename and the menu is typography, so they
    /// fail in opposite directions: `ENEMYATTHEGATES` has had its spaces
    /// taken out and matches no film, while the same disc's main menu prints
    /// "Enemy at the Gates" in words. `MenuTitleGuess` has been reading that
    /// text all along — it was simply never consulted unless the volume name
    /// produced nothing at all, and a label that produces a *wrong* term is
    /// not a label that produces nothing.
    ///
    /// Deliberately keyed on the search coming back empty rather than on the
    /// label looking odd. There is no reliable tell in the label itself:
    /// `OPPENHEIMER` is one long word and is right, `ENEMYATTHEGATES` is one
    /// long word and is wrong. "TMDB knows of no such film" is the signal
    /// that means what it says.
    private func searchThenTryTheDiscsOwnTitle(jobs: JobController, disc: DiscInsertion, apiKey: String) {
        Task { [weak self] in
            await self?.search.search(apiKey: apiKey)
            guard let self else { return }
            // Nothing is retried if the disc changed under us, if the user
            // has started typing, or if the first search actually worked.
            guard jobs.insertedDisc == disc,
                  self.search.results.isEmpty,
                  self.search.errorMessage == nil,
                  let printed = jobs.menuState.intelligence?.titleText?.text,
                  !printed.isEmpty,
                  MenuArchive.fold(printed) != MenuArchive.fold(self.search.query)
            else { return }

            self.search.query = printed
            self.search.runSearchNow(apiKey: apiKey)
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
