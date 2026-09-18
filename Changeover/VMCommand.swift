import Foundation

/// Menu intelligence, tier 1 — the DVD virtual machine's 8-byte instruction,
/// decoded far enough to answer one question: *which title does this button
/// start?*
///
/// Written from libdvdnav's `vm/vmcmd.c` mnemonic table and `vm/vm.c`'s
/// evaluator. Bit numbering follows those files exactly: the eight bytes are
/// read as one big-endian 64-bit word, **bit 63 is the most significant bit
/// of byte 0**, and `bits(start, count)` takes `count` bits ending at bit
/// `start - count + 1`. Every offset below is quoted in that numbering so it
/// can be checked against the reference implementation without re-deriving
/// anything.
///
/// Scope, deliberately small (`docs/menu-intelligence.md` §4.1 and "Not in
/// any slice"): the jump/link family that names a title, a chapter or
/// another menu, plus the stream-setting form. **The VM is not emulated.**
/// Conditional and register-driven forms decode to `.unresolved` carrying
/// their mnemonic, which is recorded in the archive so the corpus can show
/// how common they are rather than being guessed at.
nonisolated struct VMCommand: Equatable, Hashable, Sendable {

    /// The raw eight bytes, always kept.
    var bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = Array(bytes.prefix(8)) + Array(repeating: 0, count: max(0, 8 - bytes.count))
    }

    /// 16 hex characters, as `structure.json` records them. Any other
    /// length — a truncated capture, a hand-edited manifest — is `nil`
    /// rather than a silently zero-padded command.
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 16 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(8)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self.bytes = out
    }

    var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// The eight bytes as one big-endian word — the form libdvdnav's
    /// `vm_getbits` indexes into.
    var word: UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// `count` bits of `word` ending at bit `start - count + 1`, with bit 63
    /// the most significant bit of byte 0 — libdvdnav's `vm_getbits`.
    func bits(_ start: Int, _ count: Int) -> Int {
        guard count > 0, count <= 32, start < 64, start - count + 1 >= 0 else { return 0 }
        let shift = start - count + 1
        let mask: UInt64 = count == 64 ? ~0 : (UInt64(1) << UInt64(count)) - 1
        return Int((word >> UInt64(shift)) & mask)
    }

    // MARK: - Decoding

    /// Bits 63…61: the command family.
    var commandType: Int { bits(63, 3) }

    /// Bit 60, inside a type-1 instruction: set means the jump/call family,
    /// clear means the link family.
    var isJumpFamily: Bool { bits(60, 1) == 1 }

    /// Bits 51…48: the operation inside the family.
    var operation: Int { bits(51, 4) }

    /// True when the instruction carries a comparison that has to run before
    /// the jump does. Such a button's destination depends on a register this
    /// code does not model, so its target is `.unresolved` even when the
    /// jump half of the instruction looks readable.
    ///
    /// libdvdnav puts the comparison operator in bits 54…52 (byte 1's high
    /// nibble) for every family that has one — `print_if_version_1/2/3` all
    /// read `vm_getbits(command, 54, 3)`. Zero is the unconditional form.
    /// Type 0 (the special instructions) carries no comparison at all.
    var isConditional: Bool {
        commandType != 0 && bits(54, 3) != 0
    }

    /// libdvdnav's mnemonic for this instruction, for the archive and for
    /// `.unresolved`. Not exhaustive: instructions outside the jump/link
    /// family are named by family, which is all the archive needs to show
    /// how often they occur.
    var mnemonic: String {
        switch commandType {
        case 0:
            switch operation {
            case 0: return "NOP"
            case 1: return "Goto"
            case 2: return "Break"
            case 3: return "SetTmpPML"
            default: return "Special(\(operation))"
            }
        case 1 where isJumpFamily:
            switch operation {
            case 1: return "Exit"
            case 2: return "JumpTT"
            case 3: return "JumpVTS_TT"
            case 5: return "JumpVTS_PTT"
            case 6: return "JumpSS"
            case 8: return "CallSS"
            default: return "Jump(\(operation))"
            }
        case 1:
            switch operation {
            case 1: return VMCommand.linkSubMnemonic(bits(7, 8))
            case 4: return "LinkPGCN"
            case 5: return "LinkPTTN"
            case 6: return "LinkPGN"
            case 7: return "LinkCN"
            default: return "Link(\(operation))"
            }
        case 2: return "SetSystem"
        case 3: return "Set"
        case 4: return "SetCompareLink"
        case 5, 6: return "CompareSetLink"
        default: return "Unknown(\(commandType))"
        }
    }

    private static func linkSubMnemonic(_ op: Int) -> String {
        let table: [Int: String] = [
            0: "LinkNoLink", 1: "LinkTopC", 2: "LinkNextC", 3: "LinkPrevC",
            5: "LinkTopPG", 6: "LinkNextPG", 7: "LinkPrevPG",
            9: "LinkTopPGC", 10: "LinkNextPGC", 11: "LinkPrevPGC",
            12: "LinkGoUpPGC", 13: "LinkTailPGC", 16: "RSM",
        ]
        return table[op] ?? "LinkSub(\(op))"
    }

    /// Where this button goes.
    ///
    /// `vts` is the title set the menu carrying the button belongs to, so
    /// `JumpVTS_TT`/`JumpVTS_PTT` can name it; `MenuStructure` supplies it
    /// and then lifts the VTS-relative number to a VMG title through
    /// `TT_SRPT`. Pass `nil` from a test that only cares about the raw form.
    func target(inVTS vts: Int? = nil) -> ButtonTarget {
        // A conditional jump's destination is chosen at playback time by a
        // register this code does not model. Record it; never resolve it.
        guard !isConditional else { return .unresolved(mnemonic: mnemonic) }

        switch commandType {
        case 1 where isJumpFamily:
            switch operation {
            // JumpTT <title>: bits 22…16, the VMG title number — the same
            // number HandBrake indexes TT_SRPT with, which is the claim the
            // corpus invariant in DiscCorpusTests exists to prove.
            case 2:
                let title = bits(22, 7)
                return title > 0 ? .title(title) : .unresolved(mnemonic: mnemonic)
            // JumpVTS_TT <ttn>: bits 22…16, relative to this menu's VTS.
            case 3:
                let ttn = bits(22, 7)
                return ttn > 0 ? .titleInVTS(vts: vts ?? 0, ttn: ttn) : .unresolved(mnemonic: mnemonic)
            // JumpVTS_PTT <ttn>:<ptt>: title bits 22…16, chapter bits 41…32.
            case 5:
                let ttn = bits(22, 7)
                let ptt = bits(41, 10)
                guard ttn > 0, ptt > 0 else { return .unresolved(mnemonic: mnemonic) }
                return .chapterInVTS(vts: vts ?? 0, ttn: ttn, ptt: ptt)
            // JumpSS: bits 23…22 select the sub-domain.
            case 6:
                switch bits(23, 2) {
                case 0:
                    return .menu(MenuTargetRef(domain: "FP", vts: nil, pgc: nil, menuID: nil))
                case 1:
                    return .menu(MenuTargetRef(domain: "VMGM", vts: nil, pgc: nil, menuID: bits(19, 4)))
                case 2:
                    return .menu(MenuTargetRef(domain: "VTSM", vts: bits(30, 7), pgc: nil, menuID: bits(19, 4)))
                default:
                    return .menu(MenuTargetRef(domain: "VMGM", vts: nil, pgc: bits(46, 15), menuID: nil))
                }
            default:
                return .unresolved(mnemonic: mnemonic)
            }

        case 1:
            // LinkPGCN <pgc>: bits 14…0, another PGC in this menu's own
            // language unit. §4.1 follows exactly one such indirection, in
            // PlayButtonResolver — never a chain.
            if operation == 4 {
                let pgc = bits(14, 15)
                return pgc > 0
                    ? .menu(MenuTargetRef(domain: nil, vts: vts, pgc: pgc, menuID: nil))
                    : .unresolved(mnemonic: mnemonic)
            }
            return .unresolved(mnemonic: mnemonic)

        case 2:
            // System set. Sub-operation 1 (bits 59…56) is SetSTN: byte 3
            // carries the audio stream, byte 4 the sub-picture stream, each
            // with bit 7 as "this field is being set" and bits 6…0 as the
            // value. This is the least-verified decode in this file — no
            // captured disc has exercised it yet — so it only ever produces
            // a caption beside a picker the user still controls (§5.3).
            guard bits(59, 4) == 1 else { return .unresolved(mnemonic: mnemonic) }
            let audio = bits(39, 1) == 1 ? bits(38, 7) : nil
            let subpicture = bits(31, 1) == 1 ? bits(30, 7) : nil
            guard audio != nil || subpicture != nil else { return .unresolved(mnemonic: mnemonic) }
            return .streams(audio: audio, subpicture: subpicture)

        default:
            return .unresolved(mnemonic: mnemonic)
        }
    }
}

/// Where a menu button goes, once its command has been decoded.
nonisolated enum ButtonTarget: Equatable, Hashable, Sendable {
    /// `JumpTT n` — VMG title `n`, the number HandBrake also uses.
    case title(Int)
    /// `JumpVTS_TT` before `TT_SRPT` has lifted it to a VMG title.
    case titleInVTS(vts: Int, ttn: Int)
    /// A chapter of a VMG title.
    case chapter(title: Int, ptt: Int)
    /// `JumpVTS_PTT` before `TT_SRPT` has lifted it.
    case chapterInVTS(vts: Int, ttn: Int, ptt: Int)
    /// `LinkPGCN` / `JumpSS` to another menu.
    case menu(MenuTargetRef)
    /// `SetSTN` — an audio and/or sub-picture stream number.
    case streams(audio: Int?, subpicture: Int?)
    /// Anything this build does not name, with libdvdnav's mnemonic.
    case unresolved(mnemonic: String)

    /// The VMG title this button starts, if it starts one at all. The play
    /// button is chosen from exactly these.
    var titleNumber: Int? {
        if case .title(let n) = self { return n }
        return nil
    }

    var isUnresolved: Bool {
        if case .unresolved = self { return true }
        return false
    }
}

/// A menu another button jumps or links to.
nonisolated struct MenuTargetRef: Codable, Equatable, Hashable, Sendable {
    /// `"VMGM"`, `"VTSM"`, `"FP"` (first play), or `nil` for a `LinkPGCN`
    /// that stays inside the menu's own language unit.
    var domain: String?
    var vts: Int?
    var pgc: Int?
    /// The `JumpSS ... (menu k)` entry-type number: 2 title, 3 root,
    /// 4 sub-picture, 5 audio, 6 angle, 7 chapter.
    var menuID: Int?
}
