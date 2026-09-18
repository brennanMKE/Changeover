#!/usr/bin/env python3
"""Check the NAV pack offsets against the bytes, independently of menudump.c.

    Tools/menudump/check-nav-offsets.py <dir containing VIDEO_TS>

Why this exists. The first version of this tool read zero buttons off a real
disc because `pci_gi` was assumed to be 64 bytes when it is 60, and the
synthetic test disc passed anyway — because make-test-disc.py wrote the
buttons at exactly the offset menudump.c read them from. The generator and
the parser agreed, and both were wrong. A round trip cannot catch a shared
assumption.

So this script does not round-trip anything. It reads the generated VOB as
raw bytes, walks the structure from the start code forward by field sizes it
states itself, and asserts two things:

  * at the correct offset the button table is there;
  * at the OLD offset (four bytes later) `btn_ns` reads 0 — which is exactly
    the silent, plausible "this menu has no buttons" that shipped.

The second assertion is the regression guard. If someone reinstates the old
arithmetic, this fails loudly rather than producing an empty archive.
"""

import sys
import os

BLOCK = 2048
PCI_GI_SIZE = 60          # nv_pck_lbn 4 + vobu_cat 2 + zero1 2 + uop_ctl 4
                          # + s_ptm 4 + e_ptm 4 + se_e_ptm 4 + e_eltm 4 + isrc 32
WRONG_PCI_GI_SIZE = 64    # the bug
NSML_AGLI_SIZE = 36
HL_GI_SIZE = 22
BTN_COLIT_SIZE = 24
BTNI_SIZE = 18


def find_pci(sector):
    for i in range(0, 1024):
        if sector[i:i + 4] == b"\x00\x00\x01\xBF" and sector[i + 6] == 0x00:
            return i
    return -1


def main(root):
    path = os.path.join(root, "VIDEO_TS", "VTS_01_0.VOB")
    with open(path, "rb") as f:
        sector = f.read(BLOCK)

    assert sector[0:4] == b"\x00\x00\x01\xBA", "not a pack"
    pci_start = find_pci(sector)
    assert pci_start >= 0, "no PCI packet found by start code"
    pci = pci_start + 7

    hl_gi = pci + PCI_GI_SIZE + NSML_AGLI_SIZE
    btngr_ns = (sector[hl_gi + 0x0E] >> 4) & 0x03
    btn_ns = sector[hl_gi + 0x11] & 0x3F
    btnit = hl_gi + HL_GI_SIZE + BTN_COLIT_SIZE

    assert btngr_ns == 2, f"expected 2 button groups, read {btngr_ns}"
    assert btn_ns == 4, f"expected 4 buttons per group, read {btn_ns}"

    # Group 1's first button must be the Play Movie JumpTT 1.
    command = sector[btnit + 10:btnit + 18].hex()
    assert command == "3002000000010000", f"first button command is {command}"

    # Group 2 sits at index 36 // btngr_ns — the table is partitioned
    # equally among the declared groups, not packed at the btn_ns stride.
    g2 = btnit + (36 // btngr_ns) * BTNI_SIZE
    assert sector[g2 + 10:g2 + 18].hex() == command, "group 2 command differs"

    # nv_pck_lbn is the pack's own address: 0 for the first sector.
    lbn = int.from_bytes(sector[pci:pci + 4], "big")
    assert lbn == 0, f"nv_pck_lbn is {lbn}, not the sector number"

    # The regression guard: the old arithmetic reads a byte that is 0.
    wrong_hl_gi = pci + WRONG_PCI_GI_SIZE + NSML_AGLI_SIZE
    wrong_btn_ns = sector[wrong_hl_gi + 0x11] & 0x3F
    assert wrong_btn_ns == 0, (
        "the old (64-byte pci_gi) offset no longer reads 0 buttons, so this "
        "check has stopped guarding the bug it was written for"
    )

    print(f"nav offsets OK: pci at {pci_start}, hl_gi at {hl_gi}, btnit at {btnit}, "
          f"{btngr_ns} groups x {btn_ns} buttons; old offset still reads 0")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/test-disc")
