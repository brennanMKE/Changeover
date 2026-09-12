# Replacing MakeMKV — findings and decision

Companion to `MakeMKVReplacement.md`. That document stated the target. This one
states what was found against it and what to do.

Written 2026-09-11. Research is from published documentation (FFmpeg demuxer
docs, MakeMKV `usage.txt` and `apdefs.h`, HandBrake CLI, lsdvd man page,
VideoLAN libdvdcss docs, Arch Blu-ray wiki). **Nothing here has been run against
a real disc yet.** Section 6 is the verification that has to happen before any
code changes.

---

## 1. Conclusion

**MakeMKV can be removed. HandBrakeCLI stays.**

The replacement is not new code. Every one of R1–R10 is covered by binaries
already installed or by native macOS API. The recommended end state is a single
external dependency:

```
HandBrakeCLI -i <VIDEO_TS path> -t <title> ... -o <output>
```

with libdvdcss underneath, no intermediate MKV, and no expiring key.

This is contingent on one empirical result: HandBrake's DVD reader clearing the
N3 reliability bar on the 33-disc library. That is the only open question of
consequence. Section 6 settles it.

Removing ffmpeg from the picture as well is deliberate. See §5.

---

## 2. Corrections to `MakeMKVReplacement.md`

Three claims in the source document are wrong or outdated. They change the
option ranking, so fix them there before acting on it.

### 2.1 §4 is void: `apdefs.h` is published and frozen

The source document says Phase 2 "commits to reverse-engineering an undocumented
numeric attribute table." It does not. `apdefs.h` ships in the `makemkv-oss`
tarball at `makemkvgui/inc/lgpl/apdefs.h`, with the header text "This file is
hereby placed into public domain, no copyright is claimed." MakeMKV's own
`usage.txt` states of the referenced values: "These values will not change in
future versions."

The `AP_ItemAttributeId` enum, in full for the useful range:

| ID | Name | ID | Name |
|---|---|---|---|
| 1 | Type | 19 | VideoSize |
| 2 | Name | 20 | VideoAspectRatio |
| 3 | LangCode | 21 | VideoFrameRate |
| 4 | LangName | 22 | StreamFlags |
| 5 | CodecId | 24 | OriginalTitleId |
| 6 | CodecShort | 25 | SegmentsCount |
| 7 | CodecLong | 26 | SegmentsMap |
| 8 | ChapterCount | 27 | OutputFileName |
| 9 | Duration | 28 | MetadataLanguageCode |
| 10 | DiskSize | 32 | VolumeName |
| 11 | DiskSizeBytes | 36 | SeamlessInfo |
| 12 | StreamTypeExtension | 38 | MkvFlags |
| 13 | Bitrate | 40 | AudioChannelLayoutName |
| 14 | AudioChannelsCount | 49 | Comment |
| 15 | AngleInfo | 50 | OffsetSequenceId |
| 16 | SourceFileName | | |

Every ID in the Fargo sample in §7 of the source document checks out against
this: 8, 9, 10, 11, 26, 27 on titles; 5, 19, 20, 21 on video; 2, 3 on streams.

Stream flags from the same header, useful for track selection:

```
AP_AVStreamFlag_DirectorsComments            = 1
AP_AVStreamFlag_AlternateDirectorsComments   = 2
AP_AVStreamFlag_ForVisuallyImpaired          = 4
AP_AVStreamFlag_CoreAudio                    = 256
AP_AVStreamFlag_SecondaryAudio               = 512
AP_AVStreamFlag_ForcedSubtitles              = 4096
```

Consequence: the maintenance argument for replacing the scan path was the
strongest argument in the document, and it does not hold. Option B loses most of
its appeal on those grounds. It is superseded anyway by §3.

### 2.2 §5 N1 is not a live constraint

The licensing table assumes linking. Nothing in the recommendation links.
HandBrakeCLI, lsdvd and ffmpeg are separate processes invoked over a pipe,
exactly as `makemkvcon` is today. libdvdcss is dlopened by libdvdread *inside
those processes*, never by Changeover.

So §9 question 1 ("Is Changeover willing to be GPLv2?") stops gating anything.
It only becomes live if libdvdread is linked directly for R4, and since
HandBrake and lsdvd both expose that data over a pipe, there is no reason to.

Keep the GPLv2 question in the document as a note, but demote it from "the first
question to settle."

### 2.3 §7 understates what is already installed

HandBrakeCLI is listed only as an encode dependency. It is also a complete
implementation of R4, R7, R8 and a candidate R9. See §3.1.

---

## 3. What covers each requirement

| Req | Covered by | Notes |
|---|---|---|
| R1 drive enumeration | DiskArbitration / IOKit | Native. No parsing, no license. Gives insert/remove callbacks. |
| R2 CSS | libdvdcss 1.6.0 | Already installed. dlopened by libdvdread. |
| R3 AACS/BD+ | **Out of scope** | See §4. |
| R4 structure parsing | HandBrakeCLI `--scan --json` | lsdvd `-d` if cell data needed. |
| R5 extraction | HandBrakeCLI `-t <n>` on `VIDEO_TS` | No intermediate file. |
| R6 mux | N/A | Eliminated. HandBrake writes the final file. |
| R7 title metadata | HandBrakeCLI `--scan --json` | Duration, chapters, geometry, angles. |
| R8 stream metadata | HandBrakeCLI `--scan --json` | Language, codec, layout, commentary flags. |
| R9 main feature | HandBrake `MainFeature` field, else lsdvd cells | Test both. See §6. |
| R10 progress | HandBrakeCLI `--json` progress objects | Structured, not prose. |

### 3.1 HandBrakeCLI scan output

```
HandBrakeCLI -i <path> --scan --json 2>/dev/null
```

Returns `MainFeature` (a title index) and a `TitleList`. Per title:
`AngleCount`, `ChapterList`, `Duration`, `Geometry`, `FrameRate`,
`InterlaceDetected`, `AudioList`, `SubtitleList`. Per audio track:
`LanguageCode`, `CodecName`, `ChannelLayoutName`, `BitRate`, `SampleRate`, and
an `Attributes` object with `Commentary`, `AltCommentary`, `VisuallyImpaired`,
`Default`, `Secondary`.

That is R7 and R8 with no new dependency and no `apdefs.h` parsing.

**Known wart:** the output is not pure JSON. It is labelled sections, roughly:

```
Version: { ... }
JSON Title Set: { ... }
```

The parser must split on those labels before decoding. Do not assume the whole
stream parses as one JSON document. (HandBrake issue #4377.)

**Fallback flag:** `--no-dvdnav` forces the libdvdread-only path. This is the
standard workaround when libdvdnav loops or hangs on a disc. Changeover should
expose it as a per-disc retry, not a global setting.

**Other relevant flags:** `--min-duration <s>` (default 10) to suppress junk
titles, `--main-feature` to let HandBrake pick.

### 3.2 lsdvd, if needed

GPLv2, separate binary, not yet installed. The only route that exposes
**cell-level** data, which is what R9's Play All union test needs.

```
brew install lsdvd
lsdvd -x -Oj <path>     # -x all info, -Oj JSON (verify -Oj exists in this build)
lsdvd -d <path>         # cells specifically
```

Older builds may only have `-Oh/-Op/-Oy/-Or/-Ox`. Check before depending on JSON.

---

## 4. Blu-ray: scope out, permanently

Put this in `Roadmap.md` as a decision, not an open question.

libaacs requires a `KEYDB.cfg` containing a host key/certificate or a processing
key. Host keys are routinely revoked by newer discs, and revocation is generally
irreversible until a newer key appears in circulation. libbdplus implements the
BD+ VM but does not cover all BD+ generations; since 0.2.0 it can bypass
emulation using cached tables, which is its own dependency on an external data
set.

That is a key-chasing treadmill. It is the same failure mode as MakeMKV's
expiring beta key, and worse, because the keys come from third parties rather
than one vendor. Adopting it would defeat the purpose of this entire exercise.

The drive on `joe` has no BD capability, so nothing is lost today.

---

## 5. Why not ffmpeg

ffmpeg gained a real DVD-Video demuxer in 7.0 (`-f dvdvideo`, by Marth64). It is
capable and worth knowing about:

```
ffmpeg -f dvdvideo -title 3 -i <disc> -map 0 -c copy out.mkv
```

Options: `title`, `chapter_start`, `chapter_end`, `angle`, `pgc`, `pg`, `region`,
`preindex`, `trim`. `trim` (default on) skips sub-1-second padding cells at the
start of a PGC, which is real disc-quirk handling already done for you.
`preindex` gives accurate chapter markers and duration via a second-pass NAV
read, which the docs explicitly call non-ideal against a real optical drive.

**It is not recommended, for two reasons.**

1. **Build fragility.** homebrew-core's ffmpeg is not built with
   `--enable-libdvdnav --enable-libdvdread`. Only the third-party
   `homebrew-ffmpeg/ffmpeg --with-dvd` tap is. That is a source build that
   breaks on upgrades. Trading an expiring key for a bespoke build is not a win,
   and it is exactly the fragile-path problem N5 describes.

2. **The encode side is the real cost.** Fargo is hard-telecined 23.976 (§R8).
   HandBrake's `detelecine` and `decomb` do adaptive per-frame comb detection and
   adjust per disc. The ffmpeg equivalent is a fixed
   `fieldmatch,yadif=deint=interlaced,decimate` chain that behaves differently on
   progressive, hard-telecined and genuinely interlaced sources. Across 33 discs
   all three will appear. Owning that decision logic is the same class of
   open-ended obligation that §R4 of the source document warns about, just moved
   from the ripper to the encoder.

Revisit ffmpeg later if Phase 4/5 wants explicit angle control, chapter-range
extraction, structured `-progress` output, or an untouched `-c copy` archive
alongside the Plex encode. Not now.

### 5.1 Title numbering gotcha

Title indices from libdvdread, libdvdnav, HandBrake, lsdvd and ffmpeg all derive
from the VMG title table, so those agree with each other. **MakeMKV enumerates
its own filtered set and its indices do not correspond.** Any hybrid that scans
with one family and rips with MakeMKV needs an explicit mapping, probably via
`ap_iaOriginalTitleId` (attribute 24). Verify against Fargo before building any
hybrid. The recommended path avoids the problem by removing MakeMKV entirely.

---

## 6. Verification plan

Run in this order. Everything here uses discs and tools already on hand. No code
changes required for steps 1–4.

### Step 1 — Does HandBrake scan the clean case?

```
HandBrakeCLI -i /Volumes/FARGO_SE__16X9 --scan --json 2>/dev/null > fargo-scan.json
```

Expected: one long title ~1:37:44, 36 chapters, 3 AC3 audio tracks (eng 5.1,
fre, eng commentary), 3 VOBSUB subtitle tracks. Confirms R7 and R8 and confirms
the labelled-section parsing shape.

### Step 2 — Does HandBrake beat "longest title" on the hard case?

```
HandBrakeCLI -i /Volumes/THE_IT_CROWD_SEASON_1 --scan --json 2>/dev/null > itcrowd-scan.json
```

Check the `MainFeature` value. If it points at a ~24 minute episode rather than
the 2:24:12 Play All, R9 may need no custom heuristic at all. If it points at
the Play All, install lsdvd and get cell data:

```
brew install lsdvd
lsdvd -x -Oj /Volumes/THE_IT_CROWD_SEASON_1 > itcrowd-cells.json
```

Also note whether HandBrake reports anything about the BUP offset mismatch. This
is source-document §9 question 5.

### Step 3 — Does a direct encode work with no intermediate?

```
HandBrakeCLI -i /Volumes/FARGO_SE__16X9 -t 1 \
  --preset "Fast 1080p30" --detelecine \
  -o /tmp/fargo-direct.mkv
```

This is source-document §9 question 3 and the single most important test in this
document. If it produces a good file, MakeMKV is provisionally out. Check the
telecine handling specifically, since that is the reason `--detelecine` is
missing from `EncodeController` today and matters regardless.

### Step 4 — The N3 sweep

Run step 3 across all 33 discs in `/Volumes/Media/Media/Movies`. Record
failures. This is the decision:

- **0 or 1 failures** → remove MakeMKV. Proceed to §7.
- **2 failures** → retry those with `--no-dvdnav`. If they pass, remove MakeMKV
  and make the flag a per-disc retry.
- **3 or more** → do not remove MakeMKV. Fall back to option B' in §8. A ripper
  with two backends is worse than one with a stale key.

### Step 5 — Only if proceeding

Confirm DiskArbitration gives vendor/product strings and media-present state for
the DS-8A8SH, to replace `DVDMonitor`'s `VIDEO_TS`-folder polling.

---

## 7. Implementation, if §6 step 4 passes

Sequenced. Each step is independently shippable.

1. **`DiscScanner` via HandBrake.** New type wrapping
   `HandBrakeCLI --scan --json`. Split the labelled sections, decode into
   `DiscInfo` / `DiscTitle` / `DiscStream`. Drop the planned `TINFO`/`SINFO`
   parser entirely. Map HandBrake's field names to the existing model; do not
   reshape the model around HandBrake's JSON, so a future backend swap stays
   cheap.

2. **Main-feature selection.** Use HandBrake's `MainFeature` as the default
   preselection. Add the cell-union Play All test only if step 2 of §6 showed it
   is needed.

3. **Delete the rip stage.** `RipController` goes away. `EncodeController` takes
   the `VIDEO_TS` path and a title number and invokes HandBrakeCLI once. This
   closes issues #0003 and #0004 by construction and removes 5–8 GB of
   write-then-read per disc.

4. **Add `--detelecine`** to `EncodeController`. Independently correct,
   independent of everything above. Consider driving it from the scan's
   `InterlaceDetected` and `FrameRate` fields rather than hardcoding.

5. **Progress from `--json`.** Parse HandBrake's progress objects into
   structured values rather than scraping log lines. Feeds Phase 4's remote job
   progress.

6. **Remove `AppSettings.makemkvconPath`** and close issue #0009. The expiring
   key failure mode is gone.

7. **`DVDMonitor` via DiskArbitration.** Replaces `VIDEO_TS`-folder polling with
   insert/remove callbacks. Prerequisite for Phase 3 unattended multi-disc.

Steps 1, 2 and 4 are safe to do while MakeMKV is still the ripper. Step 3 is the
commit point.

---

## 8. Fallback: option B'

If §6 step 4 shows 3 or more failures, do not force it. Take this instead:

- Scan path: HandBrakeCLI `--scan --json`, plus lsdvd for cells.
- Rip path: MakeMKV stays.
- Requires the title-index mapping described in §5.1.

This still removes the `-r info` parser and makes the scan path
key-independent, which is most of the Phase 2 benefit. It keeps the expiring key
only on the rip.

---

## 9. What is still unknown

Stated plainly so it is not lost.

- **Bad-sector behavior.** FFmpeg's demuxer docs note that some drives silently
  fail on bad sectors and return random bits rather than an error, which is
  effectively corrupt data, and that detecting it needs a second pass with
  integrity checks. MakeMKV has `io_ErrorRetryCount` and `io_IgnoreReadErrors`
  settings for exactly this. HandBrake's equivalent handling is uncharacterized.
  On an aging library this is the most likely source of silent quality
  regressions, and the 33-disc sweep will not necessarily surface it, because a
  corrupt rip still produces a file. Spot-check playback, not just exit codes.
- **`lsdvd -Oj` availability** in the Homebrew build.
- **DiskArbitration field names** for vendor/product on this specific drive.
- Whether HandBrake's `MainFeature` is reliable across the full library or only
  on the two characterized discs.
