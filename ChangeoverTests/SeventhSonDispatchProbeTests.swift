import Foundation
import Testing
@testable import Changeover

/// The launcher-PGC shape, decoded by the app's own `VMCommand`.
///
/// SEVENTH_SON, read off the raw device after #0219: seven labelled bonus
/// buttons across two menus, every one of them pointing at `vts7.pgc8` rather
/// than at a title. The same family as GLASS's `LinkPGN` and SIXSENSE's
/// `unresolved:Set` — buttons that exist, resolve, and reach nothing.
///
/// These are the real commands off that disc, confirmed against a hand decode.
/// They are pinned here for two reasons. They are the evidence in the open
/// question of whether the resolver should follow a dispatch chain — one disc
/// is not a family, and anyone revisiting it should be able to see exactly what
/// was known. And they pin `VMCommand` against instruction shapes no synthetic
/// fixture produces: a set-with-link, a `JumpSS` across domains, and a
/// conditional `JumpTT` that must stay unresolved.
struct LauncherPGCDecodingTests {

    /// A button: set a register to an immediate, then link to the launcher.
    /// The *link* is what `VMCommand` reports as the target; the immediate it
    /// sets is not modelled at all, which is the whole of why the chain stops
    /// here.
    @Test(arguments: ["7104000400010008", "71040004000b0008"])
    func abuttonSetsARegisterAndLinksToTheLauncher(hex: String) throws {
        let command = try #require(VMCommand(hex: hex))
        #expect(command.mnemonic == "Set")
        #expect(!command.isConditional)
        guard case .menu(let ref) = command.target(inVTS: 7) else {
            Issue.record("expected a menu target, got \(command.target(inVTS: 7))")
            return
        }
        #expect(ref.vts == 7)
        #expect(ref.pgc == 8, "every bonus button on this disc lands on pgc8")
    }

    /// The launcher hops to the table with a cross-domain `JumpSS`, which is
    /// the second indirection — one past what `PlayButtonResolver` follows.
    @Test func thelauncherJumpsToTheTableInAnotherDomain() throws {
        let command = try #require(VMCommand(hex: "3006000600c00000"))
        #expect(command.mnemonic == "JumpSS")
        guard case .menu(let ref) = command.target() else {
            Issue.record("expected a menu target")
            return
        }
        #expect(ref.domain == "VMGM")
        #expect(ref.pgc == 6)
    }

    /// The table's branches are **conditional**, and that is exactly why they
    /// are not followed today.
    ///
    /// `VMCommand.target(inVTS:)` refuses them by design: "A conditional jump's
    /// destination is chosen at playback time by a register this code does not
    /// model. Record it; never resolve it." Following this chain means
    /// modelling that register — which is the decision, stated as code.
    @Test func thetableBranchesAreConditionalAndStayUnresolved() throws {
        let command = try #require(VMCommand(hex: "30220000000a0400"))
        #expect(command.mnemonic == "JumpTT")
        #expect(command.isConditional, "comparison operator 2 — equal")
        guard case .unresolved = command.target(inVTS: 7) else {
            Issue.record("a conditional jump must not resolve: \(command.target(inVTS: 7))")
            return
        }
    }

    /// The table's fallback is unconditional and does resolve — it is the film.
    /// So the one title this chain can already name is the one nobody needed
    /// naming.
    @Test func thefallbackResolvesToTheFilm() throws {
        let command = try #require(VMCommand(hex: "3002000000090000"))
        #expect(command.isConditional == false)
        #expect(command.target(inVTS: 7) == .title(9))
    }
}
