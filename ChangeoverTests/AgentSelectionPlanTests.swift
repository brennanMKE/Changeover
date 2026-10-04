import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0196 — the boundary where an agent's text and integers meet the app.
///
/// Three of the inputs become path components or encoder arguments, and each has a
/// failure this file is about:
///
/// - a **disc insertion token**. Two discs with no resolvable identity mount at the
///   same path with the same device node, so a selection decided four minutes ago
///   must be refused rather than applied to whatever is in the drive now. That is
///   #0034's data-loss shape — a stale selection filing a new disc under the
///   previous film's name — reached by a new road.
/// - a **title index**, meaningless across scans (#0028).
/// - an **extras folder name**, the one input where a near miss is worse than a
///   refusal: Plex excludes exactly eight names from its movie scan, so a file in
///   `Behind the Scenes` is scanned as a film and filed as a second movie with a
///   nonsense name.
///
/// The refusals are tested hardest, because an accepted mistake here writes a file.
@Suite struct AgentSelectionPlanTests {

    private static let mounted = "11111111-1111-1111-1111-111111111111"
    private static let titles = [1, 2, 8, 9, 10]

    private func decide(
        _ request: SelectionRequest,
        mounted: String? = AgentSelectionPlanTests.mounted,
        titles: [Int] = AgentSelectionPlanTests.titles,
        isRunning: Bool = false,
        isConfigured: Bool = true
    ) -> AgentSelectionPlan.Decision {
        AgentSelectionPlan.decide(
            request: request,
            mountedInsertionID: mounted,
            scannedTitleIndices: titles,
            isRunning: isRunning,
            isConfigured: isConfigured
        )
    }

    private func refusal(_ decision: AgentSelectionPlan.Decision) -> (outcome: String, reason: String)? {
        if case .refuse(let outcome, let reason) = decision { return (outcome, reason) }
        return nil
    }

    private func resolved(_ decision: AgentSelectionPlan.Decision) -> AgentSelectionPlan.Resolved? {
        if case .apply(let resolved) = decision { return resolved }
        return nil
    }

    // MARK: - What goes through

    @Test func theWorkedSessionsSelectionResolves() {
        let decision = decide(
            SelectionRequest(
                discInsertionID: Self.mounted,
                movieID: 401,
                featureTitle: 1,
                extras: [
                    .init(
                        titleIndex: 8,
                        kind: "Behind The Scenes",
                        label: "The Making of Garden State"
                    )
                ]
            )
        )
        let plan = resolved(decision)
        #expect(plan?.featureTitle == 1)
        #expect(plan?.movieID == 401)
        #expect(plan?.extras == [
            .init(titleIndex: 8, kind: .behindTheScenes, label: "The Making of Garden State")
        ])
    }

    /// Additive: naming the film alone is allowed, and needs no scan — which matters
    /// because that is exactly when an agent that has read the volume label wants to
    /// act, with the scan still running.
    @Test func namingOnlyTheFilmNeedsNoScan() {
        let decision = decide(SelectionRequest(movieID: 401), titles: [])
        #expect(resolved(decision)?.movieID == 401)
    }

    /// Left to the app to derive from the label, which is what the window does.
    @Test func anExtraWithNoKindLeavesTheDerivationToTheApp() {
        let decision = decide(
            SelectionRequest(extras: [.init(titleIndex: 8, label: "Making of Signs")])
        )
        #expect(resolved(decision)?.extras.first?.kind == nil)
        #expect(resolved(decision)?.extras.first?.label == "Making of Signs")
    }

    // MARK: - The disc

    /// The refusal this ticket's brief singles out, and the one whose absence costs a
    /// file in the library.
    @Test func aSwappedDiscIsRefused() {
        let decision = decide(
            SelectionRequest(discInsertionID: "a-different-insertion", movieID: 401)
        )
        #expect(refusal(decision)?.outcome == ActionOutcome.refusedDiscSwapped)
    }

    /// Names **both** tokens. The useful question is "is this the disc I was told
    /// about", and an agent cannot answer it from a refusal that only says no.
    @Test func theSwapRefusalNamesBothTokens() {
        let reason = refusal(
            decide(SelectionRequest(discInsertionID: "D-OLD", movieID: 401))
        )?.reason ?? ""
        #expect(reason.contains("D-OLD"))
        #expect(reason.contains(Self.mounted))
    }

    /// Checked **before** any index, deliberately. If the disc has gone then every
    /// index in the request is about something else, and "title 8 is not on this
    /// disc" would send an agent looking for a scan problem it does not have.
    @Test func theDiscCheckComesBeforeTheTitleCheck() {
        let decision = decide(
            SelectionRequest(discInsertionID: "D-OLD", extras: [.init(titleIndex: 99)])
        )
        #expect(refusal(decision)?.outcome == ActionOutcome.refusedDiscSwapped)
    }

    /// Omitting it is allowed — `select` is additive and an agent may be naming a
    /// film before it has read a status. `import` is the verb that requires it,
    /// because `import` is the irreversible one.
    @Test func omittingTheDiscTokenIsAllowedForSelect() {
        #expect(resolved(decide(SelectionRequest(movieID: 401))) != nil)
    }

    @Test func anEmptyDriveIsRefused() {
        #expect(
            refusal(decide(SelectionRequest(movieID: 401), mounted: nil))?.outcome
                == ActionOutcome.refusedNoDisc
        )
    }

    // MARK: - The titles

    @Test func aFeatureTitleTheScanDoesNotHaveIsRefused() {
        let decision = decide(SelectionRequest(featureTitle: 42))
        #expect(refusal(decision)?.outcome == ActionOutcome.refusedUnknownTitle)
    }

    /// Lists what the scan does have. A refusal that only says "not found" leaves an
    /// agent to go and ask, and the answer is three words long.
    @Test func theUnknownTitleRefusalListsTheRealTitles() {
        let reason = refusal(decide(SelectionRequest(featureTitle: 42)))?.reason ?? ""
        #expect(reason.contains("1, 2, 8, 9, 10"))
    }

    @Test func anExtraTheScanDoesNotHaveIsRefused() {
        #expect(
            refusal(decide(SelectionRequest(extras: [.init(titleIndex: 99)])))?.outcome
                == ActionOutcome.refusedUnknownTitle
        )
    }

    /// A different refusal from "that index is not on the disc", because the remedies
    /// differ: an agent that arrived early should wait, and one that named title 99
    /// should not.
    @Test func anIndexBeforeAnyScanIsItsOwnRefusal() {
        let decision = decide(SelectionRequest(featureTitle: 1), titles: [])
        #expect(refusal(decision)?.outcome == ActionOutcome.refusedNoScan)
        #expect(refusal(decision)?.reason.contains("wait --for scan-complete") == true)
    }

    /// `ExtrasPlan.make` would drop it anyway, which is right for a window where a
    /// click can collide with a selection. An agent that asked for one title to be
    /// both is confused, and exit 0 would leave it believing something that is not
    /// going to happen.
    @Test func oneTitleCannotBeBothTheFeatureAndItsOwnExtra() {
        let decision = decide(
            SelectionRequest(featureTitle: 1, extras: [.init(titleIndex: 1)])
        )
        #expect(refusal(decision)?.outcome == ActionOutcome.refusedUnknownTitle)
        #expect(refusal(decision)?.reason.contains("both") == true)
    }

    // MARK: - The extras folder

    @Test(arguments: PlexExtra.Kind.allCases)
    func everyOneOfPlexsEightFoldersIsAccepted(_ kind: PlexExtra.Kind) {
        let decision = decide(
            SelectionRequest(extras: [.init(titleIndex: 8, kind: kind.folderName)])
        )
        #expect(resolved(decision)?.extras.first?.kind == kind)
    }

    /// The case that matters most, and the one an agent will actually get wrong:
    /// English sentence case. Plex matches these names exactly, so this is an
    /// unrecognised folder — scanned as a film and filed as a second movie with a
    /// nonsense name.
    @Test func aCaseDifferenceIsRefusedNotCorrected() {
        let decision = decide(
            SelectionRequest(extras: [.init(titleIndex: 8, kind: "Behind the Scenes")])
        )
        #expect(refusal(decision)?.outcome == ActionOutcome.refusedUnknownExtrasFolder)
    }

    @Test(arguments: [
        "Behind the Scenes",
        "behind the scenes",
        "BEHIND THE SCENES",
        "Behind-The-Scenes",
        "BehindTheScenes",
        "Deleted scenes",
        "Featurette",
        "Extras",
        "Bonus",
        "Clips",
        "",
        "../../etc",
    ])
    func anythingOffPlexsListIsRefused(_ named: String) {
        let decision = decide(
            SelectionRequest(extras: [.init(titleIndex: 8, kind: named)])
        )
        #expect(
            refusal(decision)?.outcome == ActionOutcome.refusedUnknownExtrasFolder,
            "'\(named)' must not be accepted as a Plex extras folder"
        )
    }

    /// **Never suggests a nearest match.** A correction would teach an agent that
    /// the spelling is forgiving; it is not, and the next near miss would go into a
    /// folder Plex scans as a film. The refusal lists the eight instead.
    @Test func theFolderRefusalListsTheEightAndOffersNoCorrection() {
        let reason = refusal(
            decide(SelectionRequest(extras: [.init(titleIndex: 8, kind: "Behind the Scenes")]))
        )?.reason ?? ""
        for kind in PlexExtra.Kind.allCases {
            #expect(reason.contains(kind.folderName), "the refusal should list \(kind.folderName)")
        }
        #expect(!reason.lowercased().contains("did you mean"))
    }

    /// `Clips` was a real folder in this app until #0192 retired it, so an agent
    /// working from an older document might try it. It is not a Plex extras folder
    /// and never was — that was the whole point of it.
    @Test func clipsIsNotAPlexExtrasFolder() {
        #expect(!PlexExtra.recognisedFolderNames.contains("Clips"))
    }

    // MARK: - The other refusals

    /// A selection applied mid-job would move the extras out from under the encode.
    /// `RipFlowController.applyBonusFeatures` guards the same way, and
    /// `startNextFilm` is the only thing allowed to change them while a plan runs.
    @Test func aRunningJobRefusesASelection() {
        #expect(
            refusal(decide(SelectionRequest(movieID: 401), isRunning: true))?.outcome
                == ActionOutcome.refusedJobRunning
        )
    }

    @Test func anUnconfiguredAppRefusesASelection() {
        #expect(
            refusal(decide(SelectionRequest(movieID: 401), isConfigured: false))?.outcome
                == ActionOutcome.refusedNotConfigured
        )
    }

    /// Refused rather than treated as a no-op. The parser catches this first, so
    /// this is the failsafe at the point of harm — the pattern #0034 established.
    @Test func anEmptyRequestIsRefusedAtTheAppToo() {
        #expect(
            refusal(decide(SelectionRequest()))?.outcome == ActionOutcome.refusedEmptyRequest
        )
    }

    /// Checked before the disc, so an app with no Plex root says the useful thing
    /// rather than complaining about a drive.
    @Test func theConfigurationCheckComesFirst() {
        #expect(
            refusal(
                decide(SelectionRequest(movieID: 401), mounted: nil, isConfigured: false)
            )?.outcome == ActionOutcome.refusedNotConfigured
        )
    }

    // MARK: - #0202: --extras-only

    /// The contradiction that would have been applied as something else. A
    /// feature title alongside `--extras-only` says both "leave the film in
    /// Plex alone" and "re-encode this title as the film", and silently
    /// honouring either would be a job the agent did not ask for.
    @Test func extrasOnlyWithAFeatureTitleIsRefused() {
        let decision = decide(
            SelectionRequest(
                movieID: 121,
                featureTitle: 1,
                extras: [.init(titleIndex: 8)],
                extrasOnly: true
            )
        )
        guard case .refuse(_, let reason) = decision else {
            Issue.record("expected a refusal, got \(decision)")
            return
        }
        #expect(reason.contains("--extras-only"))
        #expect(reason.contains("--feature-title"))
    }

    /// And `--extras-only` with nothing ticked asks for a job that encodes
    /// nothing and files nothing — the same dead end `StartGate` refuses with
    /// an acknowledgement and no ticked extra.
    @Test func extrasOnlyWithNoExtrasIsRefused() {
        let decision = decide(SelectionRequest(movieID: 121, extrasOnly: true))
        guard case .refuse(let outcome, _) = decision else {
            Issue.record("expected a refusal, got \(decision)")
            return
        }
        #expect(outcome == ActionOutcome.refusedEmptyRequest)
    }

    /// The shape that works, and the flag surviving to the resolved plan —
    /// `AgentActions` reads it there to decide whether to acknowledge.
    @Test func extrasOnlyWithExtrasAndAFilmIsApplied() {
        let decision = decide(
            SelectionRequest(movieID: 121, extras: [.init(titleIndex: 8), .init(titleIndex: 9)], extrasOnly: true)
        )
        guard case .apply(let resolved) = decision else {
            Issue.record("expected it to apply, got \(decision)")
            return
        }
        #expect(resolved.extrasOnly)
        #expect(resolved.featureTitle == nil)
        #expect(resolved.extras.map { $0.titleIndex } == [8, 9])
    }

    /// An ordinary selection is untouched by the new flag.
    @Test func anOrdinarySelectionIsNotExtrasOnly() {
        let decision = decide(SelectionRequest(movieID: 121, featureTitle: 1, extras: [.init(titleIndex: 8)]))
        guard case .apply(let resolved) = decision else {
            Issue.record("expected it to apply, got \(decision)")
            return
        }
        #expect(!resolved.extrasOnly)
        #expect(resolved.featureTitle == 1)
    }

    /// `--extras-only` alone is not an empty request, so it reaches the plan's
    /// own refusal above rather than the parser's "select needs something to
    /// select". The two say different things and the specific one is better.
    @Test func extrasOnlyAloneIsNotAnEmptyRequest() {
        #expect(!SelectionRequest(extrasOnly: true).isEmpty)
        #expect(SelectionRequest().isEmpty)
    }
}

// MARK: - The two copies of Plex's folder names

/// #0196 — `help` has to print Plex's eight folder names whether or not Changeover
/// is running, and the `ChangeoverBridge` package cannot see the app target where
/// `PlexExtra.Kind` lives. So there is a second copy, in
/// `LibraryStatus.knownExtrasFolders`, used for help text and nothing else.
///
/// A second copy of a list whose spelling is load-bearing is exactly the drift this
/// project warns about, so it is closed by a test rather than by discipline. Only
/// this bundle can see both sides.
@Suite struct PlexExtrasFoldersAgreeTests {

    @Test func theHelpTextsCopyMatchesTheAppsList() {
        #expect(LibraryStatus.knownExtrasFolders == PlexExtra.Kind.allCases.map(\.folderName))
    }

    /// And the list the *running app* reports under `library.extrasFolders` is the
    /// app's own, so an agent choosing from `status` is choosing from the real thing
    /// and never from the help text's copy.
    @Test func theReportedListIsTheAppsOwn() {
        #expect(
            PlexExtra.Kind.allCases.map(\.folderName).count == PlexExtra.recognisedFolderNames.count
        )
    }

}
