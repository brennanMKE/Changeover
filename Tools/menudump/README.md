# changeover-menudump

Reads a DVD's menu tables and button geometry and writes
`menus/structure.json` — the tier-1 half of `docs/menu-intelligence.md`.

```
make
build/changeover-menudump --disc /Volumes/BLOODSPORT --out ~/changeover-fixtures/bloodsport/menus
build/changeover-menudump --check          # dependency report, no disc needed
make test                                  # self-check against a synthetic VIDEO_TS
```

## What it produces

* `structure.json` — every menu PGC in the VMGM and VTSM domains with its
  entry type, cell sector ranges, and every button's rectangle, neighbours
  and **raw 8-byte VM command as 16 hex characters**. The helper never
  interprets a command; `Changeover/VMCommand.swift` does, and its tests are
  pinned against exactly these strings.
* `cells/<menu-id>.vob` — the decrypted menu video for each PGC, when
  libdvdread is available. `ffmpeg` turns these into the stills that Vision
  reads. Capped by `--max-bytes` (default 64 MB).

## Dependencies — none at build time, one optional at run time

Tier 1 needs **nothing installed**. IFO files are never encrypted, and NAV
packs — the sectors that carry the button table — are never CSS-scrambled
either, so the buttons, their targets, the title table and the chapter counts
all come out of plain file reads. A Mac with no DVD tooling at all still gets
a complete `structure.json`.

Only the *picture* is scrambled. Producing stills therefore needs
`libdvdread` (which decrypts through `libdvdcss`), and that is
`dlopen()`ed at runtime from the usual Homebrew locations —
`/opt/homebrew/lib`, then `/usr/local/lib`. It is never linked and never
bundled, in line with the project's rule that anything installable through
Homebrew is found on the host rather than shipped in the DMG.

When something is missing the output says which formula, by name:

```json
"helper": {
  "css": "unavailable",
  "libdvdread": "missing",
  "missing": ["libdvdread", "libdvdcss"],
  "install": ["brew install libdvdread", "brew install libdvdcss"]
}
```

`--check` prints the same information on its own, without a disc, which is
what a Settings dependency panel reads. **"Not installed" and "this disc has
no menus" are different answers** and the output keeps them apart: the first
is a non-empty `missing` array, the second is an empty `menus` array with
`missing` empty.

## Exit status

| code | meaning |
|---|---|
| 0 | `structure.json` written — with cells if libdvdread was there, without if not |
| 2 | bad arguments |
| 3 | no readable `VIDEO_TS` under `--disc` |
| 4 | could not write the output directory |

A non-zero exit is not a rip failure. Nothing in this tool is on the rip
path; a disc that defeats every line of it rips exactly as it does today.

## Licence

MIT, the same as the rest of the repository. This file contains no code from
`libdvdread`, `libdvdnav` or `libdvdcss`: the table layouts are written from
the published DVD-Video structures, and the VM command bit positions are
cited in `Changeover/VMCommand.swift` against libdvdnav's `vm/vmcmd.c` as a
reference, not copied from it. Because nothing GPL is linked or distributed —
`libdvdread` is `dlopen()`ed from the user's own Homebrew installation — no
GPL obligation attaches to the app or to this helper. (An earlier draft of
`docs/menu-intelligence.md` §2 assumed a vendored `libdvdread` inside the
DMG and made this file GPL-2.0-or-later; that decision was reversed.)

## Reading the NAV packs — the part that was wrong once

Tier 1 lives in the PCI packet of each cell's first NAV pack, and two
things about finding it are not obvious. Both were found by pointing the
first version of this tool at a real disc and getting **zero buttons off
29 menu PGCs** that carry 151 NAV packs full of them:

1. **`pci_gi` is 60 bytes, not 64.** A four-byte slip puts every
   highlight field inside the next structure, so `btn_ns` is read from
   `foac_btnn` — normally 0. The failure is silent and entirely
   plausible: "this menu has no buttons."
2. **The PCI packet is not at a fixed offset.** The pack header may carry
   stuffing and the system header is optional, so it is found by scanning
   for `00 00 01 BF` with substream id `0x00` at +6 (the DSI packet
   shares the start code and is told apart by that byte).

Every menu therefore carries a `nav` block saying where the packet was
found, what went wrong if nothing was, and the reader's own checks —
including `lbnMatches`, which compares `pci_gi.nv_pck_lbn` (the sector
address the *disc* wrote into the pack) with the sector the IFO sent us
to. That one is independent of every assumption the parser makes: four
bytes out and the number read back is not the sector number.

**Button groups.** `btngr_ns` is 1..3 and `btn_ns` is the count *per
group*; groups sit consecutively in `btnit`. Bloodsport declares two.
They are the same buttons laid out for different display aspects
(`btngr<n>_dsp_ty`: 4:3, wide, letterbox) and carry the **same commands**,
so tier 1 cannot depend on the choice. Group 1 is emitted, because stills
are rendered from the stored frame and group 1's rectangles are in that
same space; every group's display type is recorded, and so is whether the
groups' commands actually agree, so a disc where they do not is visible
rather than silently halved.

## Known gaps

* `structure.json` does not yet carry `featurePGC.audioControl` (§8.3). That
  field only feeds §5.2's shape-1 audio mapping, which has no captured disc
  behind it, and emitting a field nothing has verified would be worse than
  leaving it out.
* Motion menus get one still from the first cell's first VOBU. §1.2's
  second still for a late `hli_s_ptm` is not implemented.
* Button groups 2 and 3 (widescreen, letterbox) are counted in
  `buttonGroups` but only group 1's buttons are emitted.
