# Replacing MakeMKV — empirical results and path forward

Third document in the series. `MakeMKVReplacement.md` stated the target,
`MakeMKVReplacement-Findings.md` proposed a plan from published documentation.
This one is **what actually happened when the plan was run against hardware**.

Everything below was executed on `joe` (M1 mini, macOS 26.6.2, 8 GB) on
2026-09-11 against the *Fargo* Special Edition disc physically in the DS-8A8SH.
Commands and raw output are reproducible; nothing here is inferred.

---

## 1. Verdict

**MakeMKV can be removed. Every requirement R1–R10 is covered without it, and
the end-to-end path has been run to completion.**

The decisive test — §6 Step 3 of the findings document — passed:

```
HandBrakeCLI -i /Volumes/FARGO_SE__16X9 -t 1 --format av_mp4 --quality 21 \
  --aencoder "copy:aac,copy:ac3" --subtitle scan --markers -o /tmp/fargo-direct.mp4
```

`work result = 0`. 1,128,135,218 bytes (1.13 GB). h264 712×472, AAC stereo +
AC3 5.1, **36 chapters preserved**, duration 1:38:08. 21m44s wall clock for a
98-minute feature. No MakeMKV, no intermediate MKV, no expiring key.

---

## 2. Correction to §1 of my own earlier report

I reported mid-session that "HandBrake's scan alone is not sufficient for Phase 2"
because it returned one title where lsdvd returned ten. **That was my error, not
a HandBrake limitation.**

The first scan omitted `--title 0`. Without it HandBrake scans only title 1 —
visible in the log as `hb_scan: path=/dev/disk6, title_index=1`. With it:

```
HandBrakeCLI -i /Volumes/FARGO_SE__16X9 --scan --title 0 --min-duration 1 --json
```

```
MainFeature: 1   titles: 8
t1  1h38m02s  36 chapters  3 audio     ← the feature
t4  0h00m40s   5 chapters  1 audio
t5  0h00m13s   1 chapter   1 audio
t6  0h27m47s   2 chapters  1 audio     ← bonus feature
t7  0h20m31s   2 chapters  1 audio     ← bonus feature
t8  0h00m34s   2 chapters  1 audio
t9  0h01m19s   2 chapters  1 audio
t10 0h02m04s   2 chapters  1 audio
```

Two consequences:

- **The findings document's §3 was right.** HandBrake covers R4, R7 and R8.
- **`MainFeature` works.** It returned `1`, correctly pointing at the feature.
  The `MainFeature: 0` from the first scan was an artifact of scanning a single
  title, not evidence the field is unreliable. §6 Step 2 should be read with this
  in mind — on the IT Crowd disc, a `0` would mean the scan was wrong, not that
  the field failed.

**`--title 0` is mandatory for a full scan.** This is the single most important
invocation detail in this document and it is easy to miss, because a scan
without it succeeds, returns valid JSON, and is simply incomplete.

---

## 3. Requirement coverage, as measured

| Req | Status | Evidence |
|---|---|---|
| R1 drive enumeration | ✅ | `diskutil` (DiskArbitration) → `Device Node: /dev/disk6`, `Device / Media Name: PLDS DVD+-RW DS-8A8SH`, `Optical Media Type: DVD-ROM`, `Removable`, `Protocol: USB` |
| R2 CSS decrypt | ⚠️ works, on a fallback | See §5 |
| R3 AACS/BD+ | ⛔ out of scope | Per findings §4. Drive has no BD capability. |
| R4 structure | ✅ | 8 titles with `--title 0 --min-duration 1` |
| R5 extraction | ✅ | Full encode completed from `VIDEO_TS` |
| R6 mux | ✅ n/a | Eliminated — HandBrake writes the final MP4 |
| R7 title metadata | ✅ | Duration, `ChapterList`, `AngleCount`, `Geometry`, `FrameRate`, `InterlaceDetected` |
| R8 stream metadata | ✅ | Language, codec, layout, and `Attributes.Commentary` correctly flagged on Fargo's third AC3 track |
| R9 main feature | ✅ | `MainFeature: 1` correct. lsdvd cells available as backup. |
| R10 progress | ✅ | `--json` emits structured `Progress:` objects |

---

## 4. What lsdvd still adds

lsdvd 0.21 is installed (`brew install lsdvd`). **`-Oj` JSON output exists**,
resolving findings §9 unknown #2.

It is **not** needed for the title list — HandBrake covers that. It uniquely
provides two things:

1. **Cell-level `first_sector` / `last_sector`.** HandBrake exposes chapters but
   not cells. R9's Play All union test needs cells, so if the IT Crowd disc
   defeats `MainFeature`, this is the fallback.
2. **A disc fingerprint** — `dvddiscid: ceaaceba983071d9a7e28fd6107947b7`.
   Unplanned and genuinely valuable: it is a stable disc identity, which is what
   Phase 3's unattended multi-disc queue needs to dedupe re-mounts and recognize
   an already-ripped disc. Neither prior document anticipated getting this.

lsdvd also reports 10 tracks to HandBrake's 8 — the two extra are 1-second junk
titles that `--min-duration` correctly suppresses.

Recommendation: **adopt HandBrake as the scanner; keep lsdvd as an optional
enrichment** for disc id and cells. Do not make the pipeline depend on it.

---

## 5. The one real reliability concern

libdvdcss **could not open the raw device** and silently fell back:

```
libdvdread: Could not open /dev/disk6 with libdvdcss.
libdvdread: Can't open /dev/disk6 for reading
libdvdread: Attempting to retrieve all CSS keys
libdvdread: This can take a _long_ time, please be patient
libdvdread: Get key for /VIDEO_TS/VIDEO_TS.VOB at 0x0000013c
libdvdread: Elapsed time 0
   … 17 keys, every one at Elapsed time 0 …
libdvdread: Found 4 VTS's
```

Raw `/dev/disk6` access needs privileges the process does not have. It worked
anyway — all 17 keys resolved instantly through the mounted filesystem — but the
job is running on a path libdvdread describes as slow and last-resort.

**This is the thing to watch across a wider disc sample.** It succeeded here; a
disc where the fallback does not hold would fail, and the failure would be a
CSS error rather than an obvious one. It is also a plausible explanation for any
future disc that works in MakeMKV but not HandBrake.

Also observed, non-fatal: `ERROR: unable to decode subtitle with 2019 bytes.`
during the subtitle scan. The encode continued and completed. This is the §9
disc-quirk class appearing on the very first disc tested.

---

## 6. Encode mechanics worth acting on

**`--subtitle scan` doubles wall-clock time.** It runs a complete extra pass over
the full title before encoding begins — the `task 1 of 2` in the progress output.
21m44s total for Fargo, roughly half of it in that pass. Phase 3 wants unattended
multi-disc throughput, so this flag deserves a deliberate decision rather than
inheritance.

**The filter chain contains no deinterlacer, correctly:**

```
+ Framerate Shaper (mode=0)
+ Crop and Scale (width=712:height=472:crop-top=0:crop-bottom=8:crop-left=8:crop-right=0)
```

**Fargo is soft telecine, not hard.** Scan reports `23.976 fps` and
`InterlaceDetected: false`; MakeMKV reported 29.97. HandBrake reads the MPEG-2
pulldown flags and resolves to native film rate. Both earlier documents describe
this disc as hard-telecined — including the findings document's §5 argument
against ffmpeg, which rests on that premise.

**Consequence: never add `--detelecine` unconditionally.** On this disc it would
insert a filter to fix a problem that does not exist. Findings §7 step 4 says
"consider driving it from `InterlaceDetected` and `FrameRate`" as an aside — that
aside is the rule.

**Two output details to check against Plex:**

- Container timebase reports `r_frame_rate=120/1` — an artifact of VFR
  (Framerate Shaper mode=0), not a real 120 fps. Consider whether CFR output is
  preferable for Plex/Apple TV.
- A `bin_data` stream (index 3) is present — the VOBSUB track from
  `--subtitle scan`. **VOBSUB in MP4 is poorly supported.** Given
  `check_mp4_compatibility.sh` and `diagnosing_mp_4_files_for_plex_apple_tv.md`
  already exist in `/Volumes/Media/Plex`, this has bitten before. Verify playback
  before trusting the output.

**Subtitle count discrepancy resolved.** HandBrake's 12 vs lsdvd's 6 vs MakeMKV's
3 is six *logical* subtitles each in two variants:

```
id=0x20bd, lang=English (Wide Screen) [VOBSUB]
id=0x26bd, lang=English (Letterbox) [VOBSUB]
```

English, Français, español, English Forced, Français Forced, English Director's
Commentary. Phase 2's UI should collapse the Wide Screen / Letterbox pairs or the
user sees twelve near-identical rows.

---

## 7. ffmpeg: ruled out, empirically

Findings §5 reason 1 confirmed on the actual machine:

```
$ ffmpeg -h demuxer=dvdvideo
Unknown format 'dvdvideo'.
$ ffmpeg -buildconf | grep -i dvd
(no libdvdread / libdvdnav)
```

homebrew-core's ffmpeg 9.0.1 has no DVD demuxer. Using it would require the
third-party tap and a source build. Correctly rejected.

---

## 8. The 33-disc sweep cannot be run as specified

Findings §6 Step 4 says to run step 3 "across all 33 discs in
`/Volumes/Media/Media/Movies`." **Those are not discs.** The directory holds
finished `.mp4` files — one per movie — and a search of the whole volume finds no
`VIDEO_TS` directory and no ISO images.

The sweep as written would require physically feeding 33 DVDs through joe's
drive, one at a time, at ~20 minutes each. That is ~11 hours of manual disc
swapping, and it is the gate the entire decision currently hangs on.

**It is also the wrong gate**, for a more important reason — see §9.

---

## 9. Path forward: demote, don't remove

The stated risk is *"MakeMKV could become a blocker at any point if it expires
and is not updated."* That risk is not addressed by proving HandBrake works on 33
discs first. It is addressed by **making MakeMKV optional**, which can be done
now.

Restructure the pipeline so HandBrake is the primary path and MakeMKV is a
fallback that is used only if present and only if HandBrake fails:

- HandBrake handles the disc → MakeMKV never invoked, key irrelevant.
- HandBrake fails → fall back to MakeMKV if installed; otherwise report a
  specific failure naming the disc.
- MakeMKV's key expires → the app still works for every disc HandBrake handles,
  which now demonstrably includes the clean case.

This inverts the dependency immediately. It does not require the sweep, because
it does not require HandBrake to be perfect — only to be tried first. The sweep
then stops being a gate and becomes data that accumulates naturally as discs are
ripped, with failures logged per disc.

This is strictly better than findings §8's option B', which keeps MakeMKV on the
rip path and therefore keeps the expiring key on the critical path for every
disc.

### Implementation sequence

Each step is independently shippable. Steps 1–3 can land while MakeMKV is still
installed.

1. **`DiscScanner` via HandBrake.** Wrap `HandBrakeCLI --scan --title 0
   --min-duration 1 --json`. Parse defensively — see §10. Decode into
   `DiscInfo` / `DiscTitle` / `DiscStream`. Drop the planned `TINFO`/`SINFO`
   parser. Map HandBrake's fields onto the model rather than reshaping the model
   around them, so a backend swap stays cheap.
2. **Main-feature selection** from `MainFeature`, with the lsdvd cell-union Play
   All test added only if the IT Crowd disc shows it is needed.
3. **Interlace handling driven by the scan** — `InterlaceDetected` and
   `FrameRate` decide whether any deinterlace filter is applied. Never
   unconditional.
4. **`EncodeController` takes `VIDEO_TS` + title number** and invokes
   HandBrakeCLI once. This is the commit point: it deletes the rip stage,
   closes [#0003](issues/0003.md) and [#0004](issues/0004.md) by construction,
   and removes 5–8 GB of write-then-read per disc.
5. **MakeMKV becomes an optional fallback.** `AppSettings.makemkvconPath` stays
   but is no longer required; `isConfigured` stops depending on it.
6. **Structured progress** from `--json`, feeding Phase 4's remote job progress.
7. **`DVDMonitor` via DiskArbitration**, using `Optical Media Type` to
   distinguish a real disc from a mounted DMG or network share, and lsdvd's
   `dvddiscid` for disc identity. Prerequisite for Phase 3.

---

## 10. Parsing warning

`--json` output is **not** a single JSON document, and it is messier than
findings §3.1 describes. Observed on this run, in order: a `Version:` block,
~25 `Progress:` blocks, and **libdvdnav log lines interleaved on stdout** —

```
libdvdnav: vm: dvd_read_name failed
libdvdnav: DVD disk reports itself with Region mask 0x00fe0000. Regions: 01
```

— all of that *before* `JSON Title Set:`, and all of it on stdout with
`2>/dev/null` already applied. A parser that splits on known labels will break.
It must tolerate arbitrary non-JSON lines anywhere in the stream and locate the
`JSON Title Set:` section specifically.

---

## 11. Still unknown

- **The IT Crowd disc has not been re-tested** since it is not in the drive. It
  is the R9 Play All case and the malformed-IFO (BUP offset) case. Needs a swap.
- **Broader disc reliability**, especially the §5 raw-device fallback. Best
  gathered incrementally per §9 rather than as an 11-hour sweep.
- **Plex playback of the output** — the VFR timebase and the `bin_data` VOBSUB
  track (§6). The file exists at `/tmp/fargo-direct.mp4` on joe and can be
  tested directly.
- **Bad-sector behavior.** Findings §9 notes MakeMKV has `io_ErrorRetryCount` /
  `io_IgnoreReadErrors`; HandBrake's equivalent is uncharacterized. A corrupt
  rip still produces a file, so spot-check playback, not exit codes.
