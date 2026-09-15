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

    /// #0045 review: a `HandBrakeCLI --scan` holds the disc and cannot be
    /// cancelled yet (#0046), so an eject mid-scan is refused.
    @Test func aScanInProgressRefusesForTheScan() {
        let decision = EjectPolicy.decide(isRunning: false, isScanning: true, isEjecting: false, hasDisc: true)
        #expect(decision == .refuse(reason: "The disc is still being scanned — wait for the scan to finish before ejecting."))
        #expect(decision.refusalReason == "The disc is still being scanned — wait for the scan to finish before ejecting.")
    }

    // MARK: - canEjectManually — full truth table

    @Test func canEjectManuallyTruthTable() {
        for running in Self.bools {
            for scanning in Self.bools {
                for ejecting in Self.bools {
                    for hasDisc in Self.bools {
                        let expected = hasDisc && !running && !scanning && !ejecting
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
