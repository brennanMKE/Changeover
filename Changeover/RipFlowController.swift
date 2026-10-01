import Foundation
import Observation

/// #0142 — the rip window's own state: which movie is picked, whether the
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

    /// #0143 — where the "already in Plex" check stands for the selected
    /// movie. Never stored across selections: every event that changes what
    /// was checked resets it (see `clearLibraryCheck`).
    private(set) var libraryCheck: LibraryCheck = .idle

    /// The library answer as it applies to **this cut** of the film.
    ///
    /// The probe answers "is this film in the library", which is the wrong
    /// question once editions exist: a collector's edition would inherit the
    /// theatrical release's answer and be refused as a duplicate of it. A
    /// folder that holds the film but not this cut reads as `.absent`, so
    /// every consumer — the Start gate, the notice, the unattended eject —
    /// gets the right answer without each having to know about editions.
    ///
    /// Computed rather than stored because `edition` is a text field the user
    /// can still be typing in; re-probing the filesystem on every keystroke
    /// would be the wrong trade when the answer is already in hand.
    /// Set the library answer directly. Tests only — the production path is
    /// `checkLibrary`, which probes the filesystem.
    func setLibraryCheckForTesting(_ value: LibraryCheck) {
        libraryCheck = value
    }

    /// Adopt a multi-feature disc's titles and name films for them, with no
    /// scan, no disc and no view. Tests only.
    ///
    /// #0172 — the production path for both is `reconcile` → `syncFeatures` →
    /// `selectFeature`, and what that path *did not* do is the whole bug:
    /// the per-feature library probe only ever ran from a view that stops
    /// existing the moment its feature is named.
    func adoptFeaturesForTesting(_ indices: [Int]) {
        featureSelection.setFeatures(indices)
        for index in indices where featureSearchModels[index] == nil {
            featureSearchModels[index] = MovieSearchViewModel()
        }
    }

    func chooseForTesting(movieID: Int?, feature: Int) {
        featureSelection.choose(movieID: movieID, for: feature)
    }

    /// Set the eject explanation directly. Tests and the screenshot harness
    /// only — the production path is `evaluateAutoEject`, which needs the whole
    /// autoselect chain to have run first.
    func setUnexplainedEjectionForTesting(_ value: EjectExplanation?) {
        unexplainedEjection = value
    }

    var libraryCheckForThisEdition: LibraryCheck {
        guard case .done(let tmdbID, .present(let entries)) = libraryCheck else { return libraryCheck }
        let wanted = MovieMetadata.normalizedEdition(edition)
        return LibraryMatch.holdsEdition(wanted, in: entries)
            ? libraryCheck
            : .done(tmdbID: tmdbID, .absent)
    }

    /// #0143 — the user's "Replace the Existing File", keyed on the movie
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
    /// Which cut of the film this disc holds, as it will be written into the
    /// filename — "Collector's Edition", "Director's Cut", or empty for the
    /// ordinary release.
    ///
    /// Seeded from the volume label, which often says
    /// (`THE_HANGOVER_EXTENDED_CUT`), and editable because just as often it
    /// does not: The Jackal's collector's edition arrived on a disc labelled
    /// `WILLIS`. Without a way to say so, the second cut of a film reads as a
    /// duplicate of the first and — unattended — is ejected as one.
    var edition: String = ""

    /// The disc `edition` was seeded for, so the seed happens once per disc
    /// and never types over what the user has entered.
    private var editionSeededFor: DiscInsertion?

    /// The disc the last `reconcile` saw, so a swap is noticed however early
    /// it happens.
    private var lastSeenDisc: DiscInsertion?

    private(set) var prefillAttemptedFor: DiscInsertion?

    /// The disc whose printed menu title has already been tried as a search
    /// term, so the retry happens once rather than on every reconcile.
    private var menuTitleTriedFor: DiscInsertion?

    /// The disc the model has already been asked about. One question per
    /// disc, whatever the answer.
    private var inferenceTriedFor: DiscInsertion?

    /// The search term whose results have already been offered to the
    /// auto-selector, so a new search is considered and a redraw is not.
    private var autoSelectTriedFor: String?
    /// Which rung of the resolution ladder produced the search term in use —
    /// "label", "menuTitle", "inference", or nil when nothing resolved.
    private(set) var resolvedBy: String?
    /// The title the disc printed on its menus, if any was read.
    private(set) var menuTitleSeen: String?
    /// What the on-device model replied, used or not.
    private(set) var inferredTitleSeen: String?
    /// Last logged Start-gate verdict, so the log records changes not every tick.
    private var lastStartDecision: String?

    /// The disc whose lookup has been started, so it runs once.
    private var resolutionStartedFor: DiscInsertion?

    /// Whether the disc is being looked up right now — the search step shows
    /// this instead of a half-finished guess.
    private(set) var isResolvingDisc = false

    /// The row to mark as the recommendation, when the disc's runtime
    /// identified one. Presentation only — the selection itself is
    /// `search.selectedMovie`, and clearing this would not unpick anything.
    private(set) var recommendedMovieID: Int?

    // MARK: - Several films on one disc (#0160)

    /// Which film the user has named for each feature, on a disc that holds
    /// more than one (#0157's `DiscTitleHeuristic.multipleFeatures`).
    ///
    /// Empty — and every question on it answers "no" — for a single-feature
    /// disc, which is why nothing on the ordinary path had to change. The
    /// decisions live in the pure `FeatureSelection`; this class only keeps
    /// it in step with the scan and mirrors the chosen film into the flow's
    /// existing single selection.
    private(set) var featureSelection = FeatureSelection()

    /// One search context per feature, keyed by disc title index.
    ///
    /// Composed rather than folded into `MovieSearchViewModel`: that type
    /// already holds a query, a debounce, a generation guard, results, a
    /// selection and a runtime lookup, all of which a *second* film needs its
    /// own copy of. Making one view model indexable would have meant
    /// rewriting every one of those for a case that does not arise on 24 of
    /// the 26 discs measured; making several costs one dictionary. It also
    /// gives each feature its own `queryIsUserEntered` (#0156) for free, so
    /// what the user typed against one film is never cleared by anything
    /// happening to another.
    private var featureSearchModels: [Int: MovieSearchViewModel] = [:]

    /// The search context for one feature, or `nil` before `reconcile` has
    /// seen a scan naming it. Views render nothing for a feature with no
    /// context rather than creating one — a view body must not mutate
    /// observable state.
    func featureSearch(_ feature: Int) -> MovieSearchViewModel? {
        featureSearchModels[feature]
    }

    /// The film that will actually be ripped on this pass.
    ///
    /// Always `search.selectedMovie`: on a multi-feature disc the active
    /// feature's pick is *mirrored* into that same single selection (see
    /// `applyActiveFeature`), so every consumer downstream — `ripRequest`,
    /// the Confirm step, the library check, the archive — keeps reading the
    /// one field it always read.
    var chosenMovie: TMDBMovie? { search.selectedMovie }

    /// #0170 — the films Continue will import, in disc order, as the user
    /// would say them: `Get Hard (2015)`.
    ///
    /// Read from `plannedFilms` in spirit but not in fact — that needs a
    /// `JobController` and this is a label. On a single-feature disc it is the
    /// one selected film, so the Choose step's action bar says the same kind
    /// of thing whether the disc holds one film or three.
    /// #0172 — features whose named film does not fit the title it sits on.
    ///
    /// The Choose step showed this only inside an open search block, so a
    /// settled row that stopped fitting said nothing at all: on 2026-09-30,
    /// Get Hard (100 min) sat named on an 85-minute title with a tick beside
    /// it and Continue enabled, and the only sign was `runtimeMismatch`
    /// appearing at the Start gate two steps later. That is #0167's fault
    /// exactly, one step earlier.
    var misfittingFeatures: [Int] {
        featureSelection.runnableFeatures.filter {
            if case .mismatch = fit(for: $0) { return true }
            return false
        }
    }

    /// Whether Continue may be pressed on a multi-feature disc.
    ///
    /// A film that fails its own runtime check is not a film to carry into
    /// Confirm. Start would refuse it there anyway — the point is to refuse it
    /// where the mistake was made and where the fix is one click.
    ///
    /// #0176 — unless the user has set this disc up by hand, in which case the
    /// misfit is reported and Continue still works. The fit check compares a
    /// TMDB runtime against the title the film sits on; once a person has said
    /// which title that is, a disagreement is the app's arithmetic against
    /// their eyes, and it has already cost four days of "the build gets stuck
    /// with this disc". The warning stays on every row that earns one
    /// (`misfittingFeatures` is unchanged, and the rows read it) — it simply
    /// stops being a door.
    var mayContinueFromChoose: Bool {
        guard featureSelection.isMultiFeature else { return chosenMovie != nil }
        return ManualOverride.mayContinue(
            hasRunnableFilm: featureSelection.hasRunnableFilm,
            misfittingFeatures: misfittingFeatures.count,
            isOverridden: manualOverride.isActive)
    }

    func acknowledgeFeatureRejection() { featureSelection.acknowledgeRejection() }

    var runnableFilmTitles: [String] {
        guard featureSelection.isMultiFeature else {
            return search.selectedMovie.map { ["\($0.title) (\($0.yearText))"] } ?? []
        }
        return featureSelection.runnableFeatures.compactMap { titleOfChoice($0) }
    }

    /// The films the user named and then excluded. Separate from "not named"
    /// — an unnamed feature is an unanswered question, a skipped one is an
    /// answer, and only the second is worth reporting back.
    var skippedFilmTitles: [String] {
        guard featureSelection.isMultiFeature else { return [] }
        return featureSelection.features
            .filter { featureSelection.isSkipped($0) }
            .compactMap { titleOfChoice($0) }
    }

    /// The film named for one feature, as text. Goes through
    /// `featureSelection` rather than the view model's `selectedMovie` so a
    /// model that has not caught up cannot put a film in this list that the
    /// plan will not run (the same guard `plannedFilms` applies).
    private func titleOfChoice(_ feature: Int) -> String? {
        guard let id = featureSelection.movieID(for: feature),
              let movie = featureSearchModels[feature]?.selectedMovie,
              movie.id == id
        else { return nil }
        return "\(movie.title) (\(movie.yearText))"
    }

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
            movieConfirmed: movieConfirmed,
            unexplainedEjection: unexplainedEjection
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
    /// #0154 — who picked the film. The evidence panel is a record of the
    /// app's reasoning, and it must not present the app's guess as the reason
    /// when the user overrode it.
    ///
    /// Defaults to `.user` because that is what a bare `select` means
    /// everywhere except the one automatic caller below: a test driving this
    /// directly is standing in for a person clicking a row.
    nonisolated enum SelectionOrigin: Equatable, Sendable {
        case user
        case automatic
    }

    func select(movieID: Int?, jobs: JobController, apiKey: String,
                origin: SelectionOrigin = .user) {
        if movieID != selectedMovieID {
            movieConfirmed = false
            // #0143: a different film is a different library question. The
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

        // #0154: say who decided. `search.select` has just resolved
        // `selectedMovie` from the results, so the title is available here.
        switch origin {
        case .automatic:
            // The app decided after all, so there is no user choice to show.
            jobs.noteManualSelection(nil)
        case .user:
            guard let movie = search.selectedMovie else {
                jobs.noteManualSelection(nil)
                return
            }
            jobs.noteManualSelection(IdentificationSummary.userChoiceLine(
                movie: "\(movie.title) (\(movie.yearText))",
                query: search.query))
        }
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
        // #0143: the library answer still applies (same movie, same root, so
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

    // MARK: - Naming each film on a multi-feature disc (#0160)

    /// Keep `featureSelection` and its search contexts in step with the scan.
    ///
    /// Called from `reconcile`, which already runs on every event that could
    /// change what is in the drive or what is known about it. A scan that
    /// reads the same features again changes nothing (`setFeatures` is keyed
    /// on the list), so this is safe to call as often as everything else in
    /// `reconcile` is.
    private func syncFeatures(jobs: JobController, apiKey: String) {
        // #0176 — the scan first, unconditionally. The override panel and the
        // fit check both read the held scan, and before this it was only
        // written on the branch below, which a single-feature disc never
        // takes.
        currentScanState = jobs.scanState
        // #0176 — what the USER said this disc holds outranks what the scan's
        // classification makes of it. `features` is `nil` until the override
        // is complete, so a disc with no override, or one half-answered,
        // takes exactly the path it always did.
        let indices = manualOverride.features(amongTitles: scannedTitles.map(\.index))
            ?? FeatureSelection.features(in: Self.discOutcome(jobs.scanState))
        guard indices != featureSelection.features else { return }

        featureSelection.setFeatures(indices)
        featureLibraryChecks = featureLibraryChecks.filter { indices.contains($0.key) }
        featureLibraryGenerations = featureLibraryGenerations.filter { indices.contains($0.key) }
        featureSearchModels = featureSearchModels.filter { indices.contains($0.key) }
        for index in indices where featureSearchModels[index] == nil {
            featureSearchModels[index] = MovieSearchViewModel()
        }

        // #0156 — never throw away what the user typed.
        //
        // The scan takes tens of seconds and the search box is on screen the
        // whole time, so text typed before the disc had answered lives in the
        // single search model. That is exactly how "The Campaign" was typed
        // on 2026-09-27. When the answer turns out to be "several films",
        // that box stops being drawn — so carry the text into the first
        // feature's box, where they can still see and use it, rather than
        // leaving it somewhere nothing shows.
        if search.queryIsUserEntered,
           !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let first = indices.first,
           let model = featureSearchModels[first],
           model.query.isEmpty {
            model.query = search.query
            model.queryChanged(apiKey: apiKey)
        }
    }

    /// `DiscTitleHeuristic`'s verdict for the scan currently held, or `nil`
    /// when no scan has completed. The same classification the Choose step's
    /// table and the scan status line already run — read here rather than
    /// stored, so there is one answer and no copy of it to go stale.
    nonisolated static func discOutcome(_ scanState: ScanState) -> DiscTitleHeuristic.Outcome? {
        guard case .scanned(let result) = scanState else { return nil }
        return DiscTitleHeuristic.classify(result.disc, mainFeatureIndex: result.mainFeatureIndex)
    }

    /// A results row clicked inside one feature's block (or the pick cleared).
    func selectFeature(movieID: Int?, feature: Int, jobs: JobController, settings: AppSettings) {
        guard let model = featureSearchModels[feature] else { return }
        model.select(movieID: movieID, apiKey: settings.tmdbAPIKey)
        featureSelection.choose(movieID: movieID, for: feature)
        // #0172 — a refused pick must not leave a tick on screen.
        //
        // `choose` declines a film that already belongs to another feature
        // instead of moving it. The view model has already recorded the click
        // by then, so without this the row stays ticked while the app has not
        // accepted it — a screen that disagrees with the state behind it,
        // which is the shape of every one of this step's worst bugs.
        if movieID != nil, featureSelection.movieID(for: feature) != movieID {
            model.select(movieID: nil, apiKey: settings.tmdbAPIKey)
            return
        }
        // #0161: last film's answer must not sit under this film's name.
        featureLibraryChecks[feature] = nil
        applyActiveFeature(jobs: jobs, settings: settings)

        // #0172 — and ask the library here, not from a view that may not
        // exist.
        //
        // #0161 hung the per-feature probe on `FeatureSearchBlock.task`, which
        // was right while every feature had a search block. #0169 collapsed a
        // NAMED feature to a plain row with no task, so on a disc the app
        // identifies by itself — both films named, neither block on screen —
        // the probe never ran for either. `importableFeatureCount` counts an
        // unchecked film as importable, so the Start gate read `ready` and the
        // disc sat in the drive with both of its films already in Plex as
        // {tmdb-257091} and {tmdb-77953}. Watching `featureLibraryChecks` for
        // changes cannot help when nothing ever writes to it.
        //
        // Choosing a film is the event that makes the question askable, so the
        // ask belongs here. The block's own `.task` stays: it is generation
        // guarded, so the two cannot disagree.
        guard featureSelection.movieID(for: feature) != nil else { return }
        Task { [weak self] in
            await self?.checkLibraryForFeature(feature, settings: settings)
            self?.evaluateAutoStart(jobs: jobs, settings: settings)
        }
    }

    /// #0167 — fill one search box per film, assigned by runtime.
    ///
    /// Three sources, in the order they are worth trusting: the volume label
    /// cut into candidate titles (`DiscLabelSplit`), and — when that yields
    /// nothing — the films the on-device model read off the menus. Either way
    /// the candidates are placed on titles by `FeatureMatching`, which refuses
    /// a one-to-one assignment it cannot make within three minutes. Measured
    /// on this disc: The Great Outdoors 0.6 min out on title 1, Uncle Buck 0.4
    /// on title 2.
    ///
    /// Refusing is the normal outcome on a disc whose label is a catalogue
    /// number, and it leaves exactly what was there before: empty boxes and a
    /// note saying how many films to name.
    private func resolveEachFeature(disc: DiscInsertion, jobs: JobController, settings: AppSettings) {
        let count = featureSelection.features.count
        let titles = featureTitles()
        let apiKey = settings.tmdbAPIKey
        let labelSplits = DiscLabelSplit.candidateSplits(volumeName: disc.label, count: count)
        // #0171 — the menus, which this function claimed to read and never did.
        let menuQuestion = settings.usesAppleIntelligence
            ? MultiTitleInference.question(volumeName: disc.label,
                                           ocr: jobs.menuState.intelligence?.ocr)
            : nil

        // #0171 — say why, in `flow.log`, not only in the job log. The job
        // log is a pane the Choose step does not show, so when this gave up
        // the whole record was a sentence nobody could reach: the rung fired,
        // refused and left no trace, which is how it went a full day looking
        // like "the OCR stopped working".
        FlowDiagnostics.note("feature resolve: \(count) features, "
            + "\(titles.count) scanned title(s), apiKey=\(!apiKey.isEmpty), "
            + "labelSplits=\(labelSplits.count), "
            + "menus=\(menuQuestion.map { "\($0.lines.count) line(s)" } ?? "none") "
            + "(AI on=\(settings.usesAppleIntelligence), menuState=\(jobs.menuState.diagnosticName))")

        guard !titles.isEmpty, !apiKey.isEmpty, !(labelSplits.isEmpty && menuQuestion == nil) else {
            jobs.note("▶ This disc holds \(count) films — name each one below")
            isResolvingDisc = false
            return
        }

        isResolvingDisc = true
        jobs.note("▶ This disc holds \(count) films — working out which is which")

        Task { [weak self] in
            defer { self?.isResolvingDisc = false }
            guard let self else { return }

            // One TMDB lookup per distinct term across every candidate split,
            // cached, so three splits of a four-word label cost at most the
            // number of distinct parts rather than three times the films.
            var looked: [String: FeatureMatching.Candidate?] = [:]
            func resolve(_ splits: [[String]]) async -> [FeatureMatching.Assignment]? {
                for term in Set(splits.flatMap { $0 }) where looked[term] == nil {
                    looked[term] = await Self.candidate(for: term, apiKey: apiKey)
                }
                return FeatureMatching.bestSplit(
                    features: titles, splits: splits, lookUp: { looked[$0] ?? nil })
            }

            // Rung 1: the volume label, cut every way it can be cut.
            var assignments = labelSplits.isEmpty ? nil : await resolve(labelSplits)
            FlowDiagnostics.note("feature match: label gave \(labelSplits.count) split(s), "
                + "\(looked.values.compactMap { $0 }.count) of \(looked.count) terms resolved, "
                + "assigned=\(assignments != nil)")

            // Rung 2: the disc's own menus.
            //
            // #0171 — this rung was described in the comment above this
            // function from the day it was written and never existed. The
            // label rung can only work on a disc whose label names its films,
            // and the label on the Get Hard / The Campaign disc is
            // `7000078778_1`, a stock number. `DiscLabelSplit` returned
            // nothing, the guard above returned, and the OCR sitting in the
            // archive — GET HARD, D°ÇAMPAIGN, and the PLAY block printed once
            // per film — was never read. Every automatic match in joe's
            // flow.log was the one disc whose label happens to spell both
            // titles.
            //
            // Tried after the label rather than instead of it, and also when
            // the label produced splits that would not assign: a label that
            // names the films is better evidence than a low-resolution menu
            // read through OCR, and there is no reason to spend a model call
            // when it already worked.
            var modelTitles: [String] = []
            if assignments == nil, let menuQuestion {
                switch await MultiTitleInference.answer(for: menuQuestion, expecting: count) {
                case .titles(let reading):
                    modelTitles = reading.titles
                    FlowDiagnostics.note("feature match: the menus named "
                        + "\(reading.titles.count) film(s) — \(reading.titles.joined(separator: " | "))"
                        + "; count agreement \(reading.agreement)")
                    // The count comparison is deliberately not enforced here.
                    // `splits(from:choose:)` turns a surplus into every subset
                    // of the right size and lets the runtimes throw out the
                    // spurious name, and turns a shortfall into nothing at all.
                    assignments = await resolve(
                        FeatureMatching.splits(from: reading.titles, choose: count))
                case .unavailable(let why):
                    FlowDiagnostics.note("feature match: the menus named no film — \(why)")
                }
            }

            // Rung 3: the menu text itself, read several ways.
            //
            // #0171 — the model reads a clean title and cannot repair a
            // damaged one. Measured on this disc: it answered GET HARD and
            // nothing else, and when told the disc holds two films it invented
            // DREAMSCAPE. So the damaged line goes to TMDB instead, which is a
            // fuzzy search over real titles — "D°ÇAMPAIGN" finds a 1912
            // newsreel, "CAMPAIGN" finds The Campaign (2012).
            //
            // Several readings per line, and the disc's own clock throws out
            // everything that does not fit: one film per feature, each within
            // three minutes. A term that means nothing finds nothing.
            if assignments == nil, let menuQuestion {
                let terms = OCRSearchTerms.terms(lines: menuQuestion.lines, known: modelTitles)
                FlowDiagnostics.note("feature match: trying \(terms.count) term(s) "
                    + "off the menu text — \(terms.joined(separator: " | "))")
                assignments = await resolve(FeatureMatching.splits(from: terms, choose: count))
                FlowDiagnostics.note("feature match: menu-text terms assigned=\(assignments != nil)")
            }

            guard let assignments else {
                jobs.note("  · neither the disc label nor its menus named films that fit these runtimes — name them below")
                return
            }

            // Still the same disc, and the user has not started naming films
            // themselves in the meantime (#0156 — never overwrite their text).
            guard jobs.insertedDisc.map({ SelectionReset.sameDisc($0, disc) }) == true else {
                FlowDiagnostics.note("feature match: the disc changed — dropping the assignment")
                return
            }
            for assignment in assignments {
                guard let model = self.featureSearchModels[assignment.feature] else {
                    FlowDiagnostics.note("feature match: no search model for feature \(assignment.feature)")
                    continue
                }
                guard !model.queryIsUserEntered else {
                    FlowDiagnostics.note("feature match: feature \(assignment.feature) has the user's own text — leaving it")
                    continue
                }
                guard self.featureSelection.movieID(for: assignment.feature) == nil else {
                    FlowDiagnostics.note("feature match: feature \(assignment.feature) already has a film")
                    continue
                }
                let candidate = assignment.candidate
                let results = (try? await TMDBClient().searchMovies(
                    query: candidate.term, apiKey: apiKey)) ?? []
                model.present(query: candidate.term, results: results)
                self.selectFeature(movieID: candidate.movieID, feature: assignment.feature,
                                   jobs: jobs, settings: settings)
                FlowDiagnostics.note("feature match: feature \(assignment.feature) <- "
                    + "\(candidate.title) (id \(candidate.movieID)); choices now "
                    + "\(self.featureSelection.choices.count), runnable "
                    + "\(self.featureSelection.runnableFeatures.count)")
                jobs.note("  · \(candidate.title) (\(candidate.year)) on feature "
                    + "\(assignment.feature) — \(String(format: "%.1f", assignment.errorMinutes)) min from its runtime")
            }
        }
    }

    /// One TMDB search plus its runtime, as `FeatureMatching` needs it.
    private static func candidate(for term: String, apiKey: String) async -> FeatureMatching.Candidate? {
        let client = TMDBClient()
        guard let top = try? await client.searchMovies(query: term, apiKey: apiKey).first,
              let details = try? await client.movieDetails(id: top.id, apiKey: apiKey),
              let runtime = details.runtimeMinutes
        else { return nil }
        return FeatureMatching.Candidate(term: term, movieID: top.id, title: top.title,
                                         year: top.yearText, runtimeMinutes: runtime)
    }

    /// #0167 — "Don't import this one".
    ///
    /// The gap the user hit on 2026-09-29: both films on the Uncle Buck disc
    /// were already in Plex, and there was no way to say so. `DiscRipPlan`
    /// could skip, but only inside `startRipping` — and Start was what was
    /// blocked, because the Confirm step judged the whole disc by whichever
    /// film happened to be active. A film you do not want should not have to
    /// be ripped or argued past.
    func setFeatureSkipped(_ skip: Bool, feature: Int, jobs: JobController, settings: AppSettings) {
        featureSelection.setSkipped(skip, for: feature)
        applyActiveFeature(jobs: jobs, settings: settings)
    }

    /// #0167 — how many films on this disc will actually be imported.
    ///
    /// Named, not skipped, and either absent from Plex or acknowledged for
    /// replacement. This is what Start is judged on: a disc holding one film
    /// the user owns and one they do not must start, because `DiscRipPlan`
    /// skips the owned one and imports the other.
    var importableFeatureCount: Int {
        featureSelection.runnableFeatures.filter { feature in
            guard case .present = libraryStatus(for: feature) else { return true }
            // "Replace the Existing File" is a statement about one film, so it
            // only excuses the film it was given for.
            guard let ack = replaceAcknowledgement,
                  let movieID = featureSelection.movieID(for: feature) else { return false }
            return ack.movieID == movieID
        }.count
    }

    /// #0167 — whether the film named in one block fits that block's runtime.
    func fit(for feature: Int) -> FeatureFit.Verdict {
        guard featureSelection.isMultiFeature,
              let model = featureSearchModels[feature],
              case .loaded(_, let minutes) = model.runtimeLookup
        else { return .unknown }
        return FeatureFit.judge(runtimeMinutes: minutes,
                                feature: featureTitle(feature),
                                allFeatures: featureTitles())
    }

    /// The scanned titles for this disc's features, in disc order.
    func featureTitles() -> [DiscTitle] {
        guard case .scanned(let result) = currentScanState else { return [] }
        return featureSelection.features.compactMap { index in
            result.disc.titles.first { $0.index == index }
        }
    }

    private func featureTitle(_ feature: Int) -> DiscTitle? {
        featureTitles().first { $0.index == feature }
    }

    /// Set by `syncFeatures`, so the fit check has the scan without needing a
    /// `JobController` handed to every view that asks.
    ///
    /// #0176 — written on **every** reconcile, not only when the feature list
    /// changes. It used to be set inside `syncFeatures`' early-out, so on a
    /// single-feature disc (the list stays empty, so the guard returns) it
    /// stayed `.idle` for the whole visit: every question answered from it
    /// read as "no scan". Nothing noticed while only multi-feature discs
    /// asked; the override panel asks on every disc, and a panel with no
    /// titles to pick from is exactly the dead end this ticket is about.
    private(set) var currentScanState: ScanState = .idle

    /// Every title the scan read, in disc order — the raw table, not the
    /// app's judgement of which rows are features.
    ///
    /// #0176's override is a way past that judgement, so it has to be able to
    /// see what the judgement was made from.
    var scannedTitles: [DiscTitle] {
        guard case .scanned(let result) = currentScanState else { return [] }
        return result.disc.titles
    }

    // MARK: - The user saying what the disc is (#0176)

    /// What the user has said this disc holds, when they have said anything.
    ///
    /// Empty — and consulted by nothing — on every disc the app reads
    /// correctly, which is the normal case. The decisions all live in the pure
    /// `ManualOverride`; this class only keeps it bound to the disc in the
    /// drive and re-states it to the parts of the app that hold the same fact
    /// twice (`FeatureSelection`, and `JobController.selectedTitleIndex`).
    private(set) var manualOverride = ManualOverride()

    /// How the override stands against the disc now in the drive.
    var manualOverrideReadiness: ManualOverride.Readiness {
        manualOverride.readiness(amongTitles: scannedTitles.map(\.index))
    }

    /// What the app itself makes of this disc, for the panel's closed state.
    /// Read from the held scan rather than stored, like every other derived
    /// answer here.
    var discReading: DiscTitleHeuristic.Outcome? {
        Self.discOutcome(currentScanState)
    }

    /// "This disc holds this many films." `nil` gives it back to the app.
    func setManualFilmCount(_ count: Int?, jobs: JobController, settings: AppSettings) {
        manualOverride.setFilmCount(count)
        applyManualOverride(jobs: jobs, settings: settings)
    }

    /// "Movie `film` is this title", straight off the raw table.
    ///
    /// A pick made with no override yet **starts** one, seeded from what the
    /// app was already working from. Without the seed, correcting one title on
    /// a disc the app read as two films would leave the other film unanswered
    /// and the override imposing nothing — the user having acted, and the
    /// screen having changed nothing, which is the exact complaint this
    /// ticket exists to answer. With it, one click is one correction.
    func assignManualTitle(_ titleIndex: Int?, toFilm film: Int,
                           jobs: JobController, settings: AppSettings) {
        if !manualOverride.isActive {
            let seed = titlesTheAppChose(jobs: jobs)
            manualOverride.setFilmCount(max(film, max(1, seed.count)))
            for (position, index) in seed.enumerated() {
                manualOverride.assign(titleIndex: index, toFilm: position + 1)
            }
        }
        manualOverride.assign(titleIndex: titleIndex, toFilm: film)
        applyManualOverride(jobs: jobs, settings: settings)
    }

    /// The titles the app is already working from, in screen order: the
    /// several features it found, the one it settled on, or — when it could
    /// not tell — whatever row is picked.
    ///
    /// The panel's starting point, so it opens as a view of the current plan
    /// rather than as an empty form beside it.
    private func titlesTheAppChose(jobs: JobController) -> [Int] {
        let features = FeatureSelection.features(in: discReading)
        if !features.isEmpty { return features }
        if case .single(let index, _) = discReading { return [index] }
        return jobs.selectedTitleIndex.map { [$0] } ?? []
    }

    /// How many films the panel lists: the user's answer, or the app's
    /// reading — never fewer than one, because a panel with no rows asks
    /// nothing.
    func manualFilmCountShown(jobs: JobController) -> Int {
        manualOverride.filmCount ?? max(1, titlesTheAppChose(jobs: jobs).count)
    }

    /// The film positions the panel lists.
    func manualFilmsShown(jobs: JobController) -> [Int] {
        Array(1...manualFilmCountShown(jobs: jobs))
    }

    /// What the panel shows for one film: the user's answer once they have
    /// given one, otherwise what the app chose for that position.
    func manualTitleShown(forFilm film: Int, jobs: JobController) -> Int? {
        if manualOverride.isActive { return manualOverride.title(forFilm: film) }
        let chosen = titlesTheAppChose(jobs: jobs)
        guard film >= 1, film <= chosen.count else { return nil }
        return chosen[film - 1]
    }

    /// "Let the app decide again" — and it decides again immediately, because
    /// `syncFeatures` re-reads the scan's own outcome the moment the override
    /// stops imposing one.
    func clearManualOverride(jobs: JobController, settings: AppSettings) {
        manualOverride.clear()
        applyManualOverride(jobs: jobs, settings: settings)
    }

    /// Push the override into the two places that hold the same fact.
    ///
    /// There is no Apply button, by design: every edit takes effect the moment
    /// it is complete, which is what "a disc the app calls one film that holds
    /// two must be one action" means. An incomplete override imposes nothing
    /// at all (`Readiness.features` is `nil` until every film has a distinct
    /// title), so the step never reshapes around half an answer.
    ///
    /// On a disc the user has cut down to **one** film the title has to be
    /// settled here. `FeatureSelection` is empty for a one-film disc by
    /// design — that emptiness is what keeps the ordinary path untouched — so
    /// there is no named film to carry the title to `JobController` the way
    /// `applyActiveFeature` does on a multi-feature disc.
    private func applyManualOverride(jobs: JobController, settings: AppSettings) {
        syncFeatures(jobs: jobs, apiKey: settings.tmdbAPIKey)
        enforceManualTitle(jobs: jobs, settings: settings)
    }

    /// Keep `JobController.selectedTitleIndex` on the title a one-film
    /// override names.
    ///
    /// Re-stated on every reconcile because the *scan* re-states its own
    /// answer: `applyScanOutcome` preselects the title on a `.single` verdict,
    /// so a Scan Again would otherwise quietly undo the override a minute
    /// after it was made — the user's answer replaced by the answer they had
    /// just overruled.
    ///
    /// Never while a job is running: the title then belongs to the job, and
    /// `startNextFilm` is the only thing allowed to move it.
    private func enforceManualTitle(jobs: JobController, settings: AppSettings) {
        guard !jobs.isRunning,
              let title = manualOverride.soleFeature,
              scannedTitles.contains(where: { $0.index == title }),
              jobs.selectedTitleIndex != title else { return }
        jobs.selectTitle(title, settings: settings)
    }

    /// A row clicked in the raw title table (`DiscTitleListView`).
    ///
    /// Routed through the flow rather than straight to `jobs.selectTitle` so
    /// that on a disc the user has overridden, the table **is** the override:
    /// the click updates the answer instead of being snapped back by
    /// `enforceManualTitle` on the next reconcile. Two controls writing the
    /// same fact and arguing about it is this window's oldest failure shape
    /// (#0030, #0167, #0172); here the fix is to let the later one win,
    /// because both of them are the user.
    func selectTitleByHand(_ index: Int?, jobs: JobController, settings: AppSettings) {
        if manualOverride.soleFeature != nil, let index {
            manualOverride.assign(titleIndex: index, toFilm: 1)
        }
        jobs.selectTitle(index, settings: settings)
    }

    /// "Rip this one first" — switches which named film this pass will rip.
    /// The other stays named; nothing is thrown away.
    func makeFeatureActive(_ feature: Int, jobs: JobController, settings: AppSettings) {
        featureSelection.makeActive(feature)
        applyActiveFeature(jobs: jobs, settings: settings)
    }

    /// A keystroke in one feature's search box.
    ///
    /// Clears **that feature's** pick only, for the reason `queryChanged`
    /// clears the single one (#0030's stuck-re-pick bug): a new result set
    /// makes the previous row id meaningless. A film named against another
    /// feature is untouched — it was judged against a different runtime and
    /// nothing about it has changed.
    func featureQueryChanged(_ feature: Int, jobs: JobController, settings: AppSettings) {
        guard let model = featureSearchModels[feature] else { return }
        // #0167 — only a *keystroke* clears the pick.
        //
        // `.onChange(of: search.query)` cannot tell who wrote the text, and
        // the resolution ladder writes it too: `present` sets the term and the
        // change lands after the selection, so the app's own answer was being
        // cleared a moment after it arrived. On the Uncle Buck disc both films
        // were assigned correctly, `choices` went 1 then 1 instead of 1 then
        // 2, and Start stayed at `noFeatureChosen` with no way past it.
        //
        // #0156's `queryIsUserEntered` is exactly this distinction, already
        // made for exactly this reason.
        guard model.queryIsUserEntered else { return }
        if featureSelection.movieID(for: feature) != nil {
            featureSelection.choose(movieID: nil, for: feature)
            applyActiveFeature(jobs: jobs, settings: settings)
        }
        model.queryChanged(apiKey: settings.tmdbAPIKey)
    }

    /// Return / the Search button inside one feature's block.
    func runFeatureSearchNow(_ feature: Int, jobs: JobController, settings: AppSettings) {
        guard let model = featureSearchModels[feature] else { return }
        if featureSelection.movieID(for: feature) != nil {
            featureSelection.choose(movieID: nil, for: feature)
            applyActiveFeature(jobs: jobs, settings: settings)
        }
        model.runSearchNow(apiKey: settings.tmdbAPIKey)
    }

    /// The view model dropped a feature's selection under us (the debounced
    /// search firing), so the flow follows — `followSelectionDrop` for the
    /// per-feature path.
    func followFeatureSelectionDrop(_ feature: Int, jobs: JobController, settings: AppSettings) {
        guard let model = featureSearchModels[feature],
              model.selectedMovie == nil,
              featureSelection.movieID(for: feature) != nil else { return }
        featureSelection.choose(movieID: nil, for: feature)
        applyActiveFeature(jobs: jobs, settings: settings)
    }

    /// Mirror the active feature's film into the flow's single selection, and
    /// settle the disc title that goes with it.
    ///
    /// **This is what keeps the rest of the app singular.** Everything after
    /// the Choose step is built on one film and one title, correctly: the
    /// pipeline encodes one title (#0014) and a `RipRequest` carries one
    /// `MovieMetadata`. Rather than teach the Confirm step, the library
    /// check, the duplicate notice, the archive and `ripRequest` about
    /// features — five places, each a chance to regress the 24-in-26 case —
    /// the film the user is ripping *now* is copied into the state they
    /// already read.
    ///
    /// The seam for ripping the second film later is `featureSelection`: the
    /// other feature's film stays named in `choices` (`waitingFeatures`), so
    /// a queue can start the next job from it without asking again. Today the
    /// user puts the disc back in, and the block for the film they already
    /// named is still on screen.
    ///
    /// A single-feature disc never reaches here.
    private func applyActiveFeature(jobs: JobController, settings: AppSettings) {
        guard featureSelection.isMultiFeature else { return }
        let apiKey = settings.tmdbAPIKey

        guard let feature = featureSelection.active,
              let model = featureSearchModels[feature],
              let movie = model.selectedMovie else {
            select(movieID: nil, jobs: jobs, apiKey: apiKey)
            jobs.selectTitle(nil, settings: settings)
            return
        }

        // `search.select` resolves the movie out of `results`, so the results
        // have to be there before the pick is made.
        search.present(query: model.query, results: model.results)
        select(movieID: movie.id, jobs: jobs, apiKey: apiKey)
        // Nothing is preselected on a multi-feature disc (#0157) — naming the
        // film for one feature is the only statement the user makes about
        // which part of the disc to rip, so it settles the title too.
        jobs.selectTitle(feature, settings: settings)
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
        // #0167 — same rule on the single-film path: the ladder presents its
        // answer through `search.present`, and clearing the selection on that
        // change would drop the film it just found.
        guard search.queryIsUserEntered else { return }
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

    // MARK: - "Already in Plex" (#0143)

    /// What `ConfirmStepView.task(id:)` keys on: the probe re-runs only when
    /// the movie or the library root changes. `nil` with no movie selected —
    /// there is nothing to look up.
    func libraryCheckKey(settings: AppSettings) -> LibraryCheckKey? {
        guard let movie = search.selectedMovie else { return nil }
        return LibraryCheckKey(
            movieID: movie.id,
            moviesPath: settings.plexMoviesPath,
            epoch: libraryEpoch
        )
    }

    /// Bumped when a rip finishes, so the library answer is asked again
    /// rather than reused from before the encode.
    private var libraryEpoch = 0

    // MARK: - Is each film on a multi-feature disc already in Plex? (#0161)

    /// One library answer per feature, keyed by disc title index.
    ///
    /// The singular `libraryCheck` above answers for whichever film is active,
    /// and only once the Confirm step is reached. On a disc holding several
    /// films that is too late and too narrow — the user is naming two films by
    /// hand and cannot see that they already own both. Reported on the Uncle
    /// Buck / The Great Outdoors disc, 2026-09-27, with both already filed as
    /// {tmdb-2616} and {tmdb-2617}.
    private(set) var featureLibraryChecks: [Int: LibraryCheck] = [:]

    /// This feature's answer, as something the block can render.
    func libraryStatus(for feature: Int) -> FeatureLibraryStatus.State {
        FeatureLibraryStatus.state(
            from: featureLibraryChecks[feature] ?? .idle,
            hasFilm: featureSelection.movieID(for: feature) != nil)
    }

    /// Every feature's answer, in disc order — what the all-features notice
    /// is computed from.
    var featureLibraryStates: [FeatureLibraryStatus.State] {
        featureSelection.features.map { libraryStatus(for: $0) }
    }

    /// Generation guard per feature, the same shape `checkLibrary` uses: an
    /// answer that arrives after the user re-picked that block's film is
    /// dropped rather than shown against the wrong movie.
    private var featureLibraryGenerations: [Int: Int] = [:]

    /// Ask the library about one feature's film. Called when a film is named
    /// in a block, so the answer appears beside it rather than two steps later.
    func checkLibraryForFeature(
        _ feature: Int,
        settings: AppSettings,
        probe: @escaping LibraryProbeRunner = LibraryProbe.defaultRunner
    ) async {
        guard let movieID = featureSelection.movieID(for: feature) else {
            featureLibraryChecks[feature] = nil
            return
        }
        let tmdbID = String(movieID)
        let moviesPath = settings.plexMoviesPath

        let generation = (featureLibraryGenerations[feature] ?? 0) + 1
        featureLibraryGenerations[feature] = generation
        featureLibraryChecks[feature] = .checking(tmdbID: tmdbID)

        let lookup = await probe(moviesPath, tmdbID)

        // Still the same film in the same block, and still the newest ask.
        guard featureLibraryGenerations[feature] == generation,
              featureSelection.movieID(for: feature) == movieID else { return }
        featureLibraryChecks[feature] = .done(tmdbID: tmdbID, lookup)
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
        clearWhatBelongedToTheLastDisc(jobs: jobs)
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
            // #0143: "per disc" comes from living here — a disc swap wipes
            // the library answer and its confirmation exactly as it wipes
            // `selectionDisc`.
            clearLibraryCheck()
        }
        // #0176 — the override belongs to one disc, and says so itself.
        // Before `syncFeatures`, which asks it how many films this disc holds.
        // The same disc re-reported (a recovered label, #0152; a re-insertion
        // of the disc it was made for) keeps it; any other disc, or an empty
        // drive, and it goes.
        manualOverride.adopt(disc: jobs.insertedDisc)
        // #0160 — before the search ladder below, which must know whether
        // this disc holds one film or several before it offers the volume
        // label as a term for "the" film.
        syncFeatures(jobs: jobs, apiKey: apiKey)
        seedEdition(jobs: jobs)
        if let settings {
            // #0176 — re-stated here because the scan re-states its own
            // answer: a Scan Again preselects the title the heuristic likes,
            // which is the answer the user has already overruled. First,
            // because everything below derives from the settled title and the
            // user's statement about it outranks the app's.
            enforceManualTitle(jobs: jobs, settings: settings)
            // #0177 — alongside the ladder, not inside it. See
            // `interrogateDisc` for why this is its own pass.
            interrogateDisc(jobs: jobs, settings: settings)
            resolveDiscSearch(jobs: jobs, settings: settings)
            attemptAutoSelect(jobs: jobs, settings: settings)
        }
    }

    // MARK: - Asking the disc several questions (#0177)

    /// What the disc said about itself, once the menus had settled, or `nil`
    /// before the interrogation has answered for the disc now in the drive.
    ///
    /// Observable, and cleared by `clearWhatBelongedToTheLastDisc` with
    /// `featureSelection` and `featureLibraryChecks`, for the same reason they
    /// are: an answer about the disc that just left is not an answer, and the
    /// shape of this step's worst bugs is a screen that still shows one.
    private(set) var discUnderstanding: DiscInterrogation.Understanding?

    /// What `discUnderstanding` licensed, kept beside it so the decision is
    /// not recomputed differently by each reader.
    private(set) var discFindings: DiscFindings.Plan?

    /// The disc the questions have already been put for. One interrogation per
    /// disc, whatever the answers: the model is asked three times and the
    /// answers do not improve on being asked again (`FoundationModelAsk` pins
    /// greedy sampling precisely so they cannot).
    ///
    /// Compared with `SelectionReset.sameDisc`, not `==`. A disc inserted
    /// while the screen is locked arrives unmounted and nameless (#0152) and
    /// has its label recovered part-way through the scan, which changes the
    /// `DiscInsertion` value — and under `!=` that reads as a new disc and
    /// asks all three questions a second time. Identity is the question,
    /// which is #0156's finding at the point where it costs model calls
    /// instead of the user's typing.
    private var interrogationStartedFor: DiscInsertion?

    /// The model seam. `nil` in production, where `DiscInterrogation.run`
    /// defaults to the on-device model; set by tests and by the screenshot
    /// harness, which have no model, no disc and no network.
    ///
    /// `@ObservationIgnored` because nothing renders it and because
    /// `@ObservationTracked` cannot synthesise an `inout` accessor for a
    /// stored `@Sendable` async closure — the observable state it produces is
    /// `discUnderstanding`, which is tracked.
    @ObservationIgnored var interrogationAskingForTesting: DiscInterrogation.Asking?

    /// What this disc calls one of its titles, when it named it.
    ///
    /// Read off `discUnderstanding` rather than copied into a second
    /// dictionary — a copy is a thing that can go stale, and the whole point
    /// of #0172 was a cached answer disagreeing with the state behind it.
    func discLabel(forTitle index: Int) -> String? {
        guard let understanding = discUnderstanding else { return nil }
        return understanding.allFindings.first { $0.titleIndex == index }?.label
    }

    /// Claims the disc made and could not prove, as sentences to show.
    ///
    /// Never empty just because the interrogation found nothing: a disc that
    /// says something unconfirmable is still telling us something, and #0171's
    /// whole cost was an answer that existed and reached nobody.
    var unconfirmedDiscClaims: [String] {
        discFindings.map(DiscFindings.unconfirmedLines) ?? []
    }

    /// Ask the disc what is on it, once its menus have settled.
    ///
    /// ## Why this is its own pass and not a rung
    ///
    /// `resolveEachFeature`'s ladder answers one question — "which film goes
    /// in which search box" — and it only runs at all on a disc
    /// `DiscTitleHeuristic` called `.multipleFeatures`. Two of the three
    /// questions here are about something else entirely: Signs holds one film,
    /// a 58:54 making-of and six named featurettes, so the disc that most
    /// needs the bonus and extras questions is a disc that ladder never
    /// touches. Folding them in would have meant running the ladder on
    /// single-film discs for its side effects, which is how a function ends up
    /// doing two jobs and neither of them visibly.
    ///
    /// It is also gated differently, deliberately. `resolveDiscSearch` refuses
    /// to start once the search box has anything in it, because its job is to
    /// fill that box and it must never type over the user. This has no such
    /// business: a disc whose film the user has already named by hand still
    /// has a making-of worth importing, and refusing to look would be refusing
    /// for a reason that does not apply.
    ///
    /// Nothing is awaited by anything. The answers arrive late, apply through
    /// `applyUnderstanding`'s guards, and a disc swap in the meantime drops
    /// them — the same contract `resolveEachFeature`'s assignment runs under.
    private func interrogateDisc(jobs: JobController, settings: AppSettings) {
        guard let disc = jobs.insertedDisc,
              interrogationStartedFor.map({ !SelectionReset.sameDisc($0, disc) }) ?? true,
              // Settled either way: ready with menus, or known to have none.
              jobs.menuState.hasSettled,
              case .scanned(let scan) = jobs.scanState
        else { return }

        interrogationStartedFor = disc

        let evidence = DiscEvidence.make(
            volumeName: disc.label,
            ocr: jobs.menuState.intelligence?.ocr,
            disc: scan.disc,
            mainFeatureIndex: scan.mainFeatureIndex)

        FlowDiagnostics.note("interrogate: \(evidence.titles.count) title(s), "
            + "\(evidence.menuPages.count) menu page(s), "
            + "\(evidence.allLines.count) line(s), label \"\(evidence.volumeName)\" "
            + "(AI on=\(settings.usesAppleIntelligence), menuState=\(jobs.menuState.diagnosticName))")

        // Two reasons not to ask, and the disc's own arithmetic still runs for
        // both. The log says which one it was, because "the bonus reel was not
        // imported" has several very different causes and last time telling
        // them apart cost a day (#0171).
        //
        // No menu text is a refusal on the merits, not a shortcut. Every one
        // of these questions is a question about what the menus say: a volume
        // label cannot tell anyone which extras a disc offers, and asking
        // anyway spends three model calls to be told so. `MultiTitleInference`
        // draws the same line by returning `nil` without OCR.
        let reasonNotToAsk: String?
        if !settings.usesAppleIntelligence {
            reasonNotToAsk = "Apple Intelligence is off"
        } else if evidence.menuPages.isEmpty {
            reasonNotToAsk = "the disc printed no menu text to read"
        } else {
            reasonNotToAsk = nil
        }
        if let reasonNotToAsk {
            FlowDiagnostics.note("interrogate: \(reasonNotToAsk) — "
                + "no questions asked; runtime nomination only")
            Task { [weak self] in
                await self?.apply(DiscInterrogation.Understanding(),
                                  disc: disc, jobs: jobs, settings: settings)
            }
            return
        }

        let ask = interrogationAskingForTesting ?? DiscInterrogation.onDeviceAsking
        Task { [weak self] in
            let understanding = await DiscInterrogation.run(evidence: evidence, ask: ask)
            guard let self else { return }
            // Still the same disc. An answer about a disc that has left the
            // drive is worse than no answer: it would name titles that are no
            // longer there.
            guard jobs.insertedDisc.map({ SelectionReset.sameDisc($0, disc) }) == true else {
                FlowDiagnostics.note("interrogate: the disc changed — dropping the answers")
                return
            }
            await self.apply(understanding, disc: disc, jobs: jobs, settings: settings)
        }
    }

    /// Record what the disc said, then act on the part of it the disc proved.
    ///
    /// Split out from `interrogateDisc` so the whole of the acting-on is one
    /// function with plain values at its edges: an `Understanding` in, state
    /// changes and log lines out, and `DiscFindings.plan` making every
    /// decision in between.
    private func apply(
        _ understanding: DiscInterrogation.Understanding,
        disc: DiscInsertion,
        jobs: JobController,
        settings: AppSettings
    ) async {
        discUnderstanding = understanding

        // The disc's own arithmetic, independently of anything the model said:
        // titles over the 45-minute feature floor that are too short against
        // the film to be a second feature (#0173/#0174). On Signs that is
        // title 8 at 58:54, 0.553 of the film.
        let feature = jobs.selectedTitleIndex
            ?? Self.featureIndex(of: Self.discOutcome(jobs.scanState))
        let nominated: [Int]
        if case .scanned(let scan) = jobs.scanState, let feature {
            nominated = BonusFeature.candidates(in: scan.disc, featureIndex: feature).map(\.index)
        } else {
            nominated = []
        }

        let plan = DiscFindings.plan(
            from: understanding,
            features: featureSelection.features,
            named: Set(featureSelection.features.filter { featureSelection.movieID(for: $0) != nil }),
            userTyped: Set(featureSelection.features.filter {
                featureSearchModels[$0]?.queryIsUserEntered == true
            }),
            bonusCandidates: nominated)
        discFindings = plan

        FlowDiagnostics.note("interrogate: \(plan.diagnostic) "
            + "(feature title \(feature.map(String.init) ?? "unknown"), "
            + "nominated \(nominated.map(String.init).joined(separator: ",")))")

        // Everything the disc could not prove, said out loud. #0171: an
        // answer nobody can reach is indistinguishable from no answer.
        for line in DiscFindings.unconfirmedLines(plan) {
            FlowDiagnostics.note("interrogate unconfirmed: \(line)")
            jobs.note("  · \(line)")
        }

        for (titleIndex, label) in plan.extraLabels.sorted(by: { $0.key < $1.key }) {
            FlowDiagnostics.note("interrogate extra: title \(titleIndex) is “\(label)”")
            jobs.note("  · title \(titleIndex) is “\(label)”")
        }

        // A bonus feature the menus named and the runtimes nominated gets
        // ticked for import, once. Only once: the interrogation runs a single
        // time per disc, so a user who unticks the box has the last word —
        // which matters, because a 58-minute reel on top of a 106-minute film
        // is most of an hour of someone's evening.
        for item in plan.bonusImports {
            guard !jobs.selectedExtraTitleIndices.contains(item.titleIndex) else {
                FlowDiagnostics.note("interrogate bonus: title \(item.titleIndex) already ticked")
                continue
            }
            jobs.toggleExtra(item.titleIndex)
            let ticked = jobs.selectedExtraTitleIndices.contains(item.titleIndex)
            FlowDiagnostics.note("interrogate bonus: title \(item.titleIndex) “\(item.label)” "
                + "→ \(item.kind.folderName), ticked=\(ticked), "
                + "off by \(item.offBySeconds.map(String.init) ?? "?")s")
            if ticked {
                jobs.note("  · importing “\(item.label)” from title \(item.titleIndex) "
                    + "as \(item.kind.folderName)")
            }
        }
        for titleIndex in plan.nominatedBonusTitles {
            FlowDiagnostics.note("interrogate bonus: title \(titleIndex) is long enough to be "
                + "bonus material but the menus did not name it — left for the user")
        }

        await applyFilmNamings(plan.filmNamings, disc: disc, jobs: jobs, settings: settings)
    }

    /// Fill the search box for each feature the disc both named and placed.
    ///
    /// The label is not believed on its own. It goes to TMDB, and the film
    /// that comes back has to fit the title it would be filed against —
    /// `FeatureMatching.assign` over one feature and one candidate, the same
    /// three-minute tolerance every other rung is held to. Measured errors on
    /// correct pairings run 0.2 to 0.6 minutes, so the gap between right and
    /// wrong here is an order of magnitude.
    ///
    /// Re-checked rather than trusted because the two checks are checks of
    /// different things: `DiscInterrogation.verify` proved the *menu* was
    /// talking about that title, and this proves the *film* is the right
    /// length for it. A menu can print a correct runtime beside a title it
    /// mislabels.
    private func applyFilmNamings(
        _ namings: [DiscFindings.FilmNaming],
        disc: DiscInsertion,
        jobs: JobController,
        settings: AppSettings
    ) async {
        guard !namings.isEmpty else { return }
        let apiKey = settings.tmdbAPIKey
        guard !apiKey.isEmpty else {
            FlowDiagnostics.note("interrogate film: no TMDB key — \(namings.count) naming(s) dropped")
            return
        }

        for naming in namings {
            guard let model = featureSearchModels[naming.feature] else {
                FlowDiagnostics.note("interrogate film: no search model for feature \(naming.feature)")
                continue
            }
            // #0156 — never over the user's own text, and never over a film
            // they already named. Re-checked here and not only in `plan`
            // because the lookup below is a network round trip and they may
            // have typed during it.
            guard !model.queryIsUserEntered else {
                FlowDiagnostics.note("interrogate film: feature \(naming.feature) has the user's own text — leaving it")
                continue
            }
            guard featureSelection.movieID(for: naming.feature) == nil else {
                FlowDiagnostics.note("interrogate film: feature \(naming.feature) already has a film")
                continue
            }
            guard let title = featureTitles().first(where: { $0.index == naming.feature }) else {
                FlowDiagnostics.note("interrogate film: feature \(naming.feature) is not a scanned title")
                continue
            }
            guard let candidate = await Self.candidate(for: naming.label, apiKey: apiKey) else {
                FlowDiagnostics.note("interrogate film: “\(naming.label)” found no film with a runtime")
                continue
            }
            guard let assignment = FeatureMatching.assign(
                features: [title], candidates: [candidate])?.first else {
                FlowDiagnostics.note("interrogate film: “\(naming.label)” resolved to "
                    + "\(candidate.title) at \(candidate.runtimeMinutes) min, which does not fit "
                    + "title \(title.index) — refused")
                continue
            }
            guard jobs.insertedDisc.map({ SelectionReset.sameDisc($0, disc) }) == true else {
                FlowDiagnostics.note("interrogate film: the disc changed — dropping the naming")
                return
            }
            let results = (try? await TMDBClient().searchMovies(
                query: candidate.term, apiKey: apiKey)) ?? []
            model.present(query: candidate.term, results: results)
            selectFeature(movieID: candidate.movieID, feature: naming.feature,
                          jobs: jobs, settings: settings)
            FlowDiagnostics.note("interrogate film: feature \(naming.feature) <- "
                + "\(candidate.title) (id \(candidate.movieID)), "
                + "\(String(format: "%.1f", assignment.errorMinutes)) min from its runtime")
            jobs.note("  · \(candidate.title) (\(candidate.year)) on feature \(naming.feature) "
                + "— the disc's menus named it")
        }
    }

    /// The feature title index a single-film classification settled on, so the
    /// bonus nomination has a film to measure against before the user has
    /// touched anything.
    nonisolated static func featureIndex(of outcome: DiscTitleHeuristic.Outcome?) -> Int? {
        guard case .single(let index, _) = outcome else { return nil }
        return index
    }

    // MARK: - Search prefill from the disc name

    /// The disc-name auto-search: turns the volume name of the disc now in
    /// the drive into a TMDB search term (`DiscNameSearchTerm.derive`) and,
    /// if `SearchPrefill.decide` says to, fills the search field with it and
    /// runs the search immediately — so results are waiting by the time the
    /// user looks at the Choose-movie step, the way typing the title by hand
    /// used to make them wait for it.
    ///
     /// Fill the edition field from the volume label, once per disc.
    ///
    /// Never over anything typed: the label is a guess and the person is not.
    private func seedEdition(jobs: JobController) {
        guard let disc = jobs.insertedDisc, editionSeededFor != disc else { return }
        editionSeededFor = disc
        guard edition.isEmpty else { return }
        edition = DiscEdition.derive(volumeName: disc.label) ?? ""
    }

    /// Wipe everything shown for the previous disc when a different one goes
    /// in — whether or not a film had been chosen for it.
    ///
    /// `SelectionReset` only fires when there *is* a selection, so a disc
    /// whose search found nothing left its term and its "No movies found
    /// for…" panel on screen for the next disc to sit under. Reported on a
    /// swap after Wedding Crashers.
    ///
    /// Keyed on the disc the lookup was last started for, which is set for
    /// every disc that reaches the search step, selection or not. A running
    /// job is left alone: its disc is the one it is reading.
    private func clearWhatBelongedToTheLastDisc(jobs: JobController) {
        guard !jobs.isRunning else { return }
        let current = jobs.insertedDisc
        // Keyed on the disc last *seen*, not on the lookup having started.
        // Keying it on the lookup meant a swap that happened before the menus
        // settled — or with no settings to hand — cleared nothing, and the
        // previous disc's edition was written into the next disc's filename.
        defer { lastSeenDisc = current }
        guard let previous = lastSeenDisc else { return }

        // #0156 — the same physical disc is not a new disc just because we now
        // know more about it.
        //
        // This compared whole `DiscInsertion` values. A disc inserted while the
        // screen is locked arrives unmounted and nameless (#0152), and its
        // label is recovered from libdvdnav part-way through the scan — which
        // changed the value, read as a disc swap, and wiped the search field,
        // the selection and the edition mid-typing. Identity, not equality, is
        // the question, and `sameDisc` is what every other guard already uses.
        if let current, SelectionReset.sameDisc(previous, current) { return }

        // #0153: only another *disc* clears the explanation. The eject itself
        // is a disc change (to nil), and clearing there would wipe the reason
        // in the same instant the screen needs it.
        if current != nil {
            unexplainedEjection = nil
        }

        resolutionStartedFor = nil
        // #0163: the plan was for the disc that just left. A plan outliving
        // its disc would hold the next one in the drive for a film that is no
        // longer in the machine.
        ripPlan = nil
        jobs.discHasMoreWork = false
        // #0160: the features, the films named for them and their search
        // boxes all belonged to the disc that just left.
        featureSelection = FeatureSelection()
        featureSearchModels = [:]
        // #0177: the answers were about the disc that just left. Cleared with
        // `featureSelection` because they are the same kind of thing — what is
        // known about one physical disc — and because a making-of named off
        // Signs' menus has no business sitting on the next disc's titles.
        discUnderstanding = nil
        discFindings = nil
        interrogationStartedFor = nil
        // #0176: so did what the user said that disc held. `ManualOverride`
        // refuses another disc on its own (`adopt`), and this is the second,
        // independent wipe — the pattern #0034 established for a statement
        // whose survival across a swap would file one disc under another's
        // answer.
        manualOverride = ManualOverride()
        editionSeededFor = nil
        edition = ""
        menuTitleTriedFor = nil
        inferenceTriedFor = nil
        autoSelectTriedFor = nil
        recommendedMovieID = nil
        isResolvingDisc = false
        cancelAutoStart()
        search.resetForNewDisc()
        selectedMovieID = nil
        selectionDisc = nil
        movieConfirmed = false
        clearLibraryCheck()
    }

    /// Work out what this disc is, quietly, and only then show anything.
    ///
    /// The ladder needs two or three attempts on an awkward disc — the volume
    /// label, then the title the disc prints on its own menus, then the
    /// on-device model — and the user must not watch it type each guess into
    /// the search box and clear the list again. On `ENEMYATTHEGATES` the
    /// first guess is "Enemyatthegates", which is exactly the wrong thing to
    /// show someone: it looks like a mistake they should start correcting,
    /// and most of them would, halfway through a lookup that was about to
    /// answer correctly on its own.
    ///
    /// So every attempt runs against `probe`, which touches nothing the view
    /// reads, and only the winner is `present`ed. Until then the step says it
    /// is looking the disc up.
    ///
    /// Runs once per disc, after the menu read has settled — that is what
    /// makes the disc's own printed title and its menu text available, and
    /// waiting for it costs nothing because there is nothing on screen to
    /// wait for.
    private func resolveDiscSearch(jobs: JobController, settings: AppSettings) {
        guard let disc = jobs.insertedDisc,
              resolutionStartedFor != disc,
              search.query.isEmpty,
              search.results.isEmpty,
              search.selectedMovie == nil,
              // Settled either way: ready with menus, or known to have none.
              jobs.menuState.hasSettled
        else { return }

        resolutionStartedFor = disc

        // #0160 — a disc with several films on it has no single answer, so
        // there is nothing for this ladder to look up.
        //
        // Every rung here asks "what film is this disc?". On the Uncle Buck /
        // The Great Outdoors disc the first rung derives "Uncle Buck Great
        // Outdoors" from the volume label, TMDB returns nothing, and the user
        // is left looking at a search box that filled itself with something
        // that does not work — which reads as a fault rather than as a
        // question. A blank box per film is honest: the app knows how many
        // films there are and not which is which.
        guard SearchPrefill.mayUseWholeLabel(featureCount: featureSelection.features.count) else {
            // #0167 — a disc with several films gets one search per film,
            // assigned by runtime rather than guessed.
            //
            // The whole label is still never prefilled into a box. What is
            // new is that the label can be *cut up*: UNCLE_BUCK_GREAT_OUTDOORS
            // splits three ways, only one of which has a film behind both
            // halves, and the disc's own runtimes say which film goes on which
            // title. Without this the user had to know that Uncle Buck runs
            // 100 minutes and The Great Outdoors 91 — and on 2026-09-29 they
            // typed them into the wrong boxes, which nothing noticed until the
            // Confirm step refused the disc with "Δ +518s".
            resolveEachFeature(disc: disc, jobs: jobs, settings: settings)
            return
        }

        isResolvingDisc = true

        let label = disc.label
        let apiKey = settings.tmdbAPIKey
        let intelligence = jobs.menuState.intelligence
        let mayInfer = settings.usesAppleIntelligence

        Task { [weak self] in
            defer { self?.isResolvingDisc = false }

            // 1. The volume label, which is right on most discs.
            let fromLabel = DiscNameSearchTerm.derive(volumeName: label)
            if let term = fromLabel {
                await MainActor.run { jobs.note("▶ Identifying the disc — its label reads “\(label)”") }
                let hits = await self?.search.probe(term, apiKey: apiKey) ?? []
                await MainActor.run {
                    jobs.note(hits.isEmpty
                        ? "  · “\(term)” found nothing on TMDB — looking at the disc's menus"
                        : "  · “\(term)” matched \(hits.count) film\(hits.count == 1 ? "" : "s")")
                }
                if !hits.isEmpty {
                    self?.resolvedBy = "label"
                    self?.finishResolution(term: term, results: hits, jobs: jobs, settings: settings, disc: disc)
                    return
                }
            }

            // 2. The title the disc prints on its own menus.
            if let printed = intelligence?.titleText?.text, !printed.isEmpty {
                self?.menuTitleSeen = printed
                await MainActor.run { jobs.note("  · the menus print “\(printed)” — searching for that") }
                let hits = await self?.search.probe(printed, apiKey: apiKey) ?? []
                if !hits.isEmpty {
                    self?.resolvedBy = "menuTitle"
                    self?.finishResolution(term: printed, results: hits, jobs: jobs, settings: settings, disc: disc)
                    return
                }
            }

            // 3. Ask the model what film this is, from everything the disc
            //    printed. Last, because it is the only step that guesses.
            if mayInfer,
               let question = DiscTitleInference.question(volumeName: label, ocr: intelligence?.ocr) {
                await MainActor.run {
                    jobs.note("  · asking this Mac's on-device model to read \(question.lines.count) line\(question.lines.count == 1 ? "" : "s") of menu text")
                }
                let answer = await DiscTitleInference.answer(for: question)
                self?.inferredTitleSeen = answer.title
                await MainActor.run {
                    switch answer {
                    case .title(let t):        jobs.note("  · the model reads it as “\(t)”")
                    case .unavailable(let why): jobs.note("  · the model had no answer — \(why)")
                    }
                }
                FlowDiagnostics.note("resolve: model answered \(answer.title.map { "\"\($0)\"" } ?? "nothing")"
                                     + " for label \(label)")
                if let inferred = answer.title {
                    let hits = await self?.search.probe(inferred, apiKey: apiKey) ?? []
                    if !hits.isEmpty {
                        self?.resolvedBy = "inference"
                        self?.finishResolution(term: inferred, results: hits, jobs: jobs, settings: settings, disc: disc)
                        return
                    }
                }
            }

            // Nothing matched. Show the best term anyway, so the empty state
            // can name what was searched and the user can edit it.
            self?.finishResolution(term: fromLabel ?? "", results: [], jobs: jobs, settings: settings, disc: disc)
        }
    }

    /// Show the winning term and its results, then offer them to the
    /// auto-selector. Abandoned if the disc changed or the user got there
    /// first while the lookup was running.
    private func finishResolution(
        term: String,
        results: [TMDBMovie],
        jobs: JobController,
        settings: AppSettings,
        disc: DiscInsertion
    ) {
        guard jobs.insertedDisc == disc,
              search.selectedMovie == nil,
              search.query.isEmpty || search.query == search.lastSearchedQuery
        else { return }

        search.present(query: term, results: results)
        attemptAutoSelect(jobs: jobs, settings: settings)
    }

    /// Pre-select the result whose runtime matches the disc, when exactly one
    /// does.
    ///
    /// Searching "Enemy at the Gates" returns three films with effectively
    /// the same title; the disc's feature runs 131 minutes and only one of
    /// them does. The evidence is the disc's, not TMDB's ordering and not a
    /// model's, which is why this is allowed to touch something as
    /// consequential as the row that decides the Plex folder and the
    /// `{tmdb-ID}`.
    ///
    /// Still a pre-selection. The list stays open, nothing advances, and
    /// every other result is one click away.
    func attemptAutoSelect(jobs: JobController, settings: AppSettings) {
        // #0160 — never on a disc with several films. The auto-selector
        // matches one search's results against the settled title's runtime;
        // on this disc there is no settled title and no single search, and
        // #0157's whole finding is that picking here is a guess dressed as an
        // answer. Two films 9 to 15 minutes apart are exactly the case where
        // a runtime match feels convincing and names the wrong one.
        guard !featureSelection.isMultiFeature else { return }
        guard settings.autoSelectSearchResult,
              jobs.insertedDisc != nil,
              search.selectedMovie == nil,
              !search.results.isEmpty,
              let searched = search.lastSearchedQuery,
              autoSelectTriedFor != searched,
              let featureSeconds = jobs.featureDurationSeconds
        else {
            FlowDiagnostics.note("""
                autoselect skipped: on=\(settings.autoSelectSearchResult)                 results=\(search.results.count)                 selected=\(search.selectedMovie?.id.description ?? "nil")                 searched=\(search.lastSearchedQuery ?? "nil")                 tried=\(autoSelectTriedFor ?? "nil")                 feature=\(jobs.featureDurationSeconds.map(String.init) ?? "nil")
                """)
            return
        }

        autoSelectTriedFor = searched
        let apiKey = settings.tmdbAPIKey
        let settings = settings

        Task { [weak self] in
            guard let candidates = await self?.search.autoSelectCandidates(
                apiKey: apiKey, limit: MovieAutoSelect.maximumLookups
            ) else { return }
            guard let self,
                  self.search.lastSearchedQuery == searched,
                  self.search.selectedMovie == nil
            else { return }

            var trust = self.termTrust(jobs: jobs, term: searched)
            // #0150 — a disc whose label says nothing can still vouch for an
            // answer, by printing the cast on its own menus. That is evidence
            // from the disc rather than from the guess, which is precisely
            // what the gate wants and what `WILLIS` and `BLUSBRO` could never
            // otherwise supply.
            if trust == .unverified,
               let best = MovieAutoSelect.rank(candidates: candidates,
                                               discDurationSeconds: featureSeconds,
                                               searchTerm: searched).selectedID,
               let cast = self.search.castByID[best] {
                let matched = CastCorroboration.matchingNames(
                    cast: cast, menuText: self.menuTextForCorroboration(jobs: jobs))
                if matched.count >= CastCorroboration.requiredMatches {
                    trust = .labelBacked
                    FlowDiagnostics.note("autoselect: menus name \(matched.joined(separator: ", "))"
                                         + " — the disc corroborates \(best)")
                }
            }
            let decision = MovieAutoSelect.decide(
                candidates: candidates,
                discDurationSeconds: featureSeconds,
                searchTerm: searched,
                trust: trust
            )
            // Show the working. This is the step that separates the app from
            // doing it by hand, and it was invisible — a film simply appeared
            // in the list already chosen, with no way to see that the runtime
            // and the cast had agreed, or that the app had declined to choose.
            let discMinutes = featureSeconds / 60
            jobs.note("▶ Matching against TMDB — the disc's feature runs \(discMinutes) min")
            for c in candidates.prefix(6) {
                let runtime = c.runtimeMinutes.map { "\($0) min" } ?? "no runtime listed"
                let cast = self.search.castByID[c.id]?.prefix(2).joined(separator: ", ")
                jobs.note("  · \(c.title) — \(runtime)" + (cast.map { " · \($0)" } ?? ""))
            }
            switch decision {
            case .select(let id, let reason):
                let title = candidates.first { $0.id == id }?.title ?? "#\(id)"
                jobs.note("✓ Chose \(title) — \(reason)")
            case .abstain(let reason):
                jobs.note("• Not choosing for you — \(reason). Pick one below.")
            }

            FlowDiagnostics.note("""
                autoselect ran: disc=\(featureSeconds)s                 trust=\(trust)                 candidates=\(candidates.map { "\($0.id):\($0.runtimeMinutes.map(String.init) ?? "nil")" }.joined(separator: ","))                 -> \(decision)
                """)
            // Order the list by the disc's own runtime before anything is
            // chosen. TMDB ranks by its popularity, which put a 2021 film of
            // the same name above the 2001 one actually in the drive; a user
            // who disagrees with the pick should still find the plausible
            // rows together at the top rather than hunting for them.
            let order = MovieAutoSelect.ranked(
                candidates: candidates, discDurationSeconds: featureSeconds, searchTerm: searched
            ).map(\.id)
            self.search.reorder(byID: order)
            self.recommendedMovieID = decision.selectedID
            FlowDiagnostics.note("autoselect order: wanted=" + order.map(String.init).joined(separator: ",") + " got=" + self.search.results.map { String($0.id) }.joined(separator: ","))

            guard let id = decision.selectedID else { return }
            self.select(movieID: id, jobs: jobs, apiKey: apiKey, origin: .automatic)
            // Choosing the film is the event automatic ripping waits for, and
            // nothing else re-evaluates on it — the view's onChange handlers
            // watch the disc, the job, the menus and the title, all of which
            // have already happened by now. Without this the policy was asked
            // exactly once, before there was a film to start, and answered
            // "no movie is chosen" forever.
            self.evaluateAutoStart(jobs: jobs, settings: settings)
            FlowDiagnostics.note("autoselect applied: " + String(id)
                + " selectedMovieID=" + (self.selectedMovieID.map(String.init) ?? "nil")
                + " selectedMovie=" + (self.search.selectedMovie?.id.description ?? "nil")
                + " recommended=" + (self.recommendedMovieID.map(String.init) ?? "nil"))
            // A second later, after every onChange this triggered has
            // run: is any of it still true?
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                FlowDiagnostics.note("autoselect after: selectedMovieID="
                    + (self.selectedMovieID.map(String.init) ?? "nil")
                    + " recommended=" + (self.recommendedMovieID.map(String.init) ?? "nil")
                    + " order=" + self.search.results.map { String($0.id) }.joined(separator: ","))
            }
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
        return ripRequest(
            jobs: jobs,
            feature: featureTitleIndex,
            metadata: MovieMetadata(
                from: movie,
                selectionDisc: selectionDisc,
                // Read from the volume label: THE_JACKAL_COLLECTORS_EDITION
                // and friends. `nil` is the ordinary release, which is what
                // an untagged filename means to Plex.
                // The field, not the label: it was seeded from the label
                // and may since have been corrected.
                edition: edition
            )
        )
    }

    /// #0163 — the same request for a film named **explicitly**, rather than
    /// for whatever the mirrored singular selection happens to hold.
    ///
    /// The second film on a disc is never the active one: #0160 mirrors only
    /// the active feature into `search`/`selectedMovieID`, so building the
    /// second job out of those fields would file it under the first film's
    /// name — the #0034 data-loss shape, one disc rather than two. Each
    /// `DiscRipPlan.Entry` already carries its own feature index and its own
    /// `MovieMetadata` (bound to the disc it was chosen for), so the request
    /// is built from the entry and nothing else.
    ///
    /// The extras, the audio tracks and the chapter markers still come off
    /// `JobController`, because they are facts about the **title** and the
    /// caller settles the title (`jobs.selectTitle`) before asking for this.
    func ripRequest(jobs: JobController, feature: Int, metadata: MovieMetadata) -> RipRequest {
        RipRequest(
            metadata: metadata,
            featureTitleIndex: feature,
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

    /// The same decision the Start button is gated on, so nothing can start
    /// automatically that a person could not start by pressing it.
    func startDecision(jobs: JobController) -> StartDecision {
        StartGate.decide(
            hasMovieSelected:    search.selectedMovie != nil,
            isRunning:           jobs.isRunning,
            hasDisc:             jobs.insertedDisc != nil && !jobs.isEjecting,
            discUnavailable:     jobs.discUnavailable,
            scanState:           jobs.scanState,
            selectedTitleIndex:  jobs.selectedTitleIndex,
            selectedAudioTrackNumbers: jobs.selectedAudioTrackNumbers,
            runtimeLookup:       search.runtimeLookup,
            mismatchAcknowledgement: jobs.mismatchAcknowledgement,
            // #0167 — the SAME answer the duplicate notice is drawn from.
            //
            // The gate took the raw check while `duplicateNotice` took the
            // edition-filtered one, so the two could disagree: the gate
            // refused Start as a duplicate while the notice decided this
            // edition was not in the library and drew nothing — leaving the
            // footer saying "Press Replace the Existing File to rip it again"
            // beside no such button. Reported on the Uncle Buck disc,
            // 2026-09-29, whose concatenated volume label seeds an edition
            // that no library file carries.
            //
            // The filtered answer is the correct one for both: a different cut
            // of a film is not a duplicate of it, so it should neither be
            // refused nor need acknowledging.
            libraryCheck:            libraryCheckForThisEdition,
            replaceAcknowledgement:  replaceAcknowledgement,
            // #0160 — on a disc holding several films, "no film chosen" has
            // its own refusal, because the screen has one search box per film
            // and "Choose a movie." does not say which.
            featureChoices:          featureSelection.gateInput(importable: importableFeatureCount),
            // #0176 — the user has said what this disc is, so the runtime
            // cross-check reports and no longer refuses. Nothing else in the
            // gate changes: a missing disc, an unticked audio track and an
            // unacknowledged duplicate are not inferences being contradicted.
            manualOverride:          manualOverride.isActive
        )
    }

    // MARK: - Ripping without being asked

    /// Seconds left before this disc starts on its own, or `nil` when no
    /// countdown is running.
    private(set) var autoStartRemaining: Int?

    /// Discs already started automatically in this session, so a finished
    /// job cannot immediately restart the same disc while it sits in the
    /// drive waiting to be swapped.
    private var autoStartedDiscs: Set<String> = []

    /// A key for "this physical disc", which survives it being re-reported.
    ///
    /// `DiscInsertion` mints a fresh token per insertion event (#0034), so two
    /// insertions are never equal even when every other field matches. That is
    /// right for "is this the disc the selection was made for" and wrong for
    /// "have we already ripped this disc": when Die Hard's eject was refused
    /// the disc was re-reported, the set no longer contained it, and it was
    /// ripped a second time ten seconds after the first finished.
    /// #0152 — never the device node, which is the drive rather than the
    /// disc and which the next disc inherits.
    ///
    /// `label` falls back to the mount URL's last path component, which for
    /// an unmounted disc is **"rdisk4"** — shared by every disc that drive
    /// ever holds. Keying "have we ripped this?" on that makes every
    /// unmounted disc the same disc as the last one, which is the worst
    /// possible direction for this to fail: it silently skips work. Measured
    /// on joe, 2026-09-25, as "this disc has already been ripped" against a
    /// film that was not in the library.
    ///
    /// **This value changes once**, when an unmounted disc's scan recovers
    /// its label: insertion id, then the label. That is deliberate and safe
    /// in a way the old behaviour was not. The window is the ~15 seconds
    /// before the first scan completes, during which nothing has been ripped
    /// or ejected, so nothing has been recorded under the earlier value; and
    /// if anything ever were, the mismatch would fail *open* — offering to
    /// rip again rather than silently refusing to.
    ///
    /// A mounted disc is unaffected: its label is its volume name from the
    /// instant it appears and never changes.
    nonisolated static func discIdentity(_ disc: DiscInsertion) -> String {
        if let discID = disc.discID { return discID }
        if let label = disc.volumeLabel, !label.isEmpty { return label }
        if disc.isMounted { return disc.label }
        return disc.insertionID.uuidString
    }

    private var autoStartTask: Task<Void, Never>?

    /// The countdown's clock, injectable so a test can run it instantly.
    /// A suite that really waited ten seconds a case is a suite that stops
    /// being run.
    @ObservationIgnored
    var autoStartSleeper: @Sendable (Duration) async -> Void = {
        try? await Task.sleep(for: $0)
    }

    /// How many times the countdown has run all the way down and asked for a
    /// rip. Observed by tests; nothing branches on it.
    private(set) var autoStartFiredCount = 0

    /// The last hold reason written to the log, so a reason that is true on
    /// every reconcile is recorded once rather than hundreds of times.
    private var lastAutoStartHold: String?

    /// Stop any countdown. Called by every deliberate user action, because a
    /// person who has started interacting is a person who is present, and
    /// the whole point of the countdown is to be interruptible.
    func cancelAutoStart() {
        autoStartTask?.cancel()
        autoStartTask = nil
        autoStartRemaining = nil
    }

    /// Discs ejected because their film was already in the library, so the
    /// eject is attempted once per disc.
    private var autoEjectedDiscs: Set<String> = []

    /// #0153 — the last automatic eject the app has not yet accounted for, and
    /// the whole input to the `.ejected` screen.
    ///
    /// Stored, unlike almost everything the flow shows, because "why is the
    /// drive empty" is a fact about the past and cannot be derived from a
    /// present state that no longer contains the disc. Cleared as soon as
    /// another disc goes in — see `clearWhatBelongedToTheLastDisc`.
    private(set) var unexplainedEjection: EjectExplanation?

    /// Discs a finished job has already been asked to eject, so the sweep
    /// asks once.
    private var postJobEjectedDiscs: Set<String> = []

    /// How long to keep asking for a disc a finished job left behind. The
    /// dissent that causes this clears on its own, in minutes rather than
    /// seconds, so the window has to outlast it without holding a task open
    /// all evening.
    /// Half an hour of asking, because that is how long the refusal has
    /// actually lasted.
    ///
    /// The Jackal's disc was refused for the full ten minutes of the first
    /// window and only came out around the twenty-five minute mark. The
    /// manual Eject in the menu "works every time" for the same reason: it is
    /// pressed late, once the dissent has cleared. It calls this identical
    /// function — there is no second code path that works.
    ///
    /// Asking costs nothing while the disc sits there. The loop stops the
    /// moment it leaves, a different disc arrives, or a job starts.
    static let postJobEjectAttempts = 60
    static let postJobEjectInterval: Duration = .seconds(30)

    /// The disc a job was last seen running for, so a finished job's outcome
    /// is never attributed to a disc that was swapped in afterwards.
    private var ranJobForDisc: DiscInsertion?

    /// Take the disc out after a job that finished with it still in the
    /// drive.
    ///
    /// The pipeline ejects on success (`DVDPipeline` step 3), and when that
    /// fails it writes a warning into the job log and nothing else happens.
    /// Limitless finished at 02:04 and its disc was still there forty minutes
    /// later — it only came out when an unrelated reconcile re-ran the
    /// library check, found the film now present, and ejected it as a
    /// duplicate. Unattended, the tray opening is the signal to feed the next
    /// disc, so an eject that silently did not happen stops the line.
    ///
    /// This is a retry, not a second mechanism: same `ejectDisc`, asked again
    /// once the job is over and nothing holds the disc.
    private func evaluatePostJobEject(jobs: JobController, settings: AppSettings) {
        // Remember whose job this is while it runs. `lastOutcome` outlives
        // the disc it belongs to, so testing it alone would eject the *next*
        // disc the moment it was inserted after a successful rip.
        if jobs.isRunning {
            ranJobForDisc = jobs.insertedDisc
            return
        }
        // #0163 — "a job finished with this disc still in the drive" is also
        // the moment the next film on it may begin. Settling and starting run
        // before anything considers an eject, so a plan with a film left on it
        // has already put the drive back to work by the time the question is
        // asked (and `isRunning` below answers it a second time).
        advanceRipPlan(jobs: jobs, settings: settings)
        guard let disc = jobs.insertedDisc,
              AutoStartPolicy.shouldEjectAfterJob(
                  isRunning: jobs.isRunning,
                  isEjecting: jobs.isEjecting,
                  currentDisc: disc,
                  ranJobForDisc: ranJobForDisc,
                  alreadyAsked: postJobEjectedDiscs.contains(Self.discIdentity(disc)),
                  outcome: jobs.lastOutcome,
                  // A plan with every film settled — ripped, failed or skipped
                  // — is a disc that is finished with, whatever that plan held.
                  planIncomplete: ripPlan.map { !$0.isFinished } ?? false
              )
        else { return }

        postJobEjectedDiscs.insert(Self.discIdentity(disc))

        // The film is in the library now, and the answer on screen was taken
        // before the encode. Ask again — otherwise a disc that stays in the
        // drive looks like a fresh one and is ripped a second time, which is
        // what happened to Die Hard when its eject was refused.
        libraryEpoch += 1
        clearLibraryCheck()

        FlowDiagnostics.note("post-job eject: the job finished with the disc still in the drive")

        // Keep asking for a few minutes, not once.
        //
        // The refusal seen on this drive is a dissent from loginwindow, and
        // it clears on its own — but it took minutes, not the thirty seconds
        // `DiscEjector`'s own budget covers. A single attempt meant a
        // finished rip left its disc in the drive with one failure recorded
        // against it, and the next disc could not go in.
        //
        // Stops the moment the disc is gone, the drive holds something else,
        // or a new job starts. Nothing here can eject a disc a job is
        // reading, because `ejectDisc` refuses while one is running.
        Task { [weak self] in
            for attempt in 0..<Self.postJobEjectAttempts {
                if attempt > 0 {
                    await self?.autoStartSleeper(Self.postJobEjectInterval)
                }
                guard let self, jobs.insertedDisc == disc, !jobs.isRunning else { return }
                let accepted = await jobs.ejectDisc()
                if jobs.insertedDisc != disc {
                    FlowDiagnostics.note("post-job eject: out after \(attempt + 1) attempt(s)")
                    return
                }
                // `accepted == false` means `EjectPolicy` refused before any
                // eject ran, which is a different failure from the eject
                // being refused by the system — and the two were
                // indistinguishable in the log while The Jackal sat in the
                // drive through ten of these.
                let gate = EjectPolicy.decide(
                    isRunning: jobs.isRunning,
                    isScanning: jobs.scanState == .scanning,
                    isEjecting: jobs.isEjecting,
                    hasDisc: jobs.insertedDisc != nil
                )
                FlowDiagnostics.note(
                    "post-job eject: attempt \(attempt + 1) accepted=\(accepted)"
                    + " gate=\(gate)"
                    + " running=\(jobs.isRunning) scanning=\(jobs.scanState == .scanning)"
                    + " ejecting=\(jobs.isEjecting) unavailable=\(jobs.discUnavailable)"
                )
            }
            FlowDiagnostics.note("post-job eject: gave up; the disc is still in the drive")
        }
    }

    /// Take out a disc whose film is already in the library, so the next one
    /// can go in.
    ///
    /// Unattended, a duplicate is the one outcome that stops the line: the
    /// rip is correctly refused and then the disc waits for a decision nobody
    /// is there to make. Ejecting turns "already have it" into the same
    /// gesture as "finished with it".
    /// Whether this feature's film is known to be in the library already.
    /// A check still running is deliberately not an answer.
    private func isHeldInPlex(_ feature: Int) -> Bool {
        if case .present = libraryStatus(for: feature) { return true }
        return false
    }

    /// #0168 — a disc with nothing to import reports and ejects itself.
    ///
    /// Phase 4 into phase 5 of the flow the user asked for: run the imports
    /// skipping what is already held, show what was done, then take the disc
    /// out. On a disc where *every* film is already in Plex there is nothing
    /// to run, so the report is immediate and so is the eject.
    ///
    /// Before this the disc sat on the Confirm step saying "You already have
    /// every movie on this disc. Take it out when you're ready." — which is
    /// true, and is also the app asking a person to do the one piece of manual
    /// work it exists to remove. Reported 2026-09-29: "Why is it not
    /// automatically ejecting and showing after it is ejected the reason?"
    ///
    /// Safe to do unattended and without `autoStartRipping`, unlike
    /// `shouldEjectDuplicate`: nothing is being encoded, nothing is being
    /// replaced, and no decision is being taken away from anyone. The only
    /// question a person could answer here is "rip it anyway", and the report
    /// names every film so that remains possible on the next insertion.
    private func evaluateNothingToImport(jobs: JobController, settings: AppSettings) {
        guard let disc = jobs.insertedDisc,
              featureSelection.isMultiFeature,
              !jobs.isRunning, !jobs.isEjecting,
              ripPlan == nil,
              !autoEjectedDiscs.contains(Self.discIdentity(disc)),
              // Every film named, so "nothing to import" is a statement about
              // the whole disc rather than about the films named so far.
              featureSelection.runnableFeatures.count == featureSelection.features.count,
              featureSelection.features.allSatisfy { featureSelection.movieID(for: $0) != nil },
              importableFeatureCount == 0,
              // And every one of them is held, not merely unchecked — a check
              // still in flight is not an answer.
              featureSelection.features.allSatisfy(isHeldInPlex)
        else { return }

        autoEjectedDiscs.insert(Self.discIdentity(disc))
        cancelAutoStart()

        // A plan with every film skipped: `isFinished` at once, nothing to
        // run, and the report lists all of them with their reason.
        var built: DiscRipPlan?
        if var plan = DiscRipPlan.make(disc: disc, films: plannedFilms(jobs: jobs)) {
            for entry in plan.entries {
                plan.skip(entry.feature, reason: "already in Plex")
            }
            ripPlan = plan
            built = plan
        }

        // #0153's screen is what the user sees once the tray opens, so the
        // reason has to be recorded before the eject rather than after: the
        // disc going is what makes that screen appear.
        // #0169 — the names come from the PLAN, not from the search models.
        //
        // Each `DiscRipPlan.Entry` carries its own `MovieMetadata`, bound to
        // the feature it was chosen for. Reading the view models instead meant
        // re-reading mirrored state that had already moved on: the first
        // ejected disc reported "Get Hard (2015)" twice, for a disc holding
        // neither film. Same rule `RipRequest` follows — build from the entry
        // and nothing else.
        let films = (built?.entries ?? []).map { "\($0.metadata.title) (\($0.metadata.year))" }
        let explanation = EjectExplanation(cause: .everyFilmAlreadyInPlex, films: films)
        unexplainedEjection = explanation
        jobs.logEvent(explanation.logLine)
        FlowDiagnostics.note("nothing to import: \(films.count) films, all already in Plex — ejecting")
        Task { await jobs.ejectDisc() }
    }

    private func evaluateAutoEject(jobs: JobController, settings: AppSettings) {
        guard let disc = jobs.insertedDisc,
              !autoEjectedDiscs.contains(Self.discIdentity(disc)),
              !jobs.isRunning,
              !jobs.isEjecting,
              AutoStartPolicy.shouldEjectDuplicate(
                  enabled: settings.autoStartRipping,
                  libraryCheck: libraryCheckForThisEdition,
                  selectedMovieID: selectedMovieID,
                  recommendedMovieID: recommendedMovieID,
                  acknowledgedReplace: replaceAcknowledgement != nil,
                  edition: MovieMetadata.normalizedEdition(edition)
              )
        else { return }

        autoEjectedDiscs.insert(Self.discIdentity(disc))
        cancelAutoStart()

        // #0153: the reason, kept rather than discarded.
        //
        // This used to be one `FlowDiagnostics` line and nothing else, so two
        // discs on 2026-09-26 were ejected in total silence. The decision was
        // right both times and still cost the user an evening, because a
        // correct automatic action with no stated reason is indistinguishable
        // from a fault. Name the film and the file it was matched against, so
        // the claim can be checked instead of trusted.
        let existing = Self.firstLibraryFile(in: libraryCheckForThisEdition)
        let explanation = EjectExplanation(
            cause: .alreadyInPlex,
            movie: search.selectedMovie.map { "\($0.title) (\($0.yearText))" },
            existingFile: existing?.name,
            existingSize: EjectExplanation.formatSize(existing?.sizeBytes)
        )
        unexplainedEjection = explanation
        jobs.logEvent(explanation.logLine)

        FlowDiagnostics.note("autoeject: already in the library — " + (search.selectedMovie?.title ?? "?"))
        Task { await jobs.ejectDisc() }
    }

    /// #0153 — the library file the duplicate decision was actually made
    /// against, so the screen can name it. First entry, first file: the check
    /// already refuses to fire unless a matched folder holds a video file.
    private static func firstLibraryFile(in check: LibraryCheck) -> LibraryFile? {
        guard case .done(_, .present(let entries)) = check else { return nil }
        return entries.first(where: { !$0.files.isEmpty })?.files.first
    }

    /// Discs whose identification has already been written, keyed by disc
    /// and chosen film, so a settled answer is recorded once rather than on
    /// every re-evaluation.
    private var identificationRecordedFor: Set<String> = []

    /// Record what this disc was identified as, whether or not it is ripped.
    ///
    /// The archive only ever wrote a naming record when a rip *started*, so
    /// the discs that went wrong left no trace at all. The Secret Life of
    /// Walter Mitty, 2026-09-24, was identified as "The Caretaker", never
    /// ripped, and taken out of the drive — the single most informative
    /// event of the evening, and the archive recorded nothing about it.
    ///
    /// Written at the moment a film is settled on, with `occasion:
    /// "identified"`. If a rip then starts, `JobController` overwrites the
    /// same file with `occasion: "rip"`, so a ripped disc still reads exactly
    /// as it did before and nothing downstream has to know this ran.
    private func recordIdentification(jobs: JobController, settings: AppSettings) {
        guard !settings.menuArchivePath.isEmpty,
              let disc = jobs.insertedDisc,
              let movie = search.selectedMovie
        else { return }
        let key = Self.discIdentity(disc) + "|" + String(movie.id)
        guard identificationRecordedFor.insert(key).inserted else { return }

        let volumeName = disc.label
        let metadata = MovieMetadata(from: movie, selectionDisc: selectionDisc, edition: edition)
        MenuArchive.writeNaming(
            root: settings.menuArchivePath,
            slug: MenuArchive.slug(discID: disc.discID, volumeName: volumeName),
            naming: MenuArchive.naming(
                volumeName: volumeName,
                discID: disc.discID,
                derivedSearchTerm: DiscNameSearchTerm.derive(volumeName: volumeName),
                chosenTitle: metadata.title,
                chosenYear: metadata.year,
                tmdbID: metadata.tmdbID,
                // What the ladder actually used, and what each rung offered —
                // without these a wrong identification cannot be attributed
                // to a rung, which is what made tonight's failure take hours.
                resolvedBy: resolvedBy,
                menuTitle: menuTitleSeen,
                inferredTitle: inferredTitleSeen,
                candidateIDs: search.results.map { String($0.id) },
                recommendedTmdbID: recommendedMovieID.map(String.init),
                selectedTitleIndex: jobs.selectedTitleIndex,
                featureDurationSeconds: jobs.featureDurationSeconds,
                edition: MovieMetadata.normalizedEdition(edition),
                occasion: "identified"
            )
        )
    }

    /// Every line the disc's menus printed, for cast matching.
    ///
    /// The same OCR the inference rung reads, flattened — a name may be its
    /// own observation, or share a line with a menu word, and the match runs
    /// over the joined text either way.
    func menuTextForCorroboration(jobs: JobController) -> [String] {
        guard let ocr = jobs.menuState.intelligence?.ocr else { return [] }
        return ocr.stills.flatMap { $0.observations.map(\.text) }
    }

    /// Whether anything outside the search term corroborates it.
    ///
    /// #0149 — the second half of the Walter Mitty failure. A term from the
    /// disc's own label is corroborated by the disc. A model answer the label
    /// agrees with is corroborated by the label. A term from the menus, or
    /// from a model answer no label can judge, is not corroborated by
    /// anything — however well a candidate then matches it, the match is only
    /// agreement with an unchecked question.
    func termTrust(jobs: JobController, term: String) -> MovieAutoSelect.TermTrust {
        guard let disc = jobs.insertedDisc else { return .unverified }
        let volumeName = disc.label
        switch resolvedBy {
        case "label":
            return .labelBacked
        case "inference":
            // #0151 — three answers, not two. A label that *agrees* is
            // corroboration. A label that *cannot judge* is silence, and
            // silence is not agreement: USUALLB is seven characters and can
            // spell nothing, yet it was reading as label-backed and
            // auto-selecting on the model's word alone — the same reasoning
            // that produced "The Caretaker".
            //
            // Silence falls through to `.unverified`, where the disc can
            // still vouch for the answer by printing the cast on its menus.
            // Same outcome on a disc that names its actors; a click on one
            // that names nothing.
            switch DiscTitleInference.labelVerdict(on: term, volumeName: volumeName) {
            case .agrees:      return .labelBacked
            case .disagrees:   return .unverified
            case .cannotJudge: return .unverified
            }
        default:
            // Menus, or an unresolved ladder. The Willis box set lives here:
            // usually right, never corroborated.
            return .unverified
        }
    }

    /// Begin, continue or abandon the countdown, from whatever just changed.
    func evaluateAutoStart(jobs: JobController, settings: AppSettings) {
        recordIdentification(jobs: jobs, settings: settings)
        evaluatePostJobEject(jobs: jobs, settings: settings)
        evaluateNothingToImport(jobs: jobs, settings: settings)
        evaluateAutoEject(jobs: jobs, settings: settings)
        let decision = AutoStartPolicy.decide(
            enabled: settings.autoStartRipping,
            start: startDecision(jobs: jobs),
            selectedMovieID: selectedMovieID,
            recommendedMovieID: recommendedMovieID,
            alreadyRipped: jobs.insertedDisc.map { autoStartedDiscs.contains(Self.discIdentity($0)) } ?? false
        )
        guard decision.startsCountdown else {
            if autoStartRemaining != nil { cancelAutoStart() }
            // Log the Start gate's own verdict alongside the auto-start
            // hold. They are not the same question — auto-start can decline
            // while Start is perfectly available — and "it won't let me move
            // forward" is unanswerable from the auto-start reason alone.
            let gate = startDecision(jobs: jobs)
            if String(describing: gate) != lastStartDecision {
                lastStartDecision = String(describing: gate)
                FlowDiagnostics.note("start gate: \(gate)")
            }
            if case .hold(let reason) = decision, reason != lastAutoStartHold {
                lastAutoStartHold = reason
                FlowDiagnostics.note("autostart hold: " + reason)
            }
            return
        }
        lastAutoStartHold = nil
        guard autoStartTask == nil, let disc = jobs.insertedDisc else { return }

        // Confirm is where the film, the title and the tracks are shown, so
        // the countdown runs there and not over a list of search results.
        if !movieConfirmed { continueToConfirm() }

        var remaining = max(1, settings.autoStartSeconds)
        autoStartRemaining = remaining
        autoStartTask = Task { [weak self] in
            // The loop counts a local variable and reaching zero is the ONLY
            // way out of it that starts anything.
            //
            // It used to be `while let remaining = self?.autoStartRemaining`,
            // and `cancelAutoStart` sets that to nil — so cancelling the
            // countdown exited the loop and fell straight through into the
            // start call, exactly as though it had finished. Pressing Cancel
            // began the rip. It only ever failed to rip because
            // `JobController.start` refused on its own, which is a failsafe,
            // not the behaviour.
            while remaining > 0 {
                await self?.autoStartSleeper(.seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                // Cancelled from outside while we slept.
                guard self.autoStartRemaining != nil else { return }
                // Re-checked every tick, not only at the start: a disc pulled
                // or a job begun during the countdown must stop it.
                let still = AutoStartPolicy.decide(
                    enabled: settings.autoStartRipping,
                    start: self.startDecision(jobs: jobs),
                    selectedMovieID: self.selectedMovieID,
                    recommendedMovieID: self.recommendedMovieID,
                    alreadyRipped: self.autoStartedDiscs.contains(Self.discIdentity(disc))
                )
                guard still.startsCountdown, jobs.insertedDisc == disc else {
                    self.cancelAutoStart()
                    return
                }
                remaining -= 1
                self.autoStartRemaining = remaining
            }
            guard let self, jobs.insertedDisc == disc else { return }
            self.autoStartRemaining = nil
            self.autoStartTask = nil
            self.autoStartFiredCount += 1
            FlowDiagnostics.note("autostart: starting " + (self.search.selectedMovie?.title ?? "?"))
            // Marked only when the job is actually accepted. Marking on the
            // attempt meant a refusal — a library check that had not finished,
            // say — permanently blocked the disc from ever trying again.
            if self.startRipping(jobs: jobs, settings: settings) {
                self.autoStartedDiscs.insert(Self.discIdentity(disc))
            } else {
                FlowDiagnostics.note("autostart: refused by JobController")
            }
        }
    }

    /// Starts the job, if there is one to start. Returns whatever
    /// `JobController.start` decided, so a refusal is still logged there.
    ///
    /// #0163 — Start now settles the **whole disc**: every film the user has
    /// named becomes an entry in a `DiscRipPlan`, and the first of them is
    /// started. A single-feature disc builds a plan of one and takes the same
    /// path, so the 24-in-26 case has no branch of its own to regress.
    @discardableResult
    func startRipping(jobs: JobController, settings: AppSettings) -> Bool {
        if let disc = jobs.insertedDisc,
           var plan = DiscRipPlan.make(disc: disc, films: plannedFilms(jobs: jobs)) {
            skipFilmsAlreadyInPlex(&plan, jobs: jobs)
            ripPlan = plan
            if plan.isFinished {
                // Every film on the disc is one the user already has. Nothing
                // to run, and — as `plan.isFinished` — nothing holding the
                // disc either, so the ordinary release path applies.
                jobs.note("▶ Nothing to import from this disc — every film on it is already in Plex")
                return false
            }
            return startNextFilm(jobs: jobs, settings: settings)
        }
        // No disc in the drive, or no film named: exactly the state this was
        // in before a plan existed. `ripRequest` refuses, or
        // `JobController.start` logs why it will not run.
        ripPlan = nil
        guard let request = ripRequest(jobs: jobs) else { return false }
        return jobs.start(request: request, settings: settings)
    }

    // MARK: - One disc, several imports (#0163)

    /// What this disc is going to produce, from the moment Start is pressed.
    ///
    /// `nil` until then, and again as soon as another disc goes in. The plan
    /// is the only thing that knows a disc is not finished with, which is why
    /// `shouldEjectAfterJob` has to be told: on Uncle Buck / The Great
    /// Outdoors, 2026-09-27, the user named both films, one was ripped, and
    /// the disc came out with the second still on it.
    private(set) var ripPlan: DiscRipPlan?

    /// Every film the user has named on the disc now in the drive, in disc
    /// order.
    ///
    /// On a single-feature disc this is the one mirrored selection, which is
    /// what `ripRequest` has always built from. On a multi-feature disc it is
    /// **every** feature with a film against it — read from that feature's own
    /// search context, never from the mirrored singular selection, which only
    /// ever holds the active one.
    private func plannedFilms(jobs: JobController) -> [(feature: Int, metadata: MovieMetadata)] {
        guard featureSelection.isMultiFeature else {
            guard let movie = search.selectedMovie, let feature = jobs.selectedTitleIndex else { return [] }
            return [(feature, metadata(for: movie))]
        }
        return featureSelection.features.compactMap { feature in
            // #0167 — a film the user said not to import never enters the
            // plan at all. Distinct from the automatic "already in Plex" skip
            // below: this one is a decision, and it applies even to a film
            // Plex does not have.
            guard !featureSelection.skipped.contains(feature) else { return nil }
            guard let model = featureSearchModels[feature],
                  let movie = model.selectedMovie,
                  // The block's own pick, not a stale `selectedMovie` the view
                  // model has not caught up with — the two are set together by
                  // `selectFeature` and the pick is the statement of intent.
                  featureSelection.movieID(for: feature) == movie.id else { return nil }
            return (feature, metadata(for: movie))
        }
    }

    /// One film, bound to the disc it was chosen for (#0034) and carrying the
    /// edition the disc holds. The edition is a fact about the *disc*, so both
    /// films on a double feature share it.
    private func metadata(for movie: TMDBMovie) -> MovieMetadata {
        MovieMetadata(from: movie, selectionDisc: selectionDisc, edition: edition)
    }

    /// Take out of the plan the films Plex already has.
    ///
    /// A skip, never a failure (`DiscRipPlan.State`): a film the user already
    /// owns and has not asked to replace is not an error, and treating it as
    /// one would keep the disc in the drive waiting for a retry nobody wants.
    /// The answers come from #0161's per-feature checks, which is why this is
    /// inert on a single-feature disc — there `StartGate.duplicateUnacknowledged`
    /// has already refused Start, so nothing reaches here to skip.
    private func skipFilmsAlreadyInPlex(_ plan: inout DiscRipPlan, jobs: JobController) {
        for entry in plan.waiting {
            guard case .present = libraryStatus(for: entry.feature) else { continue }
            // "Replace the Existing File" is a statement about one film. It
            // excuses that film and no other on the same disc.
            if let ack = replaceAcknowledgement,
               ack.movieID == featureSelection.movieID(for: entry.feature) { continue }
            plan.skip(entry.feature, reason: "already in Plex")
            jobs.note("▶ Skipping \(entry.metadata.title) — it is already in Plex")
        }
    }

    /// Start the plan's next film, settling the title it is on first.
    ///
    /// The one place a job is started from a plan, so the bookkeeping that
    /// makes the sequence work — the title, the eject hold, `markRunning` —
    /// happens once rather than at each caller.
    @discardableResult
    private func startNextFilm(jobs: JobController, settings: AppSettings) -> Bool {
        guard var plan = ripPlan, let entry = plan.next else { return false }

        // The audio tracks and the extras belong to the title being ripped,
        // and `selectTitle` recomputes the preselection for it. Only when it
        // is actually a different title: `selectTitle` also clears
        // `mismatchAcknowledgement` (#0032), and re-settling the title the
        // user already confirmed would throw that confirmation away on the
        // ordinary single-film disc, where Start settled it long ago.
        if jobs.selectedTitleIndex != entry.feature {
            jobs.selectTitle(entry.feature, settings: settings)
        }

        // #0163's reported bug, at the point of harm: `DVDPipeline` ejects on
        // success (step 3), so without this the first film's own job takes the
        // second film's disc out of the drive. `waiting` still contains the
        // entry about to start, so "more than one" is "there is another after
        // this".
        jobs.discHasMoreWork = plan.waiting.count > 1

        let request = ripRequest(jobs: jobs, feature: entry.feature, metadata: entry.metadata)
        guard jobs.start(request: request, settings: settings), let jobID = jobs.current?.id else {
            // Refused — and a disc held for work that is not going to happen
            // is a drive that will not open.
            jobs.discHasMoreWork = false
            // Taken out of the plan rather than left `.waiting`. `JobController`
            // refuses for reasons that do not clear on their own (a request
            // that will not resolve against the held scan), and the flow
            // re-evaluates on every observed change — so an entry left waiting
            // would be retried, and its refusal logged, forever, while the
            // disc it is on was never released. `JobController.start` has
            // already said why in the job log.
            plan.skip(entry.feature, reason: "the job could not be started")
            ripPlan = plan
            return false
        }
        plan.markRunning(entry.feature, jobID: jobID)
        ripPlan = plan
        return true
    }

    /// A job has ended with this disc still in the drive: settle its entry
    /// and, if the plan still has a film on it, start that one.
    ///
    /// Settling is keyed on the job id, and `DiscRipPlan.settle` only touches
    /// an entry that is `.running` under it — so this is a no-op the second
    /// and the hundredth time the flow re-evaluates for the same finished
    /// job, and needs no "already seen" set of its own.
    private func advanceRipPlan(jobs: JobController, settings: AppSettings) {
        guard var plan = ripPlan else { return }

        if let job = jobs.history.last {
            plan.settle(jobID: job.id, succeeded: job.outcome?.failure == nil)
        }
        // An "already in Plex" answer that only landed while the last film was
        // encoding still counts: the point of the skip is not to rip over a
        // copy the user has, and when the answer arrived does not change that.
        skipFilmsAlreadyInPlex(&plan, jobs: jobs)
        ripPlan = plan

        guard plan.next != nil,
              let disc = jobs.insertedDisc,
              // The plan is about one disc. A different one in the drive
              // invalidates all of it, the #0034 rule applied to the queue.
              SelectionReset.sameDisc(plan.disc, disc),
              !jobs.isEjecting,
              !jobs.discUnavailable
        else { return }

        FlowDiagnostics.note("rip plan: starting the next film on this disc")
        startNextFilm(jobs: jobs, settings: settings)
    }
}
