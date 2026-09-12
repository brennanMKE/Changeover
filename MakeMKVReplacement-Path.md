# Eliminating MakeMKV — the path forward

Fourth and final document in the series, and the only one meant to be acted on.

- `MakeMKVReplacement.md` — the target (requirements R1–R10)
- `MakeMKVReplacement-Findings.md` — the proposed plan, from documentation
- `MakeMKVReplacement-Results.md` — what happened when it was run on hardware
- **this document** — what to build, in what order, and what it does to the
  existing issue queue

Written 2026-09-11, after the end-to-end path was proven on *Fargo*.

---

## 1. The decision

**HandBrake becomes the primary path. MakeMKV is demoted to an optional
fallback. It is not deleted.**

The risk being addressed is specific: *MakeMKV's beta key expires roughly every
two months, and if it ever expires without a replacement being available, the app
stops working entirely.* Today that is a single point of failure with a
third-party clock attached to it.

The fix is not to prove HandBrake is perfect and then delete MakeMKV. It is to
stop *requiring* MakeMKV. After step 4 below, a dead key means "one fallback is
unavailable" rather than "the app is broken."

### Why not a clean removal

Three reasons, in order of weight.

1. **The evidence base is one disc.** Fargo ripped end to end, correctly. That
   proves the path works; it does not prove it works on 33 discs, and one of them
   (*The IT Crowd*) already reports malformed IFO data that MakeMKV handled
   gracefully.
2. **The sweep that was supposed to settle this cannot be run.**
   `MakeMKVReplacement-Findings.md` §6 Step 4 says to run the encode across "all
   33 discs in `/Volumes/Media/Media/Movies`" — but that directory holds finished
   `.mp4` files. There is no `VIDEO_TS` or ISO anywhere on the volume. The sweep
   means physically feeding 33 DVDs through the drive at ~20 minutes each, about
   11 hours of manual swapping, before anything can ship.
3. **libdvdcss is running on a fallback path.** See `-Results.md` §5. It could
   not open `/dev/disk6` and recovered through the mounted filesystem. It worked,
   instantly, but that is not the path it intended to take, and it is the most
   plausible future cause of "works in MakeMKV, fails in HandBrake."

Demoting rather than removing gets the entire benefit immediately, costs one
`if` statement, and converts the 11-hour sweep from a blocking gate into data
that accumulates naturally as discs get ripped.

### What this is strictly better than

`-Findings.md` §8's fallback option B' keeps MakeMKV on the **rip** path and uses
HandBrake only for scanning. That leaves the expiring key on the critical path
for every single disc — precisely the thing being fixed. Demotion inverts it.

---

## 2. Target architecture

```
DiskArbitration  →  DiscScanner        →  EncodeController  →  PlexOrganizer
(insert/eject)      HandBrake --scan      HandBrake -i VIDEO_TS   (unchanged)
                    (+ lsdvd, optional)   -t <title>
```

One external binary on the critical path: **HandBrakeCLI**. Two optional
enrichments: **lsdvd** (disc id, cells) and **makemkvcon** (fallback ripper).

The rip stage disappears. There is no intermediate `.mkv`, so there is nothing to
name, nothing to clean up, and no 5–8 GB write-then-read per disc.

### Invocations, verified

```bash
# Scan — note --title 0, which is MANDATORY for a full title list
HandBrakeCLI -i <VIDEO_TS path> --scan --title 0 --min-duration 1 --json

# Encode — direct from the disc, no intermediate
HandBrakeCLI -i <VIDEO_TS path> -t <title> --format av_mp4 --quality 21 \
  --aencoder "copy:aac,copy:ac3" --markers -o <output.mp4>

# Optional enrichment — disc fingerprint and cell data
lsdvd -x -Oj <VIDEO_TS path>
```

---

## 3. Implementation sequence

Steps 1–3 land while MakeMKV is still installed and still the ripper. **Step 4 is
the commit point.** Each step is independently shippable.

### Step 1 — `DiscScanner` over HandBrake JSON

Wrap `HandBrakeCLI --scan --title 0 --min-duration 1 --json`. Decode into the
`DiscInfo` / `DiscTitle` / `DiscStream` models that Phase 2 already calls for.

Three things that will bite if ignored:

- **`--title 0` is mandatory.** Without it HandBrake scans only title 1, returns
  valid JSON, and is silently incomplete. A scan that returns exactly one title
  on a disc that should have several is the symptom.
- **The output is not one JSON document.** A `Version:` block, ~25 `Progress:`
  blocks, and libdvdnav log lines interleaved *on stdout* all precede
  `JSON Title Set:`. Parse defensively: tolerate arbitrary non-JSON lines
  anywhere, locate the `JSON Title Set:` section specifically. Do not split on a
  fixed set of labels.
- **Map HandBrake's fields onto our model**, do not reshape the model around
  HandBrake's JSON. A backend swap should stay cheap; that is the whole lesson of
  this exercise.

### Step 2 — Main-feature selection

Use `MainFeature` from the scan. It returned `1` on Fargo, correctly identifying
the feature among 8 titles.

Add the lsdvd cell-union Play All test **only if** the IT Crowd disc shows it is
needed. Do not build it speculatively — that disc is the reason to check, and it
has not been re-tested yet.

### Step 3 — Interlace handling driven by the scan

`InterlaceDetected` and `FrameRate` decide whether any deinterlace filter is
applied. **Never unconditional.**

Fargo scans as `23.976 fps, InterlaceDetected: false` — soft telecine, already
resolved from the MPEG-2 pulldown flags. Adding `--detelecine` there would insert
a filter to fix a problem that does not exist. (Both earlier documents describe
this disc as hard-telecined; that was wrong, and `-Findings.md` §5's argument
against ffmpeg rests on it.)

### Step 4 — `EncodeController` takes `VIDEO_TS` + title — **the commit point**

Signature becomes roughly `encode(videoTS:title:output:handbrakePath:log:)`.
`RipController` is deleted.

This closes [#0003](issues/0003.md) and [#0004](issues/0004.md) *by
construction* — no intermediate file exists to pick wrongly or to strand — and
closes [#0028](issues/0028.md), which is entirely about ripping every title and
then guessing by file size.

Decide `--subtitle scan` deliberately here rather than inheriting it. It runs a
complete extra pass over the full title (`task 1 of 2` in the progress output)
and accounted for roughly half of Fargo's 21m44s. Phase 3 wants unattended
multi-disc throughput.

### Step 5 — Demote MakeMKV

- `AppSettings.isConfigured` stops depending on `makemkvconPath`.
- `makemkvconPath` stays in Settings, clearly optional.
- If HandBrake fails on a disc and makemkvcon is present, fall back to it and say
  so in the log. If it is absent, report a specific failure naming the disc.
- Log every fallback. That log is the disc-reliability data set §1 says to gather
  incrementally, and it is what eventually justifies removing MakeMKV outright.

### Step 6 — Structured progress from `--json`

Parse HandBrake's `Progress:` objects into typed values instead of scraping log
prose. Feeds Phase 4's remote job progress, and it is strictly better data than
MakeMKV's progress lines ever were.

### Step 7 — `DVDMonitor` over DiskArbitration

Replace `VIDEO_TS`-folder polling with insert/remove callbacks. Use
`Optical Media Type: DVD-ROM` to distinguish a real disc from a mounted DMG or
network share, and lsdvd's `dvddiscid` for disc identity.

Verified available: device node, `PLDS DVD+-RW DS-8A8SH`, optical media type,
removable, ejectable. Prerequisite for Phase 3, and it closes the
identity/debounce gap already noted against `DVDMonitor`.

---

## 4. Effect on the existing issue queue

This is the part that matters most for planning — Phase 2 is substantially
rewritten by this decision.

### Closed by construction (no code needed beyond step 4)

| Issue | Why |
|---|---|
| [#0003](issues/0003.md) | No shared rip folder; no intermediate to pick wrongly |
| [#0004](issues/0004.md) | No intermediate to strand |
| [#0028](issues/0028.md) | No full-disc rip and no size-based guess |

### Obsolete — close as `wontfix` with a pointer here

| Issue | Why |
|---|---|
| [#0021](issues/0021.md) | `makemkvcon` robot-mode attribute ids are no longer parsed at all |

Note that `-Findings.md` §2.1 established `apdefs.h` is public-domain and frozen,
so #0021 was tractable. It is being dropped because the parser it serves is being
dropped, not because it was unworkable.

### Need rewriting against HandBrake JSON

| Issue | Change |
|---|---|
| [#0023](issues/0023.md) | Parse HandBrake `--json`, not robot-mode output |
| [#0024](issues/0024.md) | Scan via HandBrake; failure modes are different |
| [#0025](issues/0025.md) | `MainFeature` largely solves this |
| [#0022](issues/0022.md) | Model shape should follow from HandBrake's fields |

### Changed in scope

| Issue | Change |
|---|---|
| [#0008](issues/0008.md) | Preflight checks HandBrake, not MakeMKV; MakeMKV becomes an optional probe |
| [#0009](issues/0009.md) | The expiring-key case stops being the headline failure. New headline: the libdvdcss raw-device fallback (`-Results.md` §5) |

### Unaffected

[#0005](issues/0005.md) eject, [#0006](issues/0006.md) notification,
[#0010](issues/0010.md) path sanitizer, [#0029](issues/0029.md) audio track
selection (if anything more relevant now), [#0032](issues/0032.md) TMDB runtime
cross-check.

### Newly worth filing

- **Plex compatibility of the direct-encode output.** The MP4 carries a
  `bin_data` VOBSUB stream and a VFR `120/1` container timebase. Given
  `check_mp4_compatibility.sh` and
  `diagnosing_mp_4_files_for_plex_apple_tv.md` already exist in
  `/Volumes/Media/Plex`, this has bitten before. Test file is at
  `/tmp/fargo-direct.mp4` on joe.
- **Subtitle variant collapsing.** HandBrake lists 12 subtitle entries for Fargo
  where there are 6 logical tracks — each in Wide Screen and Letterbox. Phase
  2's selection UI needs to collapse the pairs.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| libdvdcss raw-device fallback fails on some disc | MakeMKV fallback (step 5) covers it. Log every occurrence. |
| HandBrake mishandles a malformed disc MakeMKV tolerates | Same. IT Crowd is the known test case and is still untested. |
| Direct-encode output has a Plex compatibility problem | Verify `/tmp/fargo-direct.mp4` before step 4. Cheap, and it gates the commit point. |
| Phase 2 rework is larger than the original plan | Real, but it is rework toward a documented JSON schema and away from an undocumented numeric attribute table. |

---

## 6. Immediate next actions

1. **Verify `/tmp/fargo-direct.mp4` plays in Plex.** Cheapest remaining test and
   it gates step 4. No code, no disc swap.
2. **Swap in the IT Crowd disc** and re-run the scan. Settles R9 (Play All) and
   the malformed-IFO question. Needs physical access to joe.
3. **Start step 1** — `DiscScanner` over HandBrake JSON. Unblocked now; needs
   neither of the above.
4. **Re-triage Phase 2** per §4 before any more Phase 2 issues are worked, so
   nobody implements the robot-mode parser that is being deleted.

Item 4 is the time-sensitive one. [#0021](issues/0021.md) and
[#0023](issues/0023.md) are both about a parser that should no longer be built.
