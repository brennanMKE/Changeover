import Foundation
import Testing
@testable import Changeover
@testable import ChangeoverBridge

/// #0245 — the CLI's "Don't import this one".
///
/// An agent could leave a film out of a multi-film disc only by never naming
/// it, which is how The Jackal stayed out of a WILLIS triple feature. That
/// fails three ways:
///
/// 1. `select` is additive, so a film once named cannot be un-named.
/// 2. Asking the app whether a film is already in Plex requires naming it,
///    which puts it into the plan — the question changes the answer.
/// 3. A film the app guessed for itself cannot be dropped at all.
///
/// Routed through `RipFlowController.setFeatureSkipped`, the same method the
/// window's link calls, so the plan, the gate and the extras attachment cannot
/// disagree about which films are running.
@Suite struct AgentSkipFeatureTests {

    // MARK: - The CLI surface

    @Test func selectAcceptsSkipAndUnskip() throws {
        let parsed = CLIParse.parse(["select", "--skip", "6", "--unskip", "7"])
        guard case .success(let invocation) = parsed,
              case .select(let options) = invocation.command
        else { Issue.record("select --skip did not parse"); return }
        #expect(options.request.skipFeatures == [6])
        #expect(options.request.unskipFeatures == [7])
    }

    /// Several skips in one call, the way several `--extra`s work.
    @Test func severalSkipsAccumulate() throws {
        let parsed = CLIParse.parse(["select", "--skip", "6", "--skip", "8"])
        guard case .success(let invocation) = parsed,
              case .select(let options) = invocation.command
        else { Issue.record("did not parse"); return }
        #expect(options.request.skipFeatures == [6, 8])
    }

    /// A skip alone is a real request. Before this, `isEmpty` would have
    /// refused it as "a selection that asks for nothing" — which is how an
    /// additive verb quietly loses a new kind of instruction.
    @Test func askipAloneIsNotAnEmptyRequest() {
        #expect(!SelectionRequest(skipFeatures: [6]).isEmpty)
        #expect(!SelectionRequest(unskipFeatures: [6]).isEmpty)
        #expect(SelectionRequest().isEmpty)
    }

    /// Not a number is a usage error, not a silently ignored flag.
    @Test func anonNumericSkipIsRefused() {
        guard case .failure = CLIParse.parse(["select", "--skip", "theJackal"]) else {
            Issue.record("--skip theJackal should be a usage error"); return
        }
    }

    /// It belongs to `select`, so a stray `--skip` elsewhere is a usage error.
    @Test func skipDoesNotApplyToOtherVerbs() {
        guard case .failure = CLIParse.parse(["import", "--disc", "A", "--skip", "6"]) else {
            Issue.record("--skip should not be accepted by import"); return
        }
    }

    // MARK: - The state it drives

    /// The whole point: a named film can be taken back out.
    @Test @MainActor func anamedFilmCanBeSkipped() throws {
        let jobs = MultiFeatureSelectionTests.controller(
            scan: MultiFeatureSelectionTests.tripleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        let feature = try #require(flow.featureSelection.features.first)

        flow.setFeatureSkipped(true, feature: feature, jobs: jobs,
                               settings: settings, origin: .agent)
        #expect(flow.featureSelection.isSkipped(feature))

        flow.setFeatureSkipped(false, feature: feature, jobs: jobs,
                               settings: settings, origin: .agent)
        #expect(!flow.featureSelection.isSkipped(feature))
    }

    /// #0242's defaulted parameter reaching a THIRD path, which that ticket
    /// said would happen again.
    ///
    /// `setFeatureSkipped` forwards to `applyActiveFeature`, which forwards to
    /// `select`, whose default origin is `.user`. An agent skipping one film
    /// while another is named would have rewritten the named film's record to
    /// say a person chose it.
    ///
    /// Named film and skipped film are deliberately different features, which
    /// is both the real case (name these, leave that one out) and the only one
    /// where the question means anything: skipping the film that IS named
    /// unselects it, and then there is no choice left to attribute.
    @Test @MainActor func anagentsSkipDoesNotRewriteWhoChoseTheOtherFilm() throws {
        let jobs = MultiFeatureSelectionTests.controller(
            scan: MultiFeatureSelectionTests.tripleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        let features = flow.featureSelection.features
        let named = try #require(features.first)
        let other = try #require(features.dropFirst().first)

        let movie = try MultiFeatureSelectionTests.movie(
            id: 7183, title: "Perfect Stranger", year: "2007-04-13")
        flow.featureSearch(named)?.results = [movie]
        flow.selectFeature(movieID: movie.id, feature: named, jobs: jobs,
                           settings: settings, origin: .agent, askedFor: "Perfect Stranger")
        #expect(IdentificationSummary.chooser(jobs.identificationStory) == .agent)

        flow.setFeatureSkipped(true, feature: other, jobs: jobs,
                               settings: settings, origin: .agent)

        #expect(flow.featureSelection.isSkipped(other))
        #expect(IdentificationSummary.chooser(jobs.identificationStory) == .agent,
                "an agent skipped one film; the other film is still the agent's choice")
    }
}
