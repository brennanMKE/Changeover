import SwiftUI

/// #0142 — step 2: which movie is this disc? Search and results, plus the
/// scan's status as a single line.
///
/// The scan is not a step of its own on purpose: it overlaps with searching,
/// and blocking the window on it for tens of seconds would make the loop
/// slower than it is today. Everything else that used to share this screen —
/// the folder preview, the title table, the tracks, the warnings, the log —
/// belongs to a later step or to the History window.
///
/// #0160 — a disc can hold more than one film, and then this step asks the
/// same question once per film instead of once. The two layouts are separate
/// bodies rather than one body with conditions inside it: the single-feature
/// disc is 24 of the 26 measured captures, and it must behave exactly as it
/// did — including which `onChange` handlers exist at all.
struct ChooseMovieStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    var body: some View {
        if flow.featureSelection.isMultiFeature {
            multipleFeaturesBody
        } else {
            singleFeatureBody
        }
    }

    // MARK: - One film on the disc (the ordinary case)

    private var singleFeatureBody: some View {
        @Bindable var search = flow.search
        return VStack(spacing: 0) {
            if let line = ScanStatusLine.line(for: jobs.scanState) {
                ScanStatusStrip(line: line)
                Divider()
            }

            HStack(spacing: 8) {
                TextField("Search movies…", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { flow.runSearchNow(apiKey: settings.tmdbAPIKey) }
                Button("Search") { flow.runSearchNow(apiKey: settings.tmdbAPIKey) }
                    .disabled(search.query.trimmingCharacters(in: .whitespaces).isEmpty || search.isLoading)
            }
            .padding()

            Divider()
            statusRow

            // #0140: the results fill the flexible body slot and scroll
            // inside it. No `minHeight`, so however many results TMDB
            // returns, the window's minimum stays the action bar's.
            if search.results.isEmpty {
                // A blank panel is not an answer. Seen on ENEMYATTHEGATES:
                // the prefilled term matched nothing, and the screen said so
                // by showing an empty list — indistinguishable from a search
                // nobody had run. Whatever the state, something says what it
                // is and what to do next.
                SearchEmptyState(search: search, isResolvingDisc: flow.isResolvingDisc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List(search.results, selection: selection) { movie in
                MovieRow(movie: movie, posterURL: search.posterURL(for: movie),
                         isRecommended: movie.id == flow.recommendedMovieID,
                         credits: search.creditsByID[movie.id],
                         isChosen: movie.id == flow.selectedMovieID)
                    .tag(movie.id)
                    .contentShape(Rectangle())
                    // Double-click is the shortcut for "this one, go" —
                    // the single click still only selects.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        flow.select(movieID: movie.id, jobs: jobs, apiKey: settings.tmdbAPIKey)
                        flow.continueToConfirm()
                    })
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
            }

            Divider()
            StepActionBar {
                // #0176 — always here, on every disc, whatever the app made
                // of it. A control that appears only once the app has admitted
                // to being unsure is no help on the discs it is sure and wrong
                // about, which are the ones that cost four days.
                ManualOverrideButton()
                Spacer()
                Button("Continue") { flow.continueToConfirm() }
                    .disabled(search.selectedMovie == nil)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    // Tooltips stay in the detail register (§5): a disabled
                    // control still explains itself precisely on hover.
                    .help(search.selectedMovie == nil
                          ? "Choose a movie from the results first."
                          : "Confirm the disc title and tracks for this movie.")
                    .accessibilityHint(search.selectedMovie == nil
                                       ? "Pick a movie from the list first."
                                       : "Next: check the disc, then start.")
            }
        }
        // #0030: debounced as-you-type search. The selection (and the
        // confirmation with it) is cleared by `queryChanged` — see its doc
        // comment for the stuck-re-pick bug that requires it.
        .task(id: search.results.map(\.id)) {
            await search.loadCredits(apiKey: settings.tmdbAPIKey)
        }
        .onChange(of: search.query) { _, _ in flow.queryChanged(apiKey: settings.tmdbAPIKey) }
        // #0030 review: the debounced search clears `selectedMovie` only
        // when it fires, so follow the view model whenever it drops the
        // selection.
        .onChange(of: search.selectedMovie?.id) { _, _ in flow.followSelectionDrop() }
    }

    // MARK: - Several films on the disc (#0160)

    /// One block per film, each with its own runtime, search box and results.
    ///
    /// Nothing is preselected and nothing may be: #0157 established that the
    /// app knows *how many* films a disc holds and not *which is which*, so
    /// every block starts blank — never with the whole volume label, which on
    /// this disc names all of them at once and matches none of them
    /// (`SearchPrefill.mayUseWholeLabel`).
    ///
    /// A `ScrollView`, like every other step body, so the blocks never
    /// contribute to the window's minimum height (#0140).
    /// #0169 — a feature whose film is settled, as one line.
    ///
    /// It says what was matched and offers the two things still worth doing:
    /// change it, or leave it out. No search box, because that question has
    /// been answered.
    @ViewBuilder
    private func namedFeatureRow(feature: Int, position: Int, count: Int) -> some View {
        let movie = flow.featureSearch(feature)?.selectedMovie
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(movie.map { "\($0.title) (\($0.yearText))" } ?? "Movie \(position)")
                    .font(.subheadline.weight(.medium))
                // #0170 — no runtime here. The film is named; its length is
                // not a thing the user does anything with, and printing it
                // beside the title reads as though it still had to be
                // reconciled by hand. It stays in the detail register.
                DetailOnlyText(text: "Movie \(position) of \(count)")
                // #0172 — and if it no longer FITS this title, say so here.
                //
                // The warning existed only inside an open search block, so a
                // settled row that stopped fitting was silent: Get Hard, 100
                // minutes, sat ticked on an 85-minute title with Continue
                // enabled, and the only sign was the Start gate refusing two
                // steps later.
                fitWarning(feature: feature, count: count)
            }
            if case .present = flow.libraryStatus(for: feature) {
                Text("already in Plex")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Change") {
                flow.selectFeature(movieID: nil, feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
            Button(flow.featureSelection.isSkipped(feature) ? "Import this one" : "Don't import this one") {
                flow.setFeatureSkipped(!flow.featureSelection.isSkipped(feature),
                                       feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
            FeatureKindToggle(feature: feature)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// #0182 — a settled bonus feature, as one line: what it is called, which
    /// film it goes with, and which of Plex's extras folders it will land in.
    ///
    /// The folder is named on purpose. It is derived from the name the user
    /// typed (`PlexExtra.kind(forLabel:)`), so saying it is the only way they
    /// can see that "The Making of Signs" became *Behind The Scenes* rather
    /// than *Featurettes* — and the only way a wrong guess is correctable
    /// before the encode rather than afterwards in the Finder.
    @ViewBuilder
    private func bonusFeatureRow(feature: Int, position: Int, count: Int) -> some View {
        let label = flow.featureSelection.bonusLabel(for: feature) ?? ""
        let film = flow.featureSelection.bonusTarget(for: feature)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "paperclip")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text(bonusAttachmentLine(label: label, film: film))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DetailOnlyText(text: "Part \(position) of \(count)")
            }
            Spacer(minLength: 0)
            Button("Rename") {
                // Clearing the name reopens this slot's question, which is the
                // editor the name was typed into. One state, one way in.
                flow.setBonusLabel("", feature: feature, jobs: jobs)
            }
            .buttonStyle(.link)
            .font(.caption)
            Button(flow.featureSelection.isSkipped(feature) ? "Import this one" : "Don't import this one") {
                flow.setFeatureSkipped(!flow.featureSelection.isSkipped(feature),
                                       feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
            FeatureKindToggle(feature: feature)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "Imported with “Signs (2002)”, as Behind The Scenes."
    private func bonusAttachmentLine(label: String, film: Int?) -> String {
        let folder = PlexExtra.kind(forLabel: label).folderName
        guard let film, let name = flow.namedFilmTitle(for: film) else {
            return "A bonus feature — choose which movie it goes with."
        }
        return "Imported with “\(name)”, as \(folder)."
    }

    /// #0172 — "this film does not fit this part of the disc", wherever the
    /// film is shown. Same verdict and same wording the search block uses.
    @ViewBuilder
    private func fitWarning(feature: Int, count: Int) -> some View {
        let verdict = flow.fit(for: feature)
        if case .mismatch(_, let better) = verdict,
           let wording = FeatureFit.wording(
               verdict,
               positionOfBetterFeature: better.flatMap { index in
                   flow.featureSelection.features.firstIndex(of: index).map { $0 + 1 }
               },
               count: count) {
            WordingText(wording: wording, font: .caption, tint: .orange)
        }
    }

    /// #0170 — a feature with no film yet whose turn has not come.
    ///
    /// Says so, rather than borrowing the settled row's checkmark and its
    /// Change link. Nothing has been chosen here, so there is nothing to
    /// change; the only thing worth offering in advance is leaving it out.
    @ViewBuilder
    private func pendingFeatureRow(feature: Int, position: Int, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Movie \(position) of \(count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Next, after this one")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button("Don't import this one") {
                flow.setFeatureSkipped(true, feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
            // #0182 — offered before this slot's turn comes, because on the
            // Signs disc the user can see from the runtimes alone that the
            // second feature is not a second film, and making them answer a
            // TMDB search they know is wrong first would be the app insisting
            // on its own reading.
            FeatureKindToggle(feature: feature)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// #0170 — a feature the user has excluded, named or not.
    @ViewBuilder
    private func excludedFeatureRow(feature: Int, position: Int, count: Int) -> some View {
        let movie = flow.featureSearch(feature)?.selectedMovie
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(movie.map { "\($0.title) (\($0.yearText))" } ?? "Movie \(position) of \(count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Not importing this one")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button("Import this one") {
                flow.setFeatureSkipped(false, feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var continueHelp: String {
        if !flow.featureSelection.hasRunnableFilm {
            return "Name at least one of this disc's movies first."
        }
        // #0176 — a misfit on a disc the user set up by hand is a warning on
        // the row, not a reason Continue is dead, so the tooltip must not say
        // it is. A tooltip explaining a disabled button that is in fact
        // enabled is how this step spent four days contradicting itself.
        if !flow.manualOverride.isActive,
           let feature = flow.misfittingFeatures.first,
           let position = flow.featureSelection.features.firstIndex(of: feature).map({ $0 + 1 }) {
            return "Movie \(position) is not the right length for that part of the disc — fix it first."
        }
        return "Next: check the disc, then start."
    }

    /// #0172 — the pick that was refused because that film is already on
    /// another feature. Shown where the user clicked, in their words: a
    /// refusal nobody can see is indistinguishable from a click that did
    /// nothing, which is how the silent version of this rule sent a user
    /// round the same loop.
    @ViewBuilder
    private var duplicateFilmNotice: some View {
        if let rejection = flow.featureSelection.alreadyChosenElsewhere,
           let position = flow.featureSelection.features
               .firstIndex(of: rejection.heldBy).map({ $0 + 1 }) {
            let name = flow.featureSearch(rejection.heldBy)?.selectedMovie
                .map { "\($0.title) (\($0.yearText))" } ?? "That film"
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                WordingText(
                    wording: Wording(
                        plain: "\(name) is already Movie \(position) of this disc. "
                            + "Two features are two different films — pick a different one, "
                            + "or change Movie \(position) first.",
                        detail: "Refused: movie id \(rejection.movieID) is already assigned to "
                            + "feature \(rejection.heldBy)."),
                    font: .caption,
                    tint: .orange)
                Spacer(minLength: 0)
                Button("OK") { flow.acknowledgeFeatureRejection() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
    }

    private var multipleFeaturesBody: some View {
        VStack(spacing: 0) {
            duplicateFilmNotice
            if let line = ScanStatusLine.line(for: jobs.scanState) {
                ScanStatusStrip(line: line)
                Divider()
            }

            // #0161 — said once, and only when it is true of every film on the
            // disc. At that point the useful thing is to take the disc out,
            // but the app says so rather than doing it: the duplicate
            // auto-eject stays suppressed here, because ejecting a disc whose
            // *other* film the user does not have is the worse mistake.
            if let notice = FeatureLibraryStatus.everyFeatureNotice(flow.featureLibraryStates) {
                WordingText(
                    wording: Wording(
                        plain: FeatureLibraryStatus.plainEveryFeatureNotice(flow.featureLibraryStates) ?? notice,
                        detail: notice),
                    font: .subheadline,
                    tint: .orange
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let features = flow.featureSelection.features
                    // #0169 — one film at a time.
                    //
                    // Every feature used to get its own open search box at
                    // once, headed only by a runtime: "Movie 1 of 2 · 1h 30m"
                    // and "Movie 2 of 2 · 1h 40m". That asks the user to know
                    // how long each film runs in order to know which box to
                    // type in, which is the app's job and not theirs.
                    // Reported 2026-09-29: "I do not understand why it lists
                    // two search fields with durations like I am supposed to
                    // know how long both films are and pick which one."
                    //
                    // So: the first feature with no film named gets the search
                    // box, and the ones already named collapse to a line each.
                    // Ask one question, take one answer, move on — and the
                    // runtime is then a fact the app uses, not a riddle.
                    ForEach(Array(features.enumerated()), id: \.element) { position, feature in
                        if let search = flow.featureSearch(feature) {
                            // #0170 — four states, not two. Treating every
                            // feature but the first unnamed one as settled
                            // drew feature 2 with a checkmark and the
                            // placeholder name "Movie 2", while the Start gate
                            // was saying `noFeatureChosen` about the same disc.
                            switch flow.featureSelection.question(for: feature) {
                            case .ask:
                                // #0182 — the same slot, two different
                                // questions. A film's is "which film?", and
                                // TMDB answers it. A bonus feature's is "what
                                // is it called, and which film does it go
                                // with?", and nothing but the person holding
                                // the box can.
                                if flow.featureSelection.isBonusFeature(feature) {
                                    BonusFeatureBlock(
                                        feature: feature,
                                        position: position + 1,
                                        count: features.count,
                                        title: discTitle(feature)
                                    )
                                } else {
                                    FeatureSearchBlock(
                                        feature: feature,
                                        position: position + 1,
                                        count: features.count,
                                        title: discTitle(feature),
                                        search: search
                                    )
                                }
                            case .named:
                                if flow.featureSelection.isBonusFeature(feature) {
                                    bonusFeatureRow(feature: feature,
                                                    position: position + 1,
                                                    count: features.count)
                                } else {
                                    namedFeatureRow(feature: feature,
                                                    position: position + 1,
                                                    count: features.count)
                                }
                            case .waiting:
                                pendingFeatureRow(feature: feature,
                                                  position: position + 1,
                                                  count: features.count)
                            case .excluded:
                                excludedFeatureRow(feature: feature,
                                                   position: position + 1,
                                                   count: features.count)
                            }
                            if feature != features.last { Divider() }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            StepActionBar {
                // #0176 — the same control on the multi-feature layout, where
                // the misread disc is most often the problem: here it is also
                // how the user says "this disc holds one film, not two".
                ManualOverrideButton()
                // What Continue will actually do.
                //
                // #0170 — this used to read "Ripping X first — put the disc
                // back in for the other afterwards", which stopped being
                // true when `DiscRipPlan` landed (#0162): the plan holds every
                // named film and `startNextFilm` begins the next one as soon
                // as the previous job settles, on the same disc, with nobody
                // touching the drive. Telling the user to come back and
                // re-insert it was asking for a step the app had already
                // taken over.
                if let summary = ChooseSummary.line(
                    films: flow.runnableFilmTitles,
                    skipped: flow.skippedFilmTitles,
                    // #0182 — a bonus feature is not a film and gets no line
                    // of its own in the list of films, but it IS something
                    // Continue is about to import, so it is said.
                    bonusFeatures: flow.importedBonusFeatureNames) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                // #0172 — a film that fails its own runtime check does not
                // go through to Confirm. Start refuses it there anyway; this
                // refuses it where the mistake was made and where fixing it
                // is one click.
                Button("Continue") { flow.continueToConfirm() }
                    .disabled(!flow.mayContinueFromChoose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help(continueHelp)
                    .accessibilityHint(continueHelp)
            }
        }
    }

    /// The scanned title behind one feature index, for its runtime.
    private func discTitle(_ index: Int) -> DiscTitle? {
        guard case .scanned(let result) = jobs.scanState else { return nil }
        return result.disc.titles.first { $0.index == index }
    }

    /// The selection binding goes through the flow controller, which binds
    /// the pick to the disc in the drive (#0034) and starts #0032's runtime
    /// lookup.
    private var selection: Binding<Int?> {
        Binding(
            get: { flow.selectedMovieID },
            set: { flow.select(movieID: $0, jobs: jobs, apiKey: settings.tmdbAPIKey) }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        if flow.search.isLoading {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .frame(maxWidth: .infinity)
        } else if let error = flow.search.errorWording {
            WordingText(wording: error, font: .subheadline, tint: .red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - One film's block on a multi-feature disc (#0160)

/// One feature on a disc that holds several: its runtime, its own search box,
/// its own results, and the film the user named for it.
///
/// Every piece of state here belongs to this feature alone — including
/// `queryIsUserEntered` (#0156), so text typed against one film is never
/// cleared by anything that happens to another.
private struct FeatureSearchBlock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    /// The disc title index this block is about.
    let feature: Int
    /// Which of the disc's films this is, and how many there are — the
    /// heading's "Movie 1 of 2".
    let position: Int
    let count: Int
    /// The scanned title, for its runtime. `nil` only if the scan moved on
    /// under us, in which case the heading simply omits the runtime.
    let title: DiscTitle?
    /// This feature's own search context.
    let search: MovieSearchViewModel

    /// #0181 — every result is shown.
    ///
    /// This used to stop at six and say "…and N more. Add the year to narrow
    /// it down." The premise was that the step stacks two or three search
    /// blocks and a full list in each would push the action bar off screen.
    /// #0169 ended that: one feature is asked about at a time and the rest
    /// collapse to a line each, so there is one list and the body is already
    /// in a `ScrollView`.
    ///
    /// The advice was worse than the cap. Reported 2026-10-01 on the Signs
    /// disc: the user searched "Signs", was told to add the year, did not know
    /// it, guessed 2009, and got "No movies found" — the film is 2002. TMDB
    /// returns under thirty results for an ordinary title and ranks them by
    /// popularity, so the answer is almost always near the top and scrolling
    /// costs nothing. Asking someone for a fact they came here to look up is
    /// the app handing back its own work, the same fault as #0170's runtimes.

    var body: some View {
        @Bindable var search = search
        return VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 8) {
                TextField("Search movies…", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { flow.runFeatureSearchNow(feature, jobs: jobs, settings: settings) }
                Button("Search") { flow.runFeatureSearchNow(feature, jobs: jobs, settings: settings) }
                    .disabled(search.query.trimmingCharacters(in: .whitespaces).isEmpty || search.isLoading)
            }
            fitWarning
            results
        }
        .padding()
        // #0161 — ask the library as soon as this block has a film, so the
        // answer lands beside the name instead of two steps later on Confirm.
        .task(id: libraryTaskKey) {
            await flow.checkLibraryForFeature(feature, settings: settings)
        }
        .task(id: search.results.map(\.id)) {
            await search.loadCredits(apiKey: settings.tmdbAPIKey)
        }
        .onChange(of: search.query) { _, _ in
            flow.featureQueryChanged(feature, jobs: jobs, settings: settings)
        }
        .onChange(of: search.selectedMovie?.id) { _, _ in
            flow.followFeatureSelectionDrop(feature, jobs: jobs, settings: settings)
        }
    }

    /// Re-keyed on the chosen film, so naming one runs the probe and
    /// re-picking runs it again — the `.task(id:)` shape the Confirm step
    /// already uses for the singular check.
    private var libraryTaskKey: String {
        "\(feature)-\(flow.featureSelection.movieID(for: feature).map(String.init) ?? "none")"
    }

    private var isChosen: Bool { flow.featureSelection.movieID(for: feature) != nil }
    private var isSkippedHere: Bool { flow.featureSelection.isSkipped(feature) }

    /// #0167 — the film named here does not match this block's runtime.
    /// Caught where the mistake was made rather than five steps later at the
    /// Confirm step, which reported it as "Δ +518s" against a title number.
    @ViewBuilder
    private var fitWarning: some View {
        let verdict = flow.fit(for: feature)
        if case .mismatch(_, let better) = verdict,
           let wording = FeatureFit.wording(
               verdict,
               positionOfBetterFeature: better.flatMap { index in
                   flow.featureSelection.features.firstIndex(of: index).map { $0 + 1 }
               },
               count: count) {
            WordingText(wording: wording, font: .caption, tint: .orange)
        }
    }
    private var isActive: Bool { flow.featureSelection.active == feature }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WordingText(
                wording: DiscTitleFormatting.featureBlockWording(
                    position: position, of: count, title: title),
                font: .headline
            )
            Spacer(minLength: 8)
            // #0161 — this film's own library answer, beside this film's own
            // name. Before this the check ran only on the Confirm step and
            // only for the active film, so a disc whose *both* films were
            // already in Plex said nothing at all.
            if let badge = FeatureLibraryStatus.badge(for: flow.libraryStatus(for: feature)) {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // #0182 — "this is not a film at all", offered in the header of
            // the question itself. The user is looking at a search box that
            // will never find "The Making of Signs" on TMDB, which is exactly
            // the moment the other answer is worth having.
            FeatureKindToggle(feature: feature)
            // #0167 — the way out of a film you do not want. Shown once a
            // film is named, because before that there is nothing to exclude.
            if isChosen {
                Button(isSkippedHere ? "Import this one" : "Don't import this one") {
                    flow.setFeatureSkipped(!isSkippedHere, feature: feature,
                                           jobs: jobs, settings: settings)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if isChosen, !isSkippedHere {
                if isActive {
                    Text("Ripping this one")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else {
                    // Both films are named; this says which to do first.
                    // Nothing is thrown away either way — the other one stays
                    // named for the pass after this.
                    Button("Rip this one first") {
                        flow.makeFeatureActive(feature, jobs: jobs, settings: settings)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let chosen = search.selectedMovie {
            HStack(alignment: .top, spacing: 8) {
                MovieRow(movie: chosen, posterURL: search.posterURL(for: chosen),
                         credits: search.creditsByID[chosen.id], isChosen: true)
                Spacer(minLength: 8)
                Button("Change") {
                    flow.selectFeature(movieID: nil, feature: feature, jobs: jobs, settings: settings)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else if search.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let wording = search.errorWording {
            WordingText(wording: wording, font: .caption, tint: .red)
        } else if search.results.isEmpty {
            // The same rule as the single-feature empty state: a blank
            // rectangle is not an answer, and on this disc the box is blank
            // *on purpose*, so it has to say so.
            Text(emptyLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(search.results) { movie in
                    Button {
                        flow.selectFeature(movieID: movie.id, feature: feature,
                                           jobs: jobs, settings: settings)
                    } label: {
                        MovieRow(movie: movie, posterURL: search.posterURL(for: movie),
                                 credits: search.creditsByID[movie.id], isChosen: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyLine: String {
        if let searched = search.lastSearchedQuery, !searched.isEmpty {
            return "No movies found for “\(searched)”. Try a different spelling."
        }
        return "Type this movie's name and press Search."
    }
}

// MARK: - What a feature IS (#0182)

/// The one control that says whether a feature-length stretch of the disc is a
/// film or a bonus feature, wherever that slot is drawn.
///
/// One view rather than a line in each of the four row states, because the two
/// things this ticket is judged on are that the choice is **obvious** and that
/// it is **reversible** — and a control whose wording or availability differed
/// between the asked row and the settled row would be neither. It is the same
/// link in both directions: the slot's kind decides which sentence it shows.
///
/// Disabled, not hidden, when the disc has no named film yet. A bonus feature
/// is filed inside a film's own folder, so there is genuinely nowhere to put
/// one until a film is named — and #0053's rule is that a control the user
/// cannot use still has to say why, because a missing control reads as an app
/// that cannot do the thing at all. That is the whole of the complaint this
/// ticket answers: "the current workflow does not support doing this".
private struct FeatureKindToggle: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    let feature: Int

    var body: some View {
        if flow.featureSelection.isBonusFeature(feature) {
            Button("It's a movie") {
                flow.markFeatureAsFilm(feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("Import this as a movie of its own, in its own folder.")
        } else {
            let target = flow.featureSelection.bonusTargets.first
            Button("It's a bonus feature") {
                guard let target else { return }
                flow.markFeatureAsBonus(feature, of: target, label: "",
                                        jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(target == nil)
            .help(target == nil
                  ? "Name one of this disc's movies first — a bonus feature is imported into the movie's own folder."
                  : "Import this with one of this disc's movies instead, as an extra.")
        }
    }
}

/// #0182 — the question asked about a slot the user has called a bonus
/// feature: what is it called, and which film does it go with?
///
/// Deliberately **not** a search box. A making-of is not in a movie database
/// and has no year, no cast and no id; what it has is the name printed on the
/// disc's own bonus menu. Offering TMDB here would be the mistake #0181 just
/// fixed in the other direction — asking someone for a fact the app should
/// already have — in reverse: asking a database for a fact only the disc has.
///
/// The name is bound straight through to `FeatureSelection`, with no local
/// `@State` copy. That is not an economy: a second copy of the name is a
/// second writer of it, and #0172 is this window's standing proof of what two
/// writers of one fact cost.
private struct BonusFeatureBlock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    let feature: Int
    let position: Int
    let count: Int
    /// The scanned title, for its runtime — the one piece of evidence that
    /// makes "this is nearly an hour long" believable as a bonus feature
    /// rather than as a trailer.
    let title: DiscTitle?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TextField("What is this called? e.g. The Making of Signs", text: name)
                .textFieldStyle(.roundedBorder)
            attachment
            destinationLine
        }
        .padding()
    }

    /// Bound straight to the single source of truth.
    private var name: Binding<String> {
        Binding(
            get: { flow.featureSelection.bonusLabel(for: feature) ?? "" },
            set: { flow.setBonusLabel($0, feature: feature, jobs: jobs) }
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WordingText(
                wording: DiscTitleFormatting.featureBlockWording(
                    position: position, of: count, title: title),
                font: .headline
            )
            Spacer(minLength: 8)
            FeatureKindToggle(feature: feature)
            Button("Don't import this one") {
                flow.setFeatureSkipped(true, feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    /// Which film it goes with. A picker only when there is a choice to make:
    /// on the disc this ticket is about there is exactly one film, and a
    /// one-item picker is a question with one answer.
    @ViewBuilder
    private var attachment: some View {
        let targets = flow.featureSelection.bonusTargets
        if targets.count > 1 {
            Picker("Goes with", selection: targetBinding) {
                ForEach(targets, id: \.self) { film in
                    Text(flow.namedFilmTitle(for: film) ?? "Movie \(positionOf(film))").tag(film)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
        } else if let film = targets.first, let movie = flow.namedFilmTitle(for: film) {
            Text("Goes with “\(movie)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // Reachable only by the fallback branch of `featureBeingAsked`:
            // every slot on the disc is unanswered and this one happens to be
            // first. Say what is missing rather than drawing a dead picker.
            Text("Name one of this disc's movies first — a bonus feature is imported into the movie's own folder.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Where it will actually land, from the name as it is typed. The folder
    /// is Plex's own vocabulary and the only thing that makes the file show up
    /// as part of the film, so it is shown rather than inferred silently.
    @ViewBuilder
    private var destinationLine: some View {
        let typed = flow.featureSelection.bonusLabel(for: feature) ?? ""
        if flow.featureSelection.hasUsableBonusLabel(feature) {
            Text("Filed as \(PlexExtra.kind(forLabel: typed).folderName).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Give it the name the disc's own menu uses — that is what Plex will show.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var targetBinding: Binding<Int> {
        Binding(
            get: {
                flow.featureSelection.bonusTarget(for: feature)
                    ?? flow.featureSelection.bonusTargets.first
                    ?? feature
            },
            set: { flow.setBonusTarget($0, feature: feature, jobs: jobs) }
        )
    }

    private func positionOf(_ film: Int) -> Int {
        (flow.featureSelection.features.firstIndex(of: film) ?? 0) + 1
    }
}

// MARK: - Scan status strip

/// One `HStack` rendering `ScanStatusLine.Line`. The sentence, the tone and
/// which button (if any) to show are all decided by the pure function; this
/// only performs the action.
struct ScanStatusStrip: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs

    let line: ScanStatusLine.Line

    var body: some View {
        HStack(spacing: 8) {
            if line.action == .cancelScan {
                ProgressView().controlSize(.small)
            }
            // The plain sentence by default; the verbatim one (HandBrake's
            // exit status, the title count) beneath it with Details open.
            WordingText(
                wording: line.wording,
                font: .caption,
                tint: line.tone == .failure ? Color.red : Color.secondary
            )
            Spacer(minLength: 8)
            switch line.action {
            case .none:
                EmptyView()
            case .cancelScan:
                // #0051: a hung scan has to have a way out that isn't the
                // 15-minute watchdog.
                Button("Cancel Scan") { jobs.cancelScan() }
                    .buttonStyle(.link)
                    .font(.caption)
            case .rescan:
                Button("Scan Again") { jobs.startScan(settings: settings) }
                    .buttonStyle(.link)
                    .font(.caption)
                    // #0045/#0049: `startScan` refuses a disc being ejected
                    // or one whose mount path no longer resolves.
                    .disabled(jobs.isEjecting || jobs.discUnavailable)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Movie row

struct MovieRow: View {
    @Environment(AppSettings.self) private var settings

    let movie:     TMDBMovie
    let posterURL: URL?
    /// The row the disc's own runtime identified. Marked as well as
    /// pre-selected, because a selection highlight alone reads as "this is
    /// where the cursor is" rather than "this is the one that matches".
    var isRecommended = false
    /// "George Clooney, Violante Placido · dir. Anton Corbijn", or `nil`
    /// while it is still being fetched or where TMDB knows nobody. A poster
    /// thumbnail is often too small to recognise and two films of the same
    /// name cannot be told apart by title — a cast list settles it at a
    /// glance.
    let credits: String?
    /// Whether this is the chosen row.
    ///
    /// Drawn by the row rather than left to the List, because an unfocused
    /// List draws its selection in a grey faint enough to read as nothing at
    /// all — and this is a menu bar app whose window is usually not key, so
    /// unfocused is the normal case. A pre-selection nobody can see is the
    /// same as no pre-selection.
    var isChosen = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isChosen ? Color.accentColor : Color.secondary.opacity(0.35))
                .accessibilityHidden(true)
            posterThumb
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(movie.title)
                        .font(.headline)
                        .lineLimit(2)
                    if isRecommended {
                        Text("Best match")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Best match — this film's length matches the disc")
                    }
                }
                // The year is what tells two films of the same name apart on
                // screen; the database id is what tells Plex. Only one of
                // those is the person's problem, so the id is detail.
                Text(settings.showsDetails
                     ? "\(movie.yearText)  ·  tmdb-\(String(movie.id))"
                     : movie.yearText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let credits {
                    Text(credits)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var posterThumb: some View {
        AsyncImage(url: posterURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 60)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.separatorColor).opacity(0.4))
                    .frame(width: 40, height: 60)
                    .overlay(
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 40, height: 60)
    }
}

/// What the results area says when it has no results.
///
/// Four different situations reach an empty list, and before this they were
/// one blank rectangle: searching, a search that failed, a search that found
/// nothing, and a search nobody has run. The disc that surfaced it,
/// `ENEMYATTHEGATES`, produces the third — its volume label prefills a term
/// that matches no film — and the app's entire response was empty space.
private struct SearchEmptyState: View {
    let search: MovieSearchViewModel
    /// The disc is being looked up: its label tried, its menus read, and the
    /// model asked if those failed. Shown instead of a half-finished guess,
    /// because a guess in the box is something the user starts correcting.
    var isResolvingDisc = false

    var body: some View {
        VStack(spacing: 8) {
            if isResolvingDisc {
                ProgressView()
                Text("Looking up this disc…")
                    .foregroundStyle(.secondary)
            } else if search.isLoading {
                ProgressView()
                Text("Searching…")
                    .foregroundStyle(.secondary)
            } else if let wording = search.errorWording {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                WordingText(wording: wording)
                    .multilineTextAlignment(.center)
            } else if let searched = search.lastSearchedQuery, !searched.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No movies found for “\(searched)”.")
                    .font(.headline)
                // The disc's own label is often the title with the spaces
                // taken out, so this is the actionable thing to try — and it
                // is what the user has to do by hand until
                // docs/disc-name-inference.md is built.
                Text("The disc's name may be missing spaces, or be spelled differently. Try editing the search above.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Type the movie's name and press Search.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
    }
}
