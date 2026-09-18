import Foundation
import Testing
@testable import Changeover

/// The DVD VM command decoder — the one piece of menu intelligence that a
/// wrong answer from would be *plausible*: a mis-shifted field yields a
/// title number that exists, so nothing downstream can tell it is wrong.
/// Every case here therefore names the bit positions it is asserting, in
/// libdvdnav's numbering (bit 63 is the most significant bit of byte 0).
struct VMCommandTests {

    // MARK: - Bit extraction

    @Test func bitsIndexesFromTheTopOfByteZero() {
        let command = VMCommand(bytes: [0x30, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
        #expect(command.bits(63, 3) == 1, "command type is the top three bits of byte 0")
        #expect(command.bits(60, 1) == 1, "bit 60 is byte 0's bit 4 — the jump/link selector")
        #expect(command.bits(51, 4) == 2, "the operation is byte 1's low nibble")
        #expect(command.bits(22, 7) == 1, "bits 22…16 are byte 5's low seven")
    }

    @Test func hexRoundTrips() {
        let command = VMCommand(hex: "3002000000010000")
        #expect(command?.hex == "3002000000010000")
        #expect(command?.bytes == [0x30, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
    }

    /// A short, long or non-hex string is nil, never a zero-padded command —
    /// a truncated capture must not decode to "JumpTT 0".
    @Test(arguments: ["30020000000100", "3002000000010000ff", "3002000000zz0000", ""])
    func malformedHexIsRejected(_ hex: String) {
        #expect(VMCommand(hex: hex) == nil)
    }

    // MARK: - The jump family

    /// The command on a real disc's Play button, quoted in
    /// `docs/menu-intelligence.md` §8.3 and reproduced byte for byte by
    /// `Tools/menudump` against a synthetic VIDEO_TS.
    @Test func jumpTTNamesAVMGTitle() {
        let command = VMCommand(hex: "3002000000010000")!
        #expect(command.mnemonic == "JumpTT")
        #expect(command.target() == .title(1))
        #expect(command.target().titleNumber == 1)
    }

    @Test func jumpTTCarriesSevenBitsOfTitle() {
        let command = VMCommand(bytes: [0x30, 0x02, 0x00, 0x00, 0x00, 0x7F, 0x00, 0x00])
        #expect(command.target() == .title(127))
    }

    /// Title 0 is not a title. Nothing may resolve to it.
    @Test func jumpTTWithNoTitleIsUnresolved() {
        let command = VMCommand(bytes: [0x30, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(command.target().isUnresolved)
    }

    @Test func jumpVTSTitleIsRelativeToItsTitleSet() {
        let command = VMCommand(bytes: [0x30, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00])
        #expect(command.mnemonic == "JumpVTS_TT")
        #expect(command.target(inVTS: 1) == .titleInVTS(vts: 1, ttn: 2))
        #expect(command.target(inVTS: 1).titleNumber == nil, "a VTS-relative title is not a VMG title")
    }

    /// The chapter straddles two bytes: bits 41…40 are byte 2's low two and
    /// bits 39…32 are byte 3. Writing it into bytes 3 and 4 instead — the
    /// obvious wrong reading — produces chapter 0, which is why the
    /// zero-chapter case below is a refusal rather than a value.
    @Test func jumpVTSPTTSplitsTheChapterAcrossTwoBytes() {
        let command = VMCommand(bytes: [0x30, 0x05, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00])
        #expect(command.mnemonic == "JumpVTS_PTT")
        #expect(command.target(inVTS: 1) == .chapterInVTS(vts: 1, ttn: 1, ptt: 4))
    }

    @Test func jumpVTSPTTCarriesTenBitsOfChapter() {
        let command = VMCommand(bytes: [0x30, 0x05, 0x01, 0x02, 0x00, 0x01, 0x00, 0x00])
        #expect(command.target(inVTS: 2) == .chapterInVTS(vts: 2, ttn: 1, ptt: 258))
    }

    @Test func jumpVTSPTTWithChapterZeroIsUnresolved() {
        let command = VMCommand(bytes: [0x30, 0x05, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
        #expect(command.target(inVTS: 1).isUnresolved)
    }

    @Test func jumpSSNamesAMenuDomain() {
        // bits 23…22 == 2 → VTSM; bits 30…24 the VTS, bits 19…16 the menu id.
        let command = VMCommand(bytes: [0x30, 0x06, 0x00, 0x00, 0x01, 0x83, 0x00, 0x00])
        #expect(command.mnemonic == "JumpSS")
        guard case .menu(let ref) = command.target() else {
            Issue.record("expected a menu target, got \(command.target())")
            return
        }
        #expect(ref.domain == "VTSM")
        #expect(ref.vts == 1)
        #expect(ref.menuID == 3, "menu id 3 is the root menu (libdvdnav's DVD_MENU_Root)")
    }

    // MARK: - The link family

    @Test func linkPGCNTakesFifteenBitsFromTheLastTwoBytes() {
        let command = VMCommand(hex: "2004000000000002")!
        #expect(command.mnemonic == "LinkPGCN")
        #expect(command.target() == .menu(MenuTargetRef(domain: nil, vts: nil, pgc: 2, menuID: nil)))
    }

    @Test func linkPGCNCarriesLargePGCNumbers() {
        let command = VMCommand(bytes: [0x20, 0x04, 0x00, 0x00, 0x00, 0x00, 0x01, 0x2C])
        #expect(command.target() == .menu(MenuTargetRef(domain: nil, vts: nil, pgc: 300, menuID: nil)))
    }

    @Test func linkSubInstructionsAreNamedButNotResolved() {
        // Link family, operation 1, link sub-operation 16 = RSM (resume).
        let command = VMCommand(bytes: [0x20, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10])
        #expect(command.mnemonic == "RSM")
        #expect(command.target().isUnresolved)
    }

    // MARK: - Stream setting

    @Test func setSTNCarriesTheAudioStream() {
        let command = VMCommand(hex: "4100008100000000")!
        #expect(command.mnemonic == "SetSystem")
        #expect(command.target() == .streams(audio: 1, subpicture: nil))
    }

    @Test func setSTNCarriesTheSubpictureStream() {
        // Byte 4 bit 7 sets sub-picture; bits 6…0 are the stream.
        let command = VMCommand(bytes: [0x41, 0x00, 0x00, 0x00, 0x82, 0x00, 0x00, 0x00])
        #expect(command.target() == .streams(audio: nil, subpicture: 2))
    }

    @Test func setSTNThatSetsNothingIsUnresolved() {
        let command = VMCommand(bytes: [0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(command.target().isUnresolved)
    }

    // MARK: - What must never resolve

    /// A conditional jump's destination depends on a general-purpose
    /// register this code deliberately does not model. Resolving the jump
    /// half of the instruction anyway would produce a confident caption
    /// about a button that goes somewhere else — the one failure mode the
    /// decoder can have that nothing downstream would catch.
    @Test func aConditionalJumpIsRecordedNotResolved() {
        // Same JumpTT 1, but with a compare operator in bits 54…52.
        let command = VMCommand(bytes: [0x30, 0x12, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
        #expect(command.isConditional)
        #expect(command.target().isUnresolved)
        if case .unresolved(let mnemonic) = command.target() {
            #expect(mnemonic == "JumpTT", "the mnemonic is still recorded so the archive can count these")
        }
    }

    @Test func unknownFamiliesAreNamedByFamily() {
        let command = VMCommand(bytes: [0xA0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(command.target().isUnresolved)
        #expect(!command.mnemonic.isEmpty)
    }
}
