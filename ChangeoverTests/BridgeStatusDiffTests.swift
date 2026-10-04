import ChangeoverBridge
import Foundation
import Testing

/// #0189 — the rules that turn two snapshots into `watch` events.
///
/// This is where the judgement in the event feed lives, and it is a pure function
/// over two values, so all of it is reachable here. The transport is not: it is
/// verified by hand, following the RemoteControl prototype's manual test script.
struct BridgeStatusDiffTests {

    private func kinds(_ old: BridgeStatus?, _ new: BridgeStatus) -> [String] {
        BridgeStatusDiff.drafts(from: old, to: new).map(\.kind)
    }

    // MARK: - The first snapshot

    /// The opening `session.attached` event already carries the whole snapshot.
    /// Replaying "a disc was inserted" for a disc that went in ten minutes ago
    /// would be a lie about when it happened.
    @Test func theFirstSnapshotEmitsNothing() {
        let first = BridgeFixtures.status(disc: BridgeFixtures.disc(), film: BridgeFixtures.film())
        #expect(BridgeStatusDiff.drafts(from: nil, to: first).isEmpty)
    }

    @Test func anUnchangedSnapshotEmitsNothing() {
        let status = BridgeFixtures.status(disc: BridgeFixtures.disc())
        #expect(kinds(status, status).isEmpty)
    }

    // MARK: - Disc

    @Test func aDiscArrivingIsReported() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(),
            to: BridgeFixtures.status(disc: BridgeFixtures.disc())
        )
        let inserted = try #require(drafts.first { $0.kind == BridgeEvent.Kind.discInserted })
        #expect(inserted.disc?.label == "GARDEN_STATE")
        // Carries the scan and the gate too, so a consumer knows immediately
        // whether there is anything to wait for.
        #expect(inserted.scan != nil)
        #expect(inserted.start != nil)
    }

    @Test func aDiscLeavingIsReported() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(disc: BridgeFixtures.disc()),
            to: BridgeFixtures.status()
        )
        let ejected = try #require(drafts.first { $0.kind == BridgeEvent.Kind.discEjected })
        #expect(ejected.summary.contains("GARDEN_STATE"))
    }

    /// The case `insertionID` exists for. Two discs with no resolvable identity
    /// can mount at the same path with the same device node, so comparing by
    /// label or `discID` would read a swap as "nothing happened" — and an agent
    /// would carry on reasoning about the disc that left.
    @Test func aSwapBetweenIndistinguishableDiscsIsStillTwoEvents() {
        let first = BridgeFixtures.disc(
            label: "MOVIE",
            discID: nil,
            insertionID: "AAAA"
        )
        let second = BridgeFixtures.disc(
            label: "MOVIE",
            discID: nil,
            insertionID: "BBBB"
        )
        #expect(
            kinds(
                BridgeFixtures.status(disc: first),
                BridgeFixtures.status(disc: second)
            ) == [BridgeEvent.Kind.discEjected, BridgeEvent.Kind.discInserted]
        )
    }

    /// Order is causal. A consumer that saw the insert before the eject would
    /// conclude the drive is empty.
    @Test func ejectIsReportedBeforeTheNextInsert() {
        let kinds = kinds(
            BridgeFixtures.status(disc: BridgeFixtures.disc(insertionID: "AAAA")),
            BridgeFixtures.status(disc: BridgeFixtures.disc(insertionID: "BBBB"))
        )
        let eject = kinds.firstIndex(of: BridgeEvent.Kind.discEjected)
        let insert = kinds.firstIndex(of: BridgeEvent.Kind.discInserted)
        #expect(eject != nil)
        #expect(insert != nil)
        #expect(eject! < insert!)
    }

    // MARK: - Scan

    @Test func aFinishedScanIsReportedWithItsTitleCount() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                scan: BridgeFixtures.scan(state: ScanStatus.State.scanning)
            ),
            to: BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                scan: BridgeFixtures.scan(
                    state: ScanStatus.State.scanned,
                    titleCount: 9,
                    mainFeatureIndex: 1
                )
            )
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.scanFinished })
        #expect(event.summary.contains("9 title"))
        #expect(event.summary.contains("main feature 1"))
        #expect(event.scan?.titleCount == 9)
    }

    @Test func aFailedScanCarriesItsReason() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                scan: BridgeFixtures.scan(state: ScanStatus.State.scanning)
            ),
            to: BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                scan: BridgeFixtures.scan(
                    state: ScanStatus.State.failed,
                    failure: "the disc's title set is unreadable"
                )
            )
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.scanFinished })
        #expect(event.summary.contains("unreadable"))
    }

    /// `idle → scanning` is the app starting work nobody asked about. Announcing
    /// it would double every disc insertion.
    @Test func aScanStartingIsNotAnnounced() {
        let kinds = kinds(
            BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                scan: BridgeFixtures.scan(state: ScanStatus.State.idle)
            ),
            BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                scan: BridgeFixtures.scan(state: ScanStatus.State.scanning)
            )
        )
        #expect(!kinds.contains(BridgeEvent.Kind.scanFinished))
    }

    // MARK: - Identification

    @Test func identifyingAFilmIsReported() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(disc: BridgeFixtures.disc()),
            to: BridgeFixtures.status(disc: BridgeFixtures.disc(), film: BridgeFixtures.film())
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.identificationSettled })
        #expect(event.summary.contains("Garden State"))
        #expect(event.summary.contains("tmdb-401"))
        #expect(event.film?.tmdbID == "401")
    }

    @Test func aFilmChosenByHandSaysSo() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(disc: BridgeFixtures.disc()),
            to: BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                film: BridgeFixtures.film(chosenByUser: true)
            )
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.identificationSettled })
        #expect(event.summary.contains("chosen by hand"))
    }

    /// A library check completing changes `FilmStatus` without changing which
    /// film it is, and must not read as the app changing its mind.
    @Test func aLibraryCheckFinishingIsNotAnIdentification() {
        let kinds = kinds(
            BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                film: BridgeFixtures.film(libraryStatus: "checking")
            ),
            BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                film: BridgeFixtures.film(libraryStatus: "present")
            )
        )
        #expect(!kinds.contains(BridgeEvent.Kind.identificationSettled))
    }

    /// The insert event already says what is known about the new disc. A second
    /// line saying "no film is identified" a quarter of a second later is noise an
    /// agent would have to learn to ignore.
    @Test func aDiscSwapDoesNotAlsoReportLosingTheOldFilm() {
        let kinds = kinds(
            BridgeFixtures.status(
                disc: BridgeFixtures.disc(insertionID: "AAAA"),
                film: BridgeFixtures.film()
            ),
            BridgeFixtures.status(disc: BridgeFixtures.disc(insertionID: "BBBB"))
        )
        #expect(!kinds.contains(BridgeEvent.Kind.identificationSettled))
    }

    /// An empty drive needs no "the film is gone" line either — the eject said it.
    @Test func losingTheFilmWithNoDiscIsSilent() {
        let kinds = kinds(
            BridgeFixtures.status(film: BridgeFixtures.film()),
            BridgeFixtures.status()
        )
        #expect(kinds.isEmpty)
    }

    @Test func losingTheFilmWithTheDiscStillInIsReported() {
        let kinds = kinds(
            BridgeFixtures.status(disc: BridgeFixtures.disc(), film: BridgeFixtures.film()),
            BridgeFixtures.status(disc: BridgeFixtures.disc())
        )
        #expect(kinds.contains(BridgeEvent.Kind.identificationSettled))
    }

    // MARK: - Job

    @Test func aPhaseChangeIsReported() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(job: BridgeFixtures.job(phase: "starting", percent: nil)),
            to: BridgeFixtures.status(job: BridgeFixtures.job(phase: "encoding", percent: 0))
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.jobPhaseChanged })
        #expect(event.summary.contains("encoding"))
        #expect(event.job?.phase == "encoding")
    }

    /// A terminal phase reports *finished*, not a phase change. They are the same
    /// edge, and emitting both makes "has it finished?" a question with two
    /// answers.
    @Test func aTerminalPhaseReportsFinishedAndNotAPhaseChange() {
        let kinds = kinds(
            BridgeFixtures.status(job: BridgeFixtures.job(phase: "organizing", percent: nil)),
            BridgeFixtures.status(
                job: BridgeFixtures.job(
                    running: false,
                    phase: "succeeded",
                    percent: nil,
                    unit: nil,
                    outcome: "succeeded"
                )
            )
        )
        #expect(kinds.contains(BridgeEvent.Kind.jobFinished))
        #expect(!kinds.contains(BridgeEvent.Kind.jobPhaseChanged))
    }

    @Test func aFailedJobCarriesItsReason() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(job: BridgeFixtures.job(phase: "encoding")),
            to: BridgeFixtures.status(
                job: BridgeFixtures.job(
                    running: false,
                    phase: "failed",
                    percent: nil,
                    unit: nil,
                    outcome: "failed",
                    failureReason: "the destination volume is full"
                )
            )
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.jobFinished })
        #expect(event.summary.contains("volume is full"))
    }

    /// A second job on the same disc has a different id in the same phase. Without
    /// the id check it would look like nothing happened.
    @Test func aNewJobInTheSamePhaseIsReported() {
        let kinds = kinds(
            BridgeFixtures.status(job: BridgeFixtures.job(id: "job-1", phase: "starting", percent: nil)),
            BridgeFixtures.status(job: BridgeFixtures.job(id: "job-2", phase: "starting", percent: nil))
        )
        #expect(kinds.contains(BridgeEvent.Kind.jobPhaseChanged))
    }

    // MARK: - Progress

    /// HandBrake reports several times a second. A consumer reading one JSON
    /// object per line does not want four thousand of them for one encode, so
    /// progress is throttled to whole percentage points.
    @Test func progressBelowAWholePercentIsSuppressed() {
        let kinds = kinds(
            BridgeFixtures.status(job: BridgeFixtures.job(percent: 10.1)),
            BridgeFixtures.status(job: BridgeFixtures.job(percent: 10.9))
        )
        #expect(kinds.isEmpty)
    }

    @Test func crossingAWholePercentIsReported() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(job: BridgeFixtures.job(percent: 10.9)),
            to: BridgeFixtures.status(job: BridgeFixtures.job(percent: 11.0))
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.jobProgress })
        #expect(event.summary.hasPrefix("11%"))
        // Progress lines are small on purpose: they are the high-frequency kind,
        // and repeating the disc and the gate on each one would multiply the
        // stream's size for information that has not changed.
        #expect(event.disc == nil)
        #expect(event.flow == nil)
    }

    /// The step from the feature encode to "extra 1 of 3" is a real transition
    /// that carries no phase change, because both happen inside one phase.
    @Test func changingUnitAtTheSamePercentIsReported() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(job: BridgeFixtures.job(percent: 0, unit: "feature")),
            to: BridgeFixtures.status(
                job: BridgeFixtures.job(percent: 0, unit: "extra", extraIndex: 1, extraCount: 3)
            )
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.jobProgress })
        #expect(event.summary.contains("extra 1 of 3"))
    }

    /// A step with no percentage — a remux, or muxing — reports nothing rather
    /// than a zero that looks like a stalled encode.
    @Test func anIndeterminateStepEmitsNoProgress() {
        let kinds = kinds(
            BridgeFixtures.status(job: BridgeFixtures.job(percent: nil, unit: "remux")),
            BridgeFixtures.status(job: BridgeFixtures.job(percent: nil, unit: "remux"))
        )
        #expect(kinds.isEmpty)
    }

    // MARK: - Flow and the gate

    @Test func aStepChangeIsReported() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(flow: BridgeFixtures.flow(step: "chooseMovie")),
            to: BridgeFixtures.status(flow: BridgeFixtures.flow(step: "confirm"))
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.flowStepChanged })
        #expect(event.summary.contains("confirm"))
        #expect(event.flow?.step == "confirm")
    }

    /// The single most useful thing a waiting agent can be told. A library check
    /// finishing opens the gate without moving the screen, and without this event
    /// `watch` would have to be paired with polling `status`.
    @Test func theGateOpeningIsReportedOnItsOwn() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(
                start: BridgeFixtures.start(decision: "libraryCheckInProgress")
            ),
            to: BridgeFixtures.status(
                start: BridgeFixtures.start(permitted: true, decision: "ready", reason: nil)
            )
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.startDecisionChanged })
        #expect(event.summary.contains("available"))
        #expect(event.start?.permitted == true)
    }

    @Test func theGateClosingReportsItsReason() throws {
        let drafts = BridgeStatusDiff.drafts(
            from: BridgeFixtures.status(
                start: BridgeFixtures.start(permitted: true, decision: "ready", reason: nil)
            ),
            to: BridgeFixtures.status(
                start: BridgeFixtures.start(
                    decision: "noAudioTrackSelected",
                    reason: "Pick at least one audio track."
                )
            )
        )
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.startDecisionChanged })
        #expect(event.summary.contains("Pick at least one audio track."))
    }

    /// Not emitted when another event already carried the new decision, so a disc
    /// going in produces one line about the disc rather than two about the same
    /// moment.
    @Test func theGateIsNotReportedTwiceForOneChange() {
        let kinds = kinds(
            BridgeFixtures.status(start: BridgeFixtures.start(decision: "noDisc")),
            BridgeFixtures.status(
                disc: BridgeFixtures.disc(),
                start: BridgeFixtures.start(decision: "scanInProgress")
            )
        )
        #expect(kinds.contains(BridgeEvent.Kind.discInserted))
        #expect(!kinds.contains(BridgeEvent.Kind.startDecisionChanged))
    }
}
