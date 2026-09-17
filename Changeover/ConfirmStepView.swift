import SwiftUI

/// #0061 — step 3: everything that is still a decision for *this* disc, with
/// the movie already chosen and carried forward as a compact card.
///
/// The disc section is `DiscTitleListView` and `TrackSelectionView`
/// unchanged: their scanning / scan-failed / no-titles (#0039) / Play All
/// (#0025) / `.none` branches *are* this step's disc panel, and #0032's
/// mismatch confirmation and #0027's audio picker live there. What is gone is
/// the search field, the results and the log.
struct ConfirmStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    var body: some View {
        VStack(spacing: 0) {
            // #0140: one general scroll region with no minimum height. The
            // nested scrollers left inside it are the ones that cannot be
            // anything else — the title table, with its explicit height cap.
            // The audio checkboxes lay out at natural height so there is
            // always a wide area where a trackpad gesture reaches this
            // scroll view rather than an inner one.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    movieCard
                    duplicateNotice
                    Divider()
                    DiscTitleListView(jobs: jobs, settings: settings, runtimeLookup: flow.search.runtimeLookup)
                    trackSelectionSection
                }
            }

            Divider()
            actionBar
        }
        // #0062 — the check starts the moment this step appears for a movie,
        // and re-fires only when the movie or the library root changes.
        // `continueToConfirm`, `adjustAndRetry` and a new movie after "Change
        // movie" all arrive here, so the answer is on screen seconds after
        // the film is chosen — tens of minutes before an encode would have
        // found out.
        .task(id: flow.libraryCheckKey(settings: settings)) {
            guard flow.libraryCheckKey(settings: settings) != nil else { return }
            await flow.checkLibrary(settings: settings)
        }
    }

    // MARK: - Already in Plex (#0062)

    @ViewBuilder
    private var duplicateNotice: some View {
        if let movie = flow.search.selectedMovie,
           let notice = DuplicatePresentation.notice(
               check: flow.libraryCheck,
               acknowledgement: flow.replaceAcknowledgement,
               metadata: MovieMetadata(from: movie),
               now: Date()
           ) {
            DuplicateNoticeView(
                notice: notice,
                onReplace: { flow.acknowledgeReplace() },
                onRecheck: { Task { await flow.checkLibrary(settings: settings) } }
            )
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }

    // MARK: - The movie, carried forward

    @ViewBuilder
    private var movieCard: some View {
        if let movie = flow.search.selectedMovie {
            let meta = MovieMetadata(from: movie)
            HStack(alignment: .top, spacing: 10) {
                poster(for: movie)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(movie.title) (\(movie.yearText))")
                        .font(.headline)
                    Text(meta.folderName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(meta.fileName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // #0032's only caption: never reads like a pass when the
                    // cross-check did not run.
                    if let caption = DiscTitleFormatting.runtimeCaption(flow.search.runtimeLookup) {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Change movie") { flow.changeMovie() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func poster(for movie: TMDBMovie) -> some View {
        AsyncImage(url: flow.search.posterURL(for: movie)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 66)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.separatorColor).opacity(0.4))
                    .frame(width: 44, height: 66)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .frame(width: 44, height: 66)
    }

    /// #0027 — the audio (and, read-only, #0033's subtitle-group) picker for
    /// the settled feature title. Shown only once a title has resolved
    /// against the scan `jobs` currently holds.
    @ViewBuilder
    private var trackSelectionSection: some View {
        if case .scanned(let result) = jobs.scanState,
           let index = jobs.selectedTitleIndex,
           let title = result.disc.titles.first(where: { $0.index == index }) {
            Divider()
            TrackSelectionView(jobs: jobs, settings: settings, title: title)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Start (#0053)

    /// The single decision behind the Start button — the same
    /// `StartGate.decide` a Phase 4 remote client will use to gate its own
    /// Start command. Computed once per body evaluation so `.disabled`, the
    /// tooltip and the caption can never disagree about why it is greyed.
    private var startDecision: StartDecision {
        StartGate.decide(
            hasMovieSelected:    flow.search.selectedMovie != nil,
            isRunning:           jobs.isRunning,
            // #0045 review: a disc being ejected by hand is not a disc to
            // start on (`start` refuses it too).
            hasDisc:             jobs.insertedDisc != nil && !jobs.isEjecting,
            // #0049: an earlier eject unmounted the disc but failed to
            // physically eject it.
            discUnavailable:     jobs.discUnavailable,
            scanState:           jobs.scanState,
            selectedTitleIndex:  jobs.selectedTitleIndex,
            selectedAudioTrackNumbers: jobs.selectedAudioTrackNumbers,
            runtimeLookup:       flow.search.runtimeLookup,
            mismatchAcknowledgement: jobs.mismatchAcknowledgement,
            // #0062: checked last, so the caption still names the first thing
            // to do and a duplicate is never reported before the disc has
            // even been scanned.
            libraryCheck:            flow.libraryCheck,
            replaceAcknowledgement:  flow.replaceAcknowledgement
        )
    }

    private var actionBar: some View {
        StepActionBar {
            Spacer()
            // #0053: the caption beside the button — the same sentence as
            // its tooltip, so a disabled Start never leaves the user
            // guessing why (found twice on a real disc, 2026-09-16).
            if let reason = startDecision.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // #0140 review: the longest reason (#0049's partial
                    // eject, 103 characters) needs more width than this row
                    // has at `minSize`, and a `Text` squeezed inside an
                    // `HStack` truncates rather than wraps. Since #0053 made
                    // this the only on-screen explanation of a greyed-out
                    // Start, take the height instead.
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
            Button("Start Ripping") {
                flow.startRipping(jobs: jobs, settings: settings)
            }
            .disabled(startDecision != .ready)
            .help(startDecision.reason ?? "Encode the selected title into the Plex library.")
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }
}
