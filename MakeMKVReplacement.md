# Replacing MakeMKV — requirements

Status: **research brief**, not a plan. Nothing here is scheduled. The purpose is
to state precisely what MakeMKV does for Changeover so the replacement options
can be evaluated against a fixed target rather than against an impression.

Written 2026-09-11. Evidence comes from the current source, `Roadmap.md`, and two
real disc scans run on `joe` that day (*Fargo* Special Edition and *The IT Crowd*
Season 1).

---

## 1. Why this document exists

MakeMKV is one of two hard runtime dependencies (`AppSettings.makemkvconPath`,
`AppSettings.handbrakePath`). It is closed source, it is not on Homebrew as a
formula the app controls, and its beta key **expires every couple of months** —
which is the single most common failure mode the app has, and the reason
[#0009](issues/0009.md) exists.

Replacing it is not obviously worth it. This document exists so that judgment can
be made on facts.

---

## 2. What MakeMKV does for Changeover today

### 2.1 Current invocation

One command, in `RipController.rip` (`RipController.swift:19-24`):

```
makemkvcon mkv disc:0 all <outputDir>
```

That single line is doing five separable jobs:

1. **Open the optical device** and identify the disc.
2. **Decrypt** — CSS for DVD, AACS/BD+ for Blu-ray.
3. **Parse disc structure** — titles, chapters, cells, streams, from the IFO files.
4. **Select** what to extract (`all` today; Phase 2 changes this to specific titles).
5. **Remux losslessly into Matroska** — no re-encode, streams copied as-is.

A replacement must cover all five. They are usually four or five different
libraries.

### 2.2 Planned invocation (Phase 2)

`Roadmap.md` Phase 2 adds a second command:

```
makemkvcon -r info disc:0
```

parsed into `DiscInfo` / `DiscTitle` / `DiscStream`. This is a **deeper**
dependency than the rip — it binds to MakeMKV's data model, not just its binary.
See §4.

---

## 3. Functional requirements

Numbered so options can be scored against them. R1–R6 are Phase 1. R7–R10 are
Phase 2 and are what make the replacement genuinely hard.

### R1 — Enumerate optical drives

Identify the drive, its vendor/product string, and whether media is present.
Today this arrives as `DRV:` rows:

```
DRV:0,0,999,0,"DVD+R-DL PLDS DVD+-RW DS-8A8SH KD13 CN0YTVN95508126Q40XHA00","",""
```

Changeover only ever uses `disc:0`, so single-drive support is sufficient for now.
Phase 3 (unattended multi-disc) does not change this — it is one drive, many discs
in sequence.

### R2 — Decrypt CSS (DVD)

Mandatory. Every commercial DVD in the test library is CSS-scrambled.

`libdvdcss` (already installed on joe, v1.6.0, `/opt/homebrew/lib/libdvdcss.2.dylib`)
covers this. It is the well-trodden path — it is what VLC and HandBrake use.

### R3 — Decrypt AACS / BD+ (Blu-ray)

**Decision point, not a requirement yet.** Changeover is DVD-only today:
`DVDMonitor` triggers on the presence of a `VIDEO_TS` folder
(`DVDMonitor.swift:21-22`), which no Blu-ray has, and the drive on joe is a
DVD±RW with no BD capability.

If Blu-ray is ever in scope this is the hardest single item in the document —
`libaacs` needs a key database that is not distributable, and BD+ needs a VM
implementation. **Recommend explicitly scoping Blu-ray out** and revisiting only
if the hardware changes. If it is out of scope, say so in the roadmap, because it
changes the answer to "is replacing MakeMKV feasible" from *hard* to *moderate*.

### R4 — Parse disc structure

Read `VIDEO_TS/VIDEO_TS.IFO` and `VTS_nn_0.IFO` to enumerate titles, program
chains (PGCs), cells, chapters, and durations.

`libdvdread` is the standard answer. `libdvdnav` adds menu/navigation handling,
which Changeover does not need.

**This must be robust against malformed discs.** Not theoretical — the IT Crowd
disc produced this on a first read:

```
MSG:3002,0,2,"Calculated BUP offset for VTS #1 does not match one in IFO header."
MSG:3002,0,2,"Calculated BUP offset for VTS #2 does not match one in IFO header."
```

MakeMKV noted the damage and carried on. Any replacement inherits the obligation
to decide what to do in that case, and in every other malformed-disc case, from
then on. **This is the requirement most likely to be underestimated.** It is not
one bug; it is an open-ended maintenance commitment that MakeMKV has been
absorbing since 2008.

### R5 — Extract title streams

Read the selected title's cells in playback order, descrambling as it goes, and
produce the elementary streams. Requires correct handling of:

- Cell ordering within a PGC (not simply sequential on disc).
- **Seamless multi-angle** discs — cells interleaved on disc, must pick one angle.
- Layer breaks on dual-layer discs.
- Bad sectors — read errors that should be logged and skipped, not fatal.

### R6 — Mux to a container

Produce a single file per title. MakeMKV emits Matroska. `libavformat` can mux
MKV or MP4.

**Note:** MakeMKV's output is an *intermediate* in Changeover — it is handed
straight to HandBrake and then deleted by [#0004](issues/0004.md). So the
container choice is internal and free. It does not have to be MKV. It could even
be skipped entirely; see §6.

### R7 — Title metadata for selection UI

Phase 2's `DiscScanner` needs per-title data. Real output for *Fargo*:

```
TINFO:0,8,0,"36"              # chapter count
TINFO:0,9,0,"1:37:44"         # duration
TINFO:0,10,0,"4.8 GB"         # size, human
TINFO:0,11,0,"5212768256"     # size, bytes
TINFO:0,26,0,"1-24,25-36"     # segment map
TINFO:0,27,0,"B1_t00.mkv"     # suggested output name
```

Duration, chapter count and byte size all come out of libdvdread arithmetic
directly. This requirement is achievable.

### R8 — Stream metadata for track selection

Per-stream language, codec and layout. Real output for *Fargo* — 6 streams
across video, audio and subtitles:

```
SINFO:0,0,5,0,"V_MPEG2"       SINFO:0,0,19,0,"720x480"
SINFO:0,0,20,0,"16:9"         SINFO:0,0,21,0,"29.97 (30000/1001)"
SINFO:0,1,2,0,"Surround 5.1"  SINFO:0,1,3,0,"eng"     SINFO:0,1,5,0,"A_AC3"
SINFO:0,2,3,0,"fre"           SINFO:0,2,5,0,"A_AC3"
SINFO:0,4,3,0,"eng"           SINFO:0,4,5,0,"S_VOBSUB"
```

Language codes and codec identifiers are in the IFO tables, so libdvdread reaches
these. **Worth noting for the encode side:** 720x480 at 29.97 for a 97-minute
film means *Fargo* is hard-telecined 23.976 — which is why the missing
`--detelecine` in `EncodeController` matters regardless of what happens to
MakeMKV.

### R9 — Main-feature heuristic

Phase 2 wants the main feature preselected. Changeover would own this either way,
so it is not strictly a MakeMKV replacement requirement — but the replacement must
expose enough data to compute it.

The IT Crowd disc shows why it is not just "longest title":

```
Title #1  (28 cells, 2:24:12)   ← "Play All" — longest, and wrong
Title #2  (5 cells, 0:23:11)    ← actual episode
Title #3  (5 cells, 0:24:12)    ← actual episode
...
```

A naive longest-title rule picks the Play All. Detecting it needs **cell-level**
data — the Play All's cells are the union of the episode titles' cells — so R4
must expose cells, not just titles. This is already tracked as an issue from the
existing Play All work.

### R10 — Progress reporting

`RipController` streams `makemkvcon` stdout line-by-line into the log
(`RipController.swift:31-41`), and Phase 4 puts job progress on the wire for
remote clients.

A library-based implementation would produce progress from its own read loop —
arguably **better** than today, since MakeMKV's progress lines are prose to be
scraped rather than structured values. This requirement is an argument *for*
replacement, not against.

---

## 4. The `-r info` parsing dependency (Phase 2 specifically)

This deserves separate attention because it is the part that gets worse with time.

`Roadmap.md` already flags it:

> Verify the `TINFO`/`SINFO` numeric attribute **ids** against real discs. They
> come from `apdefs.h` in the MakeMKV SDK and are **not** in the published
> `usage.txt` — this is a research task before the parser can be trusted.

So Phase 2 as currently designed commits to reverse-engineering an undocumented
numeric attribute table from a closed-source tool, and to re-verifying it whenever
MakeMKV updates. Compare against reading the same values out of IFO structures
with libdvdread, which are **documented and frozen** — the DVD-Video spec has not
changed since 2000.

**This inverts the usual argument.** For the rip path, MakeMKV is clearly the
lower-maintenance option. For the *scan* path, it may well be the higher-maintenance
one. These can be decided independently — see §6.

---

## 5. Non-functional requirements

### N1 — Licensing (the decisive constraint)

| Component | License | Effect if linked into Changeover |
|---|---|---|
| libdvdcss | GPLv2 | Changeover becomes GPLv2 |
| libdvdread | GPLv2 | Changeover becomes GPLv2 |
| libdvdnav | GPLv2 | Changeover becomes GPLv2 |
| libavformat/libavcodec | LGPL v2.1+ (GPL with some flags) | LGPL is compatible with dynamic linking |
| MakeMKV (today) | Closed, shells out | No effect — separate process |

Shelling out to a separate binary does not combine the works. **Linking does.**
Phase 6 is "Ship to other people," so this is a live concern, not a hypothetical.

Two ways to keep Phase 6 open:

- **Helper process.** Ship the GPL code as a standalone binary, talk to it over a
  pipe exactly as the app already does with `makemkvcon` and `HandBrakeCLI`. Keeps
  the licensing boundary where it is today. Adds IPC and a second thing to
  install.
- **Accept GPLv2 for Changeover.** Simplest technically. Forecloses some
  distribution options. Note the app already cannot be sandboxed
  (`ENABLE_APP_SANDBOX = NO`) and so is **already** ineligible for the Mac App
  Store — so the practical cost may be smaller than it first appears. Worth
  checking what it actually rules out before treating it as a blocker.

**This is the first question to settle.** It constrains every other choice.

### N2 — Legal context for distribution

Circumventing CSS is restricted in some jurisdictions (in the US, DMCA §1201 —
with exemptions that have been granted and renewed for some purposes). This has
not mattered so far because the app shells out to a tool the user installs
themselves. Bundling decryption changes Changeover's own posture.

Not a reason to abandon the idea — VLC and HandBrake ship worldwide — but it is a
real input to the Phase 6 decision and worth understanding before, not after.
Ripping discs you own for a personal Plex library is the ordinary use here; the
question is purely about what *Changeover* ships.

### N3 — Reliability bar

The bar is "at least as good as MakeMKV on the existing 33-disc library." A
replacement that handles 30 of 33 is a regression, and the three it fails on will
be discovered one evening at a time.

**Any evaluation must run against real discs, not synthetic ones.**

### N4 — Performance

Current rip is I/O-bound on the optical drive (~5-8 GB at DVD read speed). A
library implementation should be comparable — the bottleneck is the drive, not
the descrambler. Not a differentiator; do not optimize for it.

### N5 — Build and distribution complexity

Today: two paths in Settings, and a bad path is a recoverable error the user can
fix in the UI.

Linked dylibs: a missing dylib is a **launch-time crash**, not a recoverable
error. Static linking avoids that but hardens the GPL position. Either way this
is a real downgrade in failure mode from what exists now, and `AppSettings`'
user-editable paths were the right design precisely because of it.

---

## 6. The option space

Worth noting these are not all-or-nothing — the scan path and the rip path can be
decided **separately**, and that flexibility is probably the most useful insight
in this document.

**A. Status quo.** Keep MakeMKV for everything. Zero work. Keeps the expiring-key
failure, which [#0009](issues/0009.md) mitigates but cannot remove.

**B. Replace the scan path only.** libdvdread for `DiscScanner` (R4, R7, R8, R9);
MakeMKV still does the rip. Avoids the undocumented `apdefs.h` attribute-id
problem in §4, gets cell-level data for the Play All heuristic, and leaves the
hard part (R5 extraction, malformed-disc handling) with MakeMKV. **Smallest change
with a real payoff, and the one I would investigate first.**

**C. Replace everything, DVD only.** libdvdcss + libdvdread + libavformat. Removes
the dependency and the expiring key. Inherits R4's open-ended malformed-disc
obligation permanently.

**D. Replace everything including Blu-ray.** Not recommended. R3 alone is larger
than the rest combined.

**E. Sidestep the intermediate.** Since MakeMKV's MKV is deleted immediately after
the encode (§R6), a libdvdcss-backed reader could feed HandBrake or ffmpeg
*directly* from the disc, skipping the intermediate file entirely. That deletes
the entire class of bugs [#0003](issues/0003.md) and [#0004](issues/0004.md)
exist to fix, and removes 5-8 GB of write-then-read per disc. HandBrake can
already open `VIDEO_TS` directly. **The most interesting option on this list and
the least explored — worth a spike before anything else.**

---

## 7. What is already available on joe

Installed and verified 2026-09-11:

| | |
|---|---|
| libdvdcss | 1.6.0, arm64 — `/opt/homebrew/lib/libdvdcss.2.dylib`, headers in `/opt/homebrew/include/dvdcss` |
| libdvdcss source | `~/Developer/brennanMKE/DVD/libdvdcss` (VideoLAN git, at `811ce97`) |
| ffmpeg | 9.0.1, with libavformat/libavcodec 63 |
| libbluray | 4.x (present, but see R3) |
| HandBrakeCLI | 1.11.2_1 |
| MakeMKV | 1.18.4, key currently valid |
| Not installed | libdvdread/libdvdnav standalone, lsdvd, dvdbackup, vobcopy |

---

## 8. Test corpus

Any option must be evaluated against real discs. Two are characterized already:

**Fargo Special Edition** (`FARGO_SE__16X9`) — the clean case. One title, 1:37:44,
36 chapters, 4.8 GB. MPEG-2 720x480 16:9 29.97 (telecined film). 3 audio (eng 5.1,
fre 5.1, eng commentary — all AC3), 3 VOBSUB subtitle tracks. Exercises R1-R8.

**The IT Crowd Season 1** (`THE_IT_CROWD_SEASON_1`) — the hard case. 10 titles
including a 2:24:12 Play All over 7 ~24-minute episodes. Reports BUP offset
mismatches on both VTS. Exercises R4 malformed-disc handling and R9 cell-level
Play All detection.

The remaining 31 discs in `/Volumes/Media/Media/Movies` are the reliability
sample for N3.

---

## 9. Questions to answer

In priority order — the first one gates everything else.

1. **Is Changeover willing to be GPLv2?** If yes, options B/C/E open up directly.
   If no, everything routes through a helper process. Check what GPLv2 actually
   forecloses given the app is already non-sandboxed and non-App-Store.
2. **Is Blu-ray in scope, ever?** A firm no makes this tractable. Put the answer
   in `Roadmap.md` either way.
3. **Can HandBrake read `VIDEO_TS` directly well enough to skip the intermediate
   entirely (option E)?** Cheapest spike on the list, largest payoff, and testable
   this week against Fargo with no code changes — just a command line.
4. **How much of the `apdefs.h` attribute-id problem is actually unavoidable?** If
   Phase 2 needs it anyway, option B gets much more attractive.
5. **What is libdvdread's real behavior on the IT Crowd disc's BUP mismatch?**
   The single best proxy for R4's true cost. Also a one-afternoon experiment.

Questions 3 and 5 are both cheap, both answerable against discs already on hand,
and between them they resolve most of the uncertainty. Start there.
