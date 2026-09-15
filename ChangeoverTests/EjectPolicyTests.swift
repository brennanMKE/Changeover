import Testing
@testable import Changeover

/// Covers #0045's manual "Eject Disc" decision — pure, no `JobController`, no
/// `DiscEjector`, no drive.
struct EjectPolicyTests {

    private static let bools = [false, true]

    // MARK: - decide — each refusal, in precedence order

    @Test func noDiscRefusesForNoDiscWhateverElseIsTrue() {
        // "No disc" wins over everything: nothing else can be meaningfully
        // true without a disc, and it is the most specific reason.
        for running in Self.bools {
            for scanning in Self.bools {
                for ejecting in Self.bools {
                    let decision = EjectPolicy.decide(isRunning: running, isScanning: scanning, isEjecting: ejecting, hasDisc: false)
                    #expect(decision == .refuse(reason: "No disc is mounted."))
                }
            }
        }
    }

    @Test func discMountedAndIdleEjects() {
        let decision = EjectPolicy.decide(isRunning: false, isScanning: false, isEjecting: false, hasDisc: true)
        #expect(decision == .eject)
        #expect(decision.refusalReason == nil)
    }

    @Test func discMountedAndRunningRefusesForTheRunningJob() {
        for scanning in Self.bools {
            for ejecting in Self.bools {
                let decision = EjectPolicy.decide(isRunning: true, isScanning: scanning, isEjecting: ejecting, hasDisc: true)
                #expect(decision == .refuse(reason: "A job is running — wait for it to finish before ejecting."))
            }
        }
    }

    @Test func anEjectInFlightRefusesASecondEject() {
        for scanning in Self.bools {
            let decision = EjectPolicy.decide(isRunning: false, isScanning: scanning, isEjecting: true, hasDisc: true)
            #expect(decision == .refuse(reason: "The disc is already being ejected."))
        }
    }

    /// #0051: a scan in progress no longer refuses. It is the one blocker
    /// the caller can clear itself — cancel the scan, wait, then eject — so
    /// `decide` says so as a typed case, not a reason string.
    @Test func aScanInProgressAloneAsksToCancelTheScanThenEject() {
        let decision = EjectPolicy.decide(isRunning: false, isScanning: true, isEjecting: false, hasDisc: true)
        #expect(decision == .cancelScanThenEject)
        #expect(decision.refusalReason == nil)
    }

    /// #0051: a running job or an eject in flight still wins over a scan, so
    /// a scan alongside either is never cancelled for an eject that can't
    /// proceed anyway.
    @Test func aScanAlongsideAJobOrAnEjectStillRefusesForThoseAndNeverCancelsTheScan() {
        #expect(EjectPolicy.decide(isRunning: true, isScanning: true, isEjecting: false, hasDisc: true)
                == .refuse(reason: EjectPolicy.jobRunningReason))
        #expect(EjectPolicy.decide(isRunning: false, isScanning: true, isEjecting: true, hasDisc: true)
                == .refuse(reason: EjectPolicy.alreadyEjectingReason))
    }

    // MARK: - canEjectManually — full truth table

    @Test func canEjectManuallyTruthTable() {
        for running in Self.bools {
            for scanning in Self.bools {
                for ejecting in Self.bools {
                    for hasDisc in Self.bools {
                        // #0051: scanning no longer blocks — Eject cancels the scan first.
                        let expected = hasDisc && !running && !ejecting
                        #expect(
                            EjectPolicy.canEjectManually(isRunning: running, isScanning: scanning, isEjecting: ejecting, hasDisc: hasDisc) == expected,
                            "running: \(running), scanning: \(scanning), ejecting: \(ejecting), hasDisc: \(hasDisc)"
                        )
                    }
                }
            }
        }
    }
}
