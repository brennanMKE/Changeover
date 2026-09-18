#!/usr/bin/env python3
"""Build a synthetic VIDEO_TS that exercises every byte offset menudump reads.

    Tools/menudump/make-test-disc.py <dir>

The dev Mac has no DVD drive, no libdvdread and no disc, so the only way to
find an off-by-one in an IFO table offset or a NAV pack's button packing
before the tool is pointed at a real disc is to *write* those structures from
the published layout and read them back. That is what this does: it lays out
a VMGI with a title table and a title menu, a VTSI with a root menu, a
chapter menu and one non-entry PGC, and the NAV packs whose highlight
information carries the buttons — a JumpTT, three LinkPGCNs and six
JumpVTS_PTTs.

What this proves and what it does not: it proves menudump finds each table
where the specification says it is and unpacks the 10-bit rectangles and the
8-byte commands correctly *against the same published layout*. It cannot
prove a real disc is authored the way the specification says. Only joe can,
which is why the corpus invariants in DiscCorpusTests are written to run over
captured discs and this fixture is labelled synthetic everywhere it appears.
"""

import os
import struct
import sys

BLOCK = 2048


def be16(v):
    return struct.pack(">H", v)


def be32(v):
    return struct.pack(">I", v)


def sector(data):
    assert len(data) <= BLOCK, len(data)
    return data + b"\x00" * (BLOCK - len(data))


# ---------------------------------------------------------------- commands

def jump_tt(title):
    """Type 1, jump family (bit 60), operation 2; title in bits 22..16."""
    return bytes([0x30, 0x02, 0x00, 0x00, 0x00, title, 0x00, 0x00])


def jump_vts_ptt(ttn, ptt):
    """Operation 5; title in bits 22..16 (byte 5), chapter in bits 41..32.

    Bits 41..32 straddle byte 2 (which holds bits 47..40) and byte 3 (bits
    39..32), so the chapter's top two bits go in byte 2 and its low eight in
    byte 3 — not bytes 3 and 4. Writing it the obvious wrong way produced a
    chapter of 0, which VMCommand.decode correctly refused as unresolved;
    that refusal is what caught this.
    """
    return bytes([0x30, 0x05, (ptt >> 8) & 0x03, ptt & 0xFF, 0x00, ttn, 0x00, 0x00])


def link_pgcn(pgc):
    """Type 1, link family (bit 60 clear), operation 4; PGC in bits 14..0."""
    return bytes([0x20, 0x04, 0x00, 0x00, 0x00, 0x00, (pgc >> 8) & 0x7F, pgc & 0xFF])


def set_stn_audio(stream):
    """Type 2, sub-operation 1; byte 3 bit 7 sets audio, bits 6..0 the value."""
    return bytes([0x41, 0x00, 0x00, 0x80 | (stream & 0x7F), 0x00, 0x00, 0x00, 0x00])


# ---------------------------------------------------------------- nav pack

# Sizes from libdvdread's nav_types.h, written out as a field list rather
# than as constants, because the whole reason this file exists is that
# pci_gi was assumed to be 64 bytes when it is 60 — a four-byte slip that
# made the parser read zero buttons off a disc with 151 NAV packs.
PCI_GI_FIELDS = [
    ("nv_pck_lbn", 4), ("vobu_cat", 2), ("zero1", 2), ("vobu_uop_ctl", 4),
    ("vobu_s_ptm", 4), ("vobu_e_ptm", 4), ("vobu_se_e_ptm", 4),
    ("e_eltm", 4), ("vobu_isrc", 32),
]
PCI_GI_SIZE = sum(size for _, size in PCI_GI_FIELDS)     # 60
NSML_AGLI_SIZE = 4 * 9                                   # 36
HL_GI_SIZE = 22
BTN_COLIT_SIZE = 24
BTNI_SIZE = 18
assert PCI_GI_SIZE == 60, PCI_GI_SIZE


def nav_pack(groups, lbn=0):
    """One 2048-byte NAV pack whose PCI carries one or more button groups.

    groups: list of button groups; each is a list of
            (x0, y0, x1, y1, auto, up, down, left, right, command).
            Every group must hold the same number of buttons — btn_ns is the
            count *per group* and the groups sit consecutively in btnit.
    lbn:    the pack's own sector address, written into pci_gi.nv_pck_lbn.
            menudump checks it against the sector it asked for, which is the
            one self-check that is independent of this file: if the PCI data
            offset is wrong, the number read back is not the sector number.
    """
    data = bytearray(BLOCK)

    data[0:4] = b"\x00\x00\x01\xBA"                 # pack header, 14 bytes
    data[0x0E:0x12] = b"\x00\x00\x01\xBB"           # system header, 24 bytes
    data[0x12:0x14] = be16(0x0012)
    pci_start = 0x26
    data[pci_start:pci_start + 4] = b"\x00\x00\x01\xBF"
    data[pci_start + 4:pci_start + 6] = be16(0x03D4)
    data[pci_start + 6] = 0x00                       # substream: PCI
    data[0x400:0x404] = b"\x00\x00\x01\xBF"         # DSI PES
    data[0x404:0x406] = be16(0x03FA)
    data[0x406] = 0x01                               # substream: DSI

    pci = pci_start + 7
    data[pci:pci + 4] = be32(lbn)                    # pci_gi.nv_pck_lbn

    hl_gi = pci + PCI_GI_SIZE + NSML_AGLI_SIZE
    per_group = len(groups[0]) if groups else 0
    assert all(len(g) == per_group for g in groups), "groups must be the same size"
    assert len(groups) * per_group <= 36

    data[hl_gi + 0x0E] = (len(groups) << 4) | 0x01   # btngr_ns, btngr1_dsp_ty = 4:3
    data[hl_gi + 0x0F] = (0x02 << 4) if len(groups) > 1 else 0   # btngr2_dsp_ty = wide
    data[hl_gi + 0x11] = per_group & 0x3F            # btn_ns, per group
    data[hl_gi + 0x14] = 1 if per_group else 0       # fosl_btnn

    btnit = hl_gi + HL_GI_SIZE + BTN_COLIT_SIZE
    index = 0
    for group in groups:
        for (x0, y0, x1, y1, auto, up, down, left, right, command) in group:
            base = btnit + index * BTNI_SIZE
            data[base + 0] = ((x0 >> 4) & 0x3F)
            data[base + 1] = ((x0 & 0x0F) << 4) | ((x1 >> 8) & 0x03)
            data[base + 2] = x1 & 0xFF
            data[base + 3] = ((auto & 0x03) << 6) | ((y0 >> 4) & 0x3F)
            data[base + 4] = ((y0 & 0x0F) << 4) | ((y1 >> 8) & 0x03)
            data[base + 5] = y1 & 0xFF
            data[base + 6] = up & 0x3F
            data[base + 7] = down & 0x3F
            data[base + 8] = left & 0x3F
            data[base + 9] = right & 0x3F
            data[base + 10:base + 18] = command
            index += 1
    return bytes(data)


# -------------------------------------------------------------------- PGCs

def pgc(cells, entry_id):
    """A PGC header plus its cell playback table.

    Header is 0xEC bytes; cell_playback_offset at 0xE8 points just past it.
    Each cell is 24 bytes with first_sector at +0x08 and last_sector at +0x14.
    """
    header = bytearray(0xEC)
    header[2] = 1                                   # nr_of_programs
    header[3] = len(cells)                          # nr_of_cells
    header[0xE8:0xEA] = be16(0xEC)                  # cell_playback_offset
    body = bytearray()
    for first, last in cells:
        cell = bytearray(24)
        cell[0x08:0x0C] = be32(first)
        cell[0x14:0x18] = be32(last)
        body += cell
    return bytes(header + body), entry_id


def pgci_ut(pgcs, lang=b"en"):
    """A menu PGC unit table: one language unit holding `pgcs`."""
    lu_count = 1
    header = bytearray(8)
    header[0:2] = be16(lu_count)

    srp_size = 8 * len(pgcs)
    pgcit = bytearray(8 + srp_size)
    pgcit[0:2] = be16(len(pgcs))
    offset = 8 + srp_size
    bodies = bytearray()
    for index, (body, entry_id) in enumerate(pgcs):
        base = 8 + index * 8
        pgcit[base] = entry_id
        pgcit[base + 4:base + 8] = be32(offset)
        bodies += body
        offset += len(body)
    pgcit += bodies
    pgcit[4:8] = be32(len(pgcit) - 1)

    lu = bytearray(8)
    lu[0:2] = lang
    lu[3] = 0x80
    lu[4:8] = be32(8 + 8)                           # PGCIT starts after the LU table
    table = header + lu + pgcit
    table[4:8] = be32(len(table) - 1)
    return bytes(table)


# ------------------------------------------------------------------- build

def main(root):
    video_ts = os.path.join(root, "VIDEO_TS")
    os.makedirs(video_ts, exist_ok=True)

    # ---- VMGI: title table at sector 1, menu table at sector 2
    vmgi_mat = bytearray(BLOCK)
    vmgi_mat[0:12] = b"DVDVIDEO-VMG"
    vmgi_mat[0x3E:0x40] = be16(1)                   # one title set
    vmgi_mat[0xC4:0xC8] = be32(1)                   # tt_srpt
    vmgi_mat[0xC8:0xCC] = be32(2)                   # vmgm_pgci_ut
    vmgi_mat[0x100:0x102] = b"\x00\x00"             # NTSC, 720x480

    tt_srpt = bytearray(8 + 12)
    tt_srpt[0:2] = be16(1)
    tt_srpt[4:8] = be32(len(tt_srpt) - 1)
    entry = tt_srpt
    entry[8] = 0x3F                                 # playback type
    entry[9] = 1                                    # angles
    entry[10:12] = be16(23)                         # chapters
    entry[14] = 1                                   # title set
    entry[15] = 1                                   # vts title number

    vmgm_title_menu = pgc([(0, 9)], 0x82)
    vmgm_ut = pgci_ut([vmgm_title_menu])

    with open(os.path.join(video_ts, "VIDEO_TS.IFO"), "wb") as f:
        f.write(sector(bytes(vmgi_mat)))
        f.write(sector(bytes(tt_srpt)))
        f.write(sector(vmgm_ut))

    # VMGM menu video: one NAV pack, one button, straight to title 1.
    with open(os.path.join(video_ts, "VIDEO_TS.VOB"), "wb") as f:
        f.write(nav_pack([[(100, 100, 300, 130, 0, 1, 1, 1, 1, jump_tt(1))]], lbn=0))
        f.write(b"\x00" * BLOCK * 9)

    # ---- VTSI: root menu, chapter menu, one non-entry PGC
    vtsi_mat = bytearray(BLOCK)
    vtsi_mat[0:12] = b"DVDVIDEO-VTS"
    vtsi_mat[0xD0:0xD4] = be32(1)                   # vtsm_pgci_ut
    vtsi_mat[0x100:0x102] = b"\x00\x00"

    root_menu = pgc([(0, 9)], 0x83)
    chapter_menu = pgc([(10, 19)], 0x87)
    language_menu = pgc([(20, 29)], 0x85)
    orphan = pgc([(30, 39)], 0x00)
    vtsm_ut = pgci_ut([root_menu, chapter_menu, language_menu, orphan])

    with open(os.path.join(video_ts, "VTS_01_0.IFO"), "wb") as f:
        f.write(sector(bytes(vtsi_mat)))
        f.write(sector(vtsm_ut))

    root_buttons = [
        (388, 148, 550, 178, 0, 4, 2, 1, 1, jump_tt(1)),        # Play Movie
        (388, 188, 550, 218, 0, 1, 3, 2, 2, link_pgcn(2)),      # Scene Selections
        (388, 228, 550, 258, 0, 2, 4, 3, 3, link_pgcn(4)),      # Special Features
        (388, 268, 550, 298, 0, 3, 1, 4, 4, link_pgcn(3)),      # Languages
    ]
    chapter_buttons = [
        (137, 180, 260, 210, 0, 1, 4, 3, 2, jump_vts_ptt(1, 1)),
        (290, 180, 420, 210, 0, 2, 5, 1, 3, jump_vts_ptt(1, 2)),
        (440, 180, 570, 210, 0, 3, 6, 2, 1, jump_vts_ptt(1, 3)),
        (137, 316, 260, 346, 0, 1, 1, 6, 5, jump_vts_ptt(1, 4)),
        (290, 316, 420, 346, 0, 2, 2, 4, 6, jump_vts_ptt(1, 5)),
        (440, 316, 570, 346, 0, 3, 3, 5, 4, jump_vts_ptt(1, 6)),
    ]
    language_buttons = [
        (200, 260, 340, 290, 0, 1, 2, 1, 1, set_stn_audio(0)),
        (200, 300, 340, 330, 0, 1, 2, 2, 2, set_stn_audio(1)),
    ]
    # The root menu declares TWO button groups — a 4:3 layout and a
    # widescreen one with the same commands at shifted rectangles — because
    # Bloodsport declares two and a reader that silently took half the table
    # (or read past it) would otherwise never be caught here.
    root_wide = [
        (x0 - 40, y0, x1 + 40, y1, auto, up, down, left, right, command)
        for (x0, y0, x1, y1, auto, up, down, left, right, command) in root_buttons
    ]
    with open(os.path.join(video_ts, "VTS_01_0.VOB"), "wb") as f:
        f.write(nav_pack([root_buttons, root_wide], lbn=0))
        f.write(b"\x00" * BLOCK * 9)
        f.write(nav_pack([chapter_buttons], lbn=10))
        f.write(b"\x00" * BLOCK * 9)
        f.write(nav_pack([language_buttons], lbn=20))
        f.write(b"\x00" * BLOCK * 9)
        f.write(b"\x00" * BLOCK * 10)

    print(f"wrote {video_ts}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/test-disc")
