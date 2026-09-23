import Foundation
import Testing
@testable import Changeover

/// Die Hard was ripped twice on 2026-09-23.
///
/// The first rip finished and landed correctly; its eject was refused
/// (`kDAReturnNotPermitted`); ten seconds later the app started ripping the
/// same disc again. Two guards should each have stopped it, and both had the
/// same root cause in different clothes.
struct ReRipGuardTests {

    static func insertion(discID: String?, volume: String, device: String = "disk9") -> DiscInsertion {
        DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/\(volume)"),
            deviceNode: device,
            discID: discID
        )
    }

    /// The bug, stated as the type's own behaviour: `DiscInsertion` mints a
    /// fresh token per insertion event (#0034), so the same physical disc
    /// re-reported is a *different* value and a `Set<DiscInsertion>` no
    /// longer contains it.
    @Test func theSameDiscReReportedIsNotEqualToItself() {
        let first = Self.insertion(discID: "diehard", volume: "DIEHARD")
        let second = Self.insertion(discID: "diehard", volume: "DIEHARD")
        #expect(first != second, "this is by design — #0034 needs it")
        #expect(!Set([first]).contains(second), "which is exactly how the re-rip got through")
    }

    /// So "have we already ripped this disc" keys on identity instead, which
    /// survives the re-report.
    @Test func identitySurvivesTheDiscBeingReReported() {
        let first = Self.insertion(discID: "diehard", volume: "DIEHARD")
        let second = Self.insertion(discID: "diehard", volume: "DIEHARD", device: "disk11")
        #expect(RipFlowController.discIdentity(first) == RipFlowController.discIdentity(second))
        #expect(Set([RipFlowController.discIdentity(first)])
            .contains(RipFlowController.discIdentity(second)))
    }

    /// A disc with no readable id falls back to its volume name, which is
    /// still stable across a re-report.
    @Test func aDiscWithNoIDFallsBackToItsVolumeName() {
        let first = Self.insertion(discID: nil, volume: "DIEHARD")
        let second = Self.insertion(discID: nil, volume: "DIEHARD")
        #expect(RipFlowController.discIdentity(first) == "DIEHARD")
        #expect(RipFlowController.discIdentity(first) == RipFlowController.discIdentity(second))
    }

    /// And two genuinely different discs stay different.
    @Test func differentDiscsKeepDifferentIdentities() {
        #expect(RipFlowController.discIdentity(Self.insertion(discID: "a", volume: "DIEHARD"))
             != RipFlowController.discIdentity(Self.insertion(discID: "b", volume: "FARGO")))
        #expect(RipFlowController.discIdentity(Self.insertion(discID: nil, volume: "DIEHARD"))
             != RipFlowController.discIdentity(Self.insertion(discID: nil, volume: "FARGO")))
    }

    /// The other guard: the library answer is keyed so that a finished rip
    /// forces it to be asked again. Without the epoch the key is (film,
    /// folder) — neither of which changes when the film lands in the library
    /// — so the duplicate notice kept reporting what it found *before* the
    /// encode, and the disc looked fresh.
    @Test func theLibraryKeyChangesWhenARipFinishes() {
        let before = LibraryCheckKey(movieID: 562, moviesPath: "/Movies", epoch: 0)
        let after = LibraryCheckKey(movieID: 562, moviesPath: "/Movies", epoch: 1)
        #expect(before != after, "a finished rip must re-ask the library")

        // And the same film, same folder, same epoch is still one question.
        #expect(before == LibraryCheckKey(movieID: 562, moviesPath: "/Movies", epoch: 0))
    }
}
