import ChangeoverBridge
import Foundation
import Testing

/// #0196 — `changeoverctl wait`'s predicate.
///
/// Evaluated against the **snapshot**, never against the arrival of an event, and
/// that choice is what most of this file is about. The obvious implementation waits
/// for a `disc.inserted` event and exits; it would hang forever for an agent that
/// attached with the disc already in the drive, waiting on something that happened
/// ten minutes ago. So a condition that is already true is met at once.
///
/// Pure, so each condition is asserted against a fixture rather than against a real
/// disc — the only coverage available, since UI tests are forbidden here.
@Suite struct WaitConditionTests {

    /// Through `BridgeFixtures` rather than built here, so the snapshot a condition
    /// is judged against is the same shape every other bridge test uses.
    private func status(
        disc: DiscStatus? = nil,
        scan: ScanStatus = ScanStatus(state: ScanStatus.State.idle),
        film: FilmStatus? = nil,
        job: JobStatus? = nil
    ) -> BridgeStatus {
        BridgeFixtures.status(disc: disc, scan: scan, film: film, job: job, sessions: 1)
    }

    // MARK: - disc-inserted

    @Test func discInsertedIsMetAsSoonAsThereIsAnActionableDisc() {
        #expect(WaitCondition.discInserted.isMet(status: status(disc: BridgeFixtures.disc())))
    }

    @Test func discInsertedIsNotMetWithAnEmptyDrive() {
        #expect(!WaitCondition.discInserted.isMet(status: status()))
    }

    /// Not merely `disc != nil`. A disc on its way out is present and is not
    /// something to start work on — reporting it as inserted would hand an agent a
    /// disc every other verb will refuse.
    @Test func aDiscOnItsWayOutDoesNotCountAsInserted() {
        #expect(
            !WaitCondition.discInserted.isMet(
                status: status(disc: BridgeFixtures.disc(isEjecting: true))
            )
        )
    }

    /// #0049's half-eject leaves a disc whose mount path no longer resolves. It is
    /// in the drive and nothing can read it.
    @Test func anUnavailableDiscDoesNotCountAsInserted() {
        #expect(
            !WaitCondition.discInserted.isMet(
                status: status(disc: BridgeFixtures.disc(unavailable: true))
            )
        )
    }

    // MARK: - disc-ejected

    @Test func discEjectedIsMetWhenTheDriveIsEmpty() {
        #expect(WaitCondition.discEjected.isMet(status: status()))
        #expect(!WaitCondition.discEjected.isMet(status: status(disc: BridgeFixtures.disc())))
    }

    // MARK: - scan-complete

    @Test func scanCompleteIsMetOnASuccessfulScan() {
        #expect(
            WaitCondition.scanComplete.isMet(
                status: status(scan: ScanStatus(state: ScanStatus.State.scanned, titleCount: 12))
            )
        )
    }

    /// Settled, not succeeded. An agent that waited only for success would sit out
    /// its whole timeout on a disc whose title set is unreadable — a disc the user
    /// needs told about, not waited on.
    @Test func scanCompleteIsAlsoMetWhenTheScanFailed() {
        let failed = ScanStatus(
            state: ScanStatus.State.failed,
            failure: "the disc's title set is unreadable"
        )
        #expect(WaitCondition.scanComplete.isMet(status: status(scan: failed)))
        // And it says so, rather than reporting a title count it does not have.
        #expect(
            WaitCondition.scanComplete.metDetail(status: status(scan: failed))
                .contains("unreadable")
        )
    }

    @Test(arguments: [ScanStatus.State.idle, ScanStatus.State.scanning])
    func scanCompleteIsNotMetBeforeTheScanSettles(_ state: String) {
        #expect(!WaitCondition.scanComplete.isMet(status: status(scan: ScanStatus(state: state))))
    }

    // MARK: - identified

    @Test func identifiedIsMetWhenAFilmIsSettled() {
        #expect(WaitCondition.identified.isMet(status: status(film: BridgeFixtures.film())))
        #expect(!WaitCondition.identified.isMet(status: status()))
    }

    // MARK: - job-done

    @Test func jobDoneIsMetOnATerminalJob() {
        let finished = JobStatus(running: false, id: "job-1", phase: "succeeded", outcome: "succeeded")
        #expect(WaitCondition.jobDone.isMet(status: status(job: finished)))
    }

    @Test func jobDoneIsNotMetWhileOneIsRunning() {
        let running = JobStatus(running: true, id: "job-1", phase: "encoding", percent: 61)
        #expect(!WaitCondition.jobDone.isMet(status: status(job: running)))
    }

    @Test func jobDoneIsNotMetWhenNoJobHasEverRun() {
        #expect(!WaitCondition.jobDone.isMet(status: status()))
    }

    /// The race this binding closes. A disc holding two films produces two jobs; the
    /// first one finishing would otherwise satisfy `wait --for job-done` while the
    /// second is still queued, and the agent would eject a disc with a film still on
    /// it — #0163's reported bug, reached by a new road.
    @Test func bindingToAJobIDRefusesTheWrongJobsFinish() {
        let firstFilmFinished = JobStatus(
            running: false, id: "job-1", phase: "succeeded", outcome: "succeeded"
        )
        #expect(
            !WaitCondition.jobDone.isMet(status: status(job: firstFilmFinished), boundJobID: "job-2")
        )
        #expect(
            WaitCondition.jobDone.isMet(status: status(job: firstFilmFinished), boundJobID: "job-1")
        )
    }

    /// A cancel is a terminal outcome like any other, which is what makes a cancel
    /// indistinguishable downstream from a failure — and what lets `cancel` followed
    /// by `wait --for job-done` work.
    @Test(arguments: ["succeeded", "failed", "cancelled"])
    func everyTerminalPhaseSatisfiesJobDone(_ phase: String) {
        let settled = JobStatus(running: false, id: "job-1", phase: phase, outcome: phase)
        #expect(WaitCondition.jobDone.isMet(status: status(job: settled)))
    }

    // MARK: - idle

    @Test func idleIsMetWithNothingHappening() {
        #expect(WaitCondition.idle.isMet(status: status()))
    }

    /// A finished job is not "in flight". `job == nil` and a settled job are both
    /// idle, or an agent could never wait for idle twice in one session.
    @Test func aFinishedJobIsStillIdle() {
        let finished = JobStatus(running: false, id: "job-1", phase: "succeeded", outcome: "succeeded")
        #expect(WaitCondition.idle.isMet(status: status(job: finished)))
    }

    @Test func idleIsNotMetWhileAJobRuns() {
        #expect(
            !WaitCondition.idle.isMet(
                status: status(job: JobStatus(running: true, phase: "encoding"))
            )
        )
    }

    @Test func idleIsNotMetWhileAScanRuns() {
        #expect(
            !WaitCondition.idle.isMet(
                status: status(scan: ScanStatus(state: ScanStatus.State.scanning))
            )
        )
    }

    /// The check that stops an agent putting the next disc into a drive that has not
    /// opened yet.
    @Test func idleIsNotMetWhileAnEjectIsInFlight() {
        #expect(
            !WaitCondition.idle.isMet(status: status(disc: BridgeFixtures.disc(isEjecting: true)))
        )
    }

    // MARK: - What a timeout says

    /// The *state*, not the condition. "timed out waiting for job-done" tells a
    /// caller nothing it did not know; "the job is encoding, 61%" tells it whether
    /// to wait longer or go and look.
    @Test func aTimeoutReportsWhatItWasStillLookingAt() {
        let running = JobStatus(running: true, id: "job-1", phase: "encoding", percent: 61)
        let detail = WaitCondition.jobDone.unmetDetail(status: status(job: running))
        #expect(detail.contains("encoding"))
        #expect(detail.contains("61"))
    }

    @Test func aTimeoutWithNoSnapshotSaysSoRatherThanGuessing() {
        #expect(WaitCondition.idle.unmetDetail(status: nil).contains("no snapshot"))
    }

    @Test func aTimeoutOnIdleNamesEverythingThatIsBusy() {
        let detail = WaitCondition.idle.unmetDetail(
            status: status(
                disc: BridgeFixtures.disc(isEjecting: true),
                scan: ScanStatus(state: ScanStatus.State.scanning),
                job: JobStatus(running: true, phase: "encoding")
            )
        )
        #expect(detail.contains("job"))
        #expect(detail.contains("scan"))
        #expect(detail.contains("eject"))
    }

    // MARK: - The contract itself

    /// The spelling an agent types is the raw value, and `help` and the parser both
    /// read it from here. A condition renamed in one place and not the others would
    /// be a condition nobody can ask for.
    @Test func theSpellingsAreTheOnesTheDocumentPromises() {
        #expect(
            WaitCondition.names
                == ["disc-inserted", "disc-ejected", "scan-complete", "identified", "job-done", "idle"]
        )
    }

    @Test(arguments: WaitCondition.allCases)
    func everyConditionHasASummaryForHelp(_ condition: WaitCondition) {
        #expect(!condition.summary.isEmpty)
    }
}
