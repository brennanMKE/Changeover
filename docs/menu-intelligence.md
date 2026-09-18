# Menu intelligence — reading a DVD's menus to improve the rip and the Plex output

Written 2026-09-18 against `595fe26`, to be implemented next. Same rules as
`docs/ux-step-flow.md` §5 and `docs/tv-seasons-plan.md`: `@Observable`,
MainActor-by-default with `nonisolated` pure seams, every decision behind a
plain function covered by `ChangeoverTests` on gordon, UI tests forbidden, and
every new rule pinned to a captured disc under `ChangeoverTests/Fixtures/discs/`.

---

## The principle, stated first

**Menu intelligence enriches. It never decides what gets encoded.**

The decision path for a movie stays exactly what it is today: HandBrake's
`MainFeature`, the 45-minute rule when HandBrake gives no answer (#0056), the
Play All guard (#0025), the TMDB runtime cross-check (#0032), and the user's
Start on the Confirm step. The TV path, when it lands, is the episode cluster
and the confirmed table of `docs/tv-seasons-plan.md`. Nothing in this document
moves a title into or out of the encode. What it adds, in decreasing order of
certainty:

| Tier | Source | What it produces | If it is wrong |
|---|---|---|---|
| 1 — structure | IFO tables and NAV packs (deterministic, no AI) | which button jumps to which title/chapter; how many chapters the chapter menu names; a **confirmation line** on Confirm ("The disc's Play button starts title 1") | a wrong caption; the rip is unchanged |
| 2 — text | Vision OCR of menu stills | chapter names into the MP4; language hints beside the audio picker; a search term when the volume label is useless | a wrong chapter name, a wrong hint, a wrong prefill — all visible, all cheap |
| 3 — judgement | Foundation Models over OCR'd button labels | *which* of the disc's own buttons is "play the movie", for discs whose label the lexicon does not know | a wrong confirmation line, caught by tier 1 (the chosen button must resolve to a real title) |

Every section below obeys this. If a section's value ever depends on the model
being right, it is in the wrong tier and should be cut, not defended. Tier 3
exists so that the tier-1 confirmation can be *named* on a French, Spanish or
Japanese disc; it never touches the selection.

Four things from the user (2026-09-18) that shape the rest:

- **The discs are permanent.** "This is my DVD collection. I will always have
  these disks." Nothing here is a one-shot capture: a disc can be re-read
  whenever the tooling improves, so the archive is built up incrementally
  (§8.1), a format change is a re-capture rather than a migration (§8.4),
  and an enrichment that is not ready today can be applied to the file
  later without losing the chance (§7). The document does not hedge against
  never seeing a disc again, and where an earlier draft did, it now says
  "re-read the disc".
- **Films already in the library can be upgraded from their disc** (§7).
  "For reading a DVD which has already been imported it could show what has
  been included with Plex and if it can enhance chapter and audio titles it
  should offer that upgrade." Offered, never automatic; a remux, never a
  re-encode.
- **`libdvdread` ships inside the app** (§2). The install image carries it.
- **Vision and Foundation Models are assumed present.** They are OS frameworks
  on macOS 26; the app links them and has no "framework missing" branch. The
  model can still be unavailable *at runtime* (`SystemLanguageModel.default
  .availability` reports Apple Intelligence off, model not downloaded, device
  unsupported) and that is handled as **no answer**, never as an error.
- **The archive comes first** (§8). The user will rip several discs, then
  review what was captured. The rules in §3–§6 are hypotheses with one disc
  behind them; the archive is what turns them into pinned behaviour.

## The evidence base — the Bloodsport run (2026-09-18, joe)

Artifacts: `/tmp/menus` on joe; `~/Desktop/bloodsport-menus/` on the dev Mac
(16 stills `menu_01.png`–`menu_16.png`, ~0.5–0.6 MB each as PNG, and
`ocr-results.txt`, 8.9 KB).

- A ~150-line C tool read the menu VOBs through `libdvdread` (which decrypts
  CSS through `libdvdcss`; both on joe as HandBrake dependencies). `ffmpeg`
  cannot read those VOBs off the mount: the video sectors are scrambled and
  it silently yields zero frames.
- `ffmpeg` rendered 16 stills from the decrypted 4.5 MB `vts_01.vob`.
- `VNRecognizeTextRequest` read every line at confidence 1.00 bar one
  (`ONAOC`, 0.30, a decorative smear on the last chapter page).

What it read, and what each line teaches:

| Screen | Text | Lesson |
|---|---|---|
| main menu (`menu_16`) | `Play Movie`, `Scene Selections`, `Special Features`, `Languages` — and the logo as `Bloodiport` | the play label is **"Play Movie" here, "Start Movie" on the chapter pages** — one disc, two labels; stylised title art fails OCR |
| chapter pages (`menu_05`–`08`) | `1World's warriors, 2 Dux ducks out. 3 A mentor:` / `Tanaka.` / `4 Training.` … 23 names, plus `1-6 7-12 13-18 19-23`, `Start Movie`, `Main Menu`, `End Credits` | OCR merges a **row** of three captions into one observation and wraps a long caption onto a second observation; the numbers are in the text; the page-range buttons are also text |
| languages (`menu_02`) | `SPOKEN LANGUAGES` `English` `Français` / `SUBTITLES` `English` `Français` `off` | the words the disc leaves as `und` in its stream table are printed on its menu |
| special features (`menu_04`) | `Cast & Crew`, `Theatrical Trailer` | a second title-jumping button ("trailer") can sit one level below the play button |
| cast/crew bios (`menu_09`–`15`) | `Bloodsport (1987)` on **five** screens, as a filmography credit | **the trap**: the film's own title appears more often on pages that have nothing to do with playing it than on the page that does |
| decorative fonts | `Lanquages`, `Cast &Cren`, `Dean Claude / Dan Damme`, `Newt Ainold`, `Limecop`, `Rambo 111`, `ontin` | the button font read perfectly; the display font did not — never trust a single misread string, and never let OCR text become a path component |

## Facts checked on this Mac (2026-09-18)

- This Mac carries both the **MacOSX26.5** and the **MacOSX27** SDKs
  (`/Applications/Xcode.app`, Xcode 27.0). In the 27 SDK `FoundationModels`
  has `DynamicGenerationSchema(name:description:anyOf: [String])`,
  `GenerationSchema(root:dependencies:)`,
  `LanguageModelSession.respond(to:schema:includeSchemaInPrompt:options:)`,
  `GenerationOptions(sampling: .greedy)`, `GenerationGuide.anyOf(_:)`,
  `SystemLanguageModel.default.availability` →
  `.available | .unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`,
  and `LanguageModelError.refusal / .guardrailViolation /
  .unsupportedLanguageOrLocale`. Everything the design uses is in the 26.5
  SDK too.
- **Vision input is not absent from the framework; it is absent at the
  deployment target.** The 27 SDK declares `Attachment<Content>`,
  `ImageReference`, `Transcript.Segment.image` and
  `LanguageModelCapabilities.Capability.vision` (beside `guidedGeneration`
  and `reasoning`), all `@available(macOS 27.0)`; the 26.5 SDK has none of
  them. The app's `MACOSX_DEPLOYMENT_TARGET` is 26.2, so at the target the
  model reads text only. joe itself runs macOS 27.0. **The design stays
  text-only by choice**, not by limitation: OCR is deterministic and its
  output is a list of strings with boxes that a test can pin and a human can
  read; a picture answer is neither, and it works at the deployment target.
  If the target ever moves to 27, what would change is that a
  vision-capable model could read a menu still directly — which would let it
  *name* a button on a picture-only menu (§9's "picture menus" row), but
  would not remove the need for button geometry: the answer still has to be
  attached to a real button rectangle and its decoded command before it is
  worth showing. The closed-set-of-labels contract (§4.3) would apply to
  the picture path unchanged.
- `Vision` has both `VNRecognizeTextRequest` (the run used it) and the Swift
  `RecognizeTextRequest` with `recognitionLevel`, `usesLanguageCorrection`,
  `recognitionLanguages`, `automaticallyDetectsLanguage`, `customWords`,
  `minimumTextHeightFraction`; observations carry `boundingBox` and
  `topCandidates(_:)` with a confidence.
- No `ffmpeg`, `HandBrakeCLI`, `lsdvd` or `libdvdread` headers on the dev Mac,
  and no MPEG-2 sample to test AVFoundation decode against — the one open
  engineering question in §1.4 has to be answered on joe.
- The repo is MIT. `libdvdread` and `libdvdcss` are GPL-2.0-or-later. §2
  deals with that.

---

## 1. The pipeline, end to end

```
                     disc mounted (DVDMonitor)
                              │
            ┌─────────────────┴──────────────────┐
            ▼                                    ▼
   HandBrakeCLI --scan (today, ~60 s)    changeover-menudump  (helper, §2)
   → scan.json → DiscInfo, MainFeature      reads IFOs + menu NAV packs (clear),
   → classify / Play All guard              decrypts the menu cells it needs (CSS)
   ════ the decision path, unchanged ════   → structure.json + cells/*.vob
                                                     │  runs AFTER the scan (one
                                                     │  reader on a USB 2.0 drive)
                                                     ▼
                                          still per menu PGC  (decoder, §1.4)
                                                     │
                                                     ▼
                                          Vision OCR  → ocr.json  (in-app)
                                                     │
                                ┌────────────────────┼────────────────────┐
                                ▼                    ▼                    ▼
                     MenuStructure (tier 1)   MenuText (tier 2)   MenuJudge (tier 3)
                     buttons → titles/PTTs    chapter names,      Foundation Models
                     chapter-menu counts      language hints,     over button labels
                     tvSignal                 title text          → label or "none"
                                └────────────────────┼────────────────────┘
                                                     ▼
                                           MenuIntelligence (one value)
                                        ┌────────────┼──────────────┐
                                        ▼            ▼              ▼
                                  Confirm step    --markers=csv   corpus archive
                                  captions/hints  --aname         (§8)
```

### 1.1 Which files to read

A DVD's menus live in two domains, and the tables that describe them are in
the IFO files, which are **never scrambled**:

| Domain | Tables (IFO) | Video (VOB) | What is there |
|---|---|---|---|
| VMGM (disc-wide) | `VIDEO_TS.IFO`: `VMGM_PGCI_UT` (menu PGCs per language unit), `TT_SRPT` (title → VTS, VTS title number, chapter count), `FP_PGC` (first play) | `VIDEO_TS.VOB` | the title menu (entry type "title"), often the main menu |
| VTSM (per title set) | `VTS_nn_0.IFO`: `VTSM_PGCI_UT` (entry types root 0x82, subpicture 0x83, audio 0x84, angle 0x85, chapter/PTT 0x86), `VTS_PTT_SRPT` (title, PTT → PGC, program) | `VTS_nn_0.VOB` | root menu, chapter pages, language menu, extras pages |

Each menu PGC's cell playback table gives sector ranges into the menu VOB.
Every VOBU in those cells starts with a **NAV pack** — a 2048-byte sector
holding the PCI and DSI packets (private stream 2). The PCI's highlight
information (`hli`) is the button table: up to 36 buttons, each with a
rectangle (`x_start … y_end`), the up/down/left/right links, an auto-action
flag and an **8-byte VM command** — `JumpTT n`, `JumpVTS_TT n`,
`JumpVTS_PTT title, chapter`, `LinkPGCN n`, `SetSTN` (audio/subpicture
stream), and the conditional and register-setting forms. NAV packs are not
CSS-scrambled either (the scrambling bits live in the pack header and NAV
packs never set them), which is why `libdvdread` can hand them back before it
has any key. Only the *picture* — the MPEG-2 video that carries the words —
needs `libdvdcss`.

So the helper reads, per disc: every IFO (small), every menu PGC's first NAV
pack (one sector each — the button table is repeated in every NAV pack of a
still menu and the first one is enough; for a motion menu with a late
highlight start, also the last NAV pack of the first cell), and the video
sectors needed for one still per menu PGC.

### 1.2 How many stills, and how chosen

**One still per menu PGC, not a fixed frame rate.** The unit of a menu is the
PGC; the 16 Bloodsport stills happen to be its 16 menu PGCs (title menu,
root/main, four chapter pages, languages, credits, special features, seven
bio pages). Frame-rate sampling would produce duplicates of still menus and
miss the one frame of a motion menu where the text has finished fading in.

Per menu PGC:

1. **Still menu** (first cell is a single VOBU or under ~1 s): decode the
   first I-frame. One still.
2. **Motion menu** (first cell longer than ~2 s): decode one I-frame from the
   *end* of the first cell (the loop point, where transitions have settled),
   and — only if the PCI's `hli_ss` says the highlight starts later than the
   cell start — one from just after `hli_s_ptm`. Two stills at most.
3. **Non-entry PGCs that no button reaches** (pre-roll loops, orphaned
   authoring): skipped. A PGC counts when it is an entry PGC or the target of
   some button's `LinkPGCN`/`JumpSS`, walked from the entry PGCs.
4. **Button groups.** `hl_gi.btngr_ns` can define up to three button groups
   (4:3, widescreen, letterbox). Use group 1; record the count so a disc
   whose groups differ shows up in the archive.

Cap the disc reading: at most 64 MB of menu video per disc (about 12 s on
the ~5.6 MB/s USB 2.0 drive, `memory/dvd-read-vs-encode-throughput.md`).
Motion-menu discs past the cap get their entry PGCs first and stop; the
archive records `truncated: true` — and since the disc stays on the shelf, a
later helper with a higher cap simply re-reads it.

### 1.3 OCR settings

`RecognizeTextRequest` (Swift Vision), one request per still, on the
cooperative pool, results hopped to MainActor like every other worker:

- `recognitionLevel = .accurate`.
- `usesLanguageCorrection = false` for the first archive round. Correction
  did not rescue `Lanquages`, and it is the mechanism most likely to "fix" a
  proper noun in a chapter name. Re-evaluate on the archive: the capture
  tool records the setting it used (§8), so both settings can be run over
  the same stills later.
- `recognitionLanguages = [en, fr, es, de, it, pt, nl, ja]` and
  `automaticallyDetectsLanguage = true`.
- `customWords` = the button lexicon (§4.2) plus the words the Bloodsport
  run got wrong (`Languages`, `Continue`, `Crew`). The lexicon takes
  precedence over the dictionary, which is what a menu wants.
- `minimumTextHeightFraction = 0.02` (a 10-pixel line on a 480-line frame).
- The still is upscaled 2× with Lanczos before OCR. DVD menus are 720×480 or
  720×576 with anamorphic text; the run did not upscale and still read
  everything in the plain font, so this is a knob for the archive to settle,
  not a requirement.

Keep every observation: text, confidence, `boundingBox` (normalised,
origin bottom-left — convert to the frame's pixel rect once, on the way in).
Geometry is what attaches text to buttons (§3.2, §4.1); a text dump with no
boxes cannot do that, which is what `ocr-results.txt`'s `at y=` column was
already hinting at.

### 1.4 Where each stage runs

| Stage | Capture path (`Tools/capture-disc.sh`, joe) | App path (joe, after the scan) |
|---|---|---|
| IFO + NAV read, CSS decrypt of menu cells | `changeover-menudump` on joe | the same helper, from the app bundle |
| still rendering | `ffmpeg` on joe (proven today; ffmpeg is present there and the capture path may depend on it) | **open**: `AVAssetImageGenerator` on the decrypted `.vob`, or VideoToolbox (`kCMVideoCodecType_MPEG2Video`) behind a small PS→ES demux; if neither decodes it, the helper grows a libmpeg2 dependency (§2.4). Settle this with one experiment on `/tmp/menus/vts_01.vob` before slice 2 |
| OCR | on the dev Mac after `scp` (Vision is there too; keeps joe idle) | in-app, off MainActor |
| resolution (tiers 1–2) | a `swiftc`-built `Tools/menu-derive` that links the app's `nonisolated` sources, the way #0055 derived manifests | in-app, pure functions |
| judgement (tier 3) | recorded when run, never required (gordon may have no model) | in-app, only when tiers 1–2 leave a question |

The helper runs **after** `DiscScanner.scan` returns, never concurrently with
it: HandBrake's scan is ~60 s of seeking on a USB 2.0 drive and two readers
would slow both. It runs concurrently with the user's TMDB search. Its
results land on `JobController` as `menuState: MenuState` (`.idle /
.reading / .ready(MenuIntelligence) / .unavailable(reason)`) — a sibling of
`scanState`, cleared on `removeDisc()` and on a fresh `startScan`, so a
caption from one disc can never show under another. Start never waits on it.

### 1.5 Cost

Measured and estimated from today's run (4.5 MB, 16 frames):

| Step | Cost | Basis |
|---|---|---|
| IFOs + NAV packs | tens of KB to ~1 MB, <1 s | never scrambled; a handful of seeks |
| menu video read | 4.5 MB → ~0.8 s at 5.6 MB/s plus seeks; a motion-menu disc up to the 64 MB cap → ~12 s | measured drive throughput |
| decode 16 I-frames | well under 1 s | MPEG-2 at DVD resolution |
| OCR 16 stills, `.accurate` | ~0.1–0.4 s each on Apple Silicon → 2–7 s | not timed today — the first thing the in-app path should log |
| model call, one label choice | ~1–2 s, one call per disc at most | constrained decoding of a few tokens |
| total | ~5–25 s, overlapping the user's search; the encode is 20–40 min | |

Disc wear and time added to a rip: one extra pass over a few MB of the
menu domain. Nothing here touches the title VOBs.

---

## 2. Shipping `libdvdread` — the dependency, decided

The user's decision: **`libdvdread` is included in the install image.** This
section is how, not whether.

### 2.1 Shape: a helper binary, a bundled dylib, and a runtime-located `libdvdcss`

```
Changeover.app/Contents/
  MacOS/Changeover                       (MIT, no new entitlements, links nothing new)
  Helpers/changeover-menudump            (C, GPL-2.0-or-later, ~200 lines: today's tool + JSON output)
  Frameworks/libdvdread.8.dylib          (vendored build, GPL-2.0-or-later, @rpath, Developer ID signed)
  Resources/Licenses/libdvdread-COPYING  (the GPL text and the vendored version/URL)
```

- **The app never links `libdvdread`.** It launches the helper through
  `ProcessRunner`, exactly as it launches `HandBrakeCLI`, and reads JSON from
  its stdout. Three reasons, in order of weight: a crash inside `libdvdread`
  on a damaged disc kills a 200-line helper, not the menu-bar app and the
  40-minute encode it is hosting; the GPL library and the GPL helper are a
  separate program talked to at arm's length over a pipe, so the MIT app is
  not a derivative work and the licence boundary is clean; and the one
  entitlement this needs (below) stays off the main binary.
- **`libdvdread` is vendored**, built from the release tarball by
  `scripts/build-menudump.sh` (autotools, `--disable-static`, and configured
  for **`dlopen` of libdvdcss, not `--with-libdvdcss`**), installed with
  `install_name_tool -id @rpath/libdvdread.8.dylib`, and signed with the
  Developer ID. Homebrew's copy is not shippable as-is: it is ad-hoc signed,
  its install name is an absolute `/opt/homebrew/...` path, and depending on
  how the formula was configured it may carry a load command naming
  `libdvdcss` — a preflight gate (§2.3) refuses any of those.
- **`libdvdcss` is not bundled. It is looked up at runtime.** This is
  different in kind from a normal dependency and the user should confirm it:
  `libdvdcss` is the CSS circumvention library, HandBrake itself does not
  ship it for exactly that reason, and the app's *hard* dependency —
  Homebrew `HandBrakeCLI` — already requires it to rip anything, so on any
  working rip host it is present by construction. The helper `dlopen`s it
  from, in order: `AppSettings.libdvdcssPath` (new, default
  `/opt/homebrew/lib/libdvdcss.2.dylib`, shown in Settings beside the
  HandBrakeCLI path), then `/usr/local/lib`. Loading an ad-hoc-signed
  Homebrew dylib into a hardened-runtime process requires
  `com.apple.security.cs.disable-library-validation` — on the **helper
  only**. Notarization accepts that entitlement; the app binary carries none.
- **Licence posture.** The app stays MIT. The helper's source lives in
  `Tools/menudump/` under GPL-2.0-or-later with its own `COPYING`; the DMG
  carries the GPL text and the vendored tarball's version and URL in
  `RELEASE.md` (the source offer). Because the app is open source under an
  MIT licence, nothing about this combination is difficult; it just has to
  be written down.

### 2.2 What breaks when the Homebrew copy disappears

| Missing on the host | Effect |
|---|---|
| Homebrew `libdvdread` | nothing — the bundled copy is the one used; the helper's rpath is `@executable_path/../Frameworks` and never `/opt/homebrew` |
| Homebrew `libdvdcss` | the helper still reads IFOs and NAV packs (tier 1 works: buttons, targets, chapter counts, TV signal). It cannot decrypt menu video, reports `"css": "unavailable"`, and there are no stills, no OCR, no chapter names, no hints. `MenuState.unavailable(.noCSS)` shows one line on Confirm. The rip is unaffected — and in practice `HandBrakeCLI` would already be failing on the same disc |
| the helper itself (a hand-built app, a broken bundle) | `MenuState.unavailable(.helperMissing)`; nothing else changes |

Everything here is an enrichment, so every absence is a caption, never a
failure. `Preflight.check` does **not** gain a menu-helper gate; the helper is
checked where it is used, the way `lsdvd` is.

### 2.3 What #0102's release pipeline does differently

`scripts/preflight.sh` gains gates, `scripts/release.sh` gains a build step:

1. `scripts/build-menudump.sh` builds the vendored `libdvdread` and the
   helper into `build/menudump/`, pinned to a tarball SHA recorded in the
   script. It runs before `xcodebuild archive`; an Xcode "Copy Files" phase
   places the two products into `Helpers/` and `Frameworks/`.
2. Signing is inside-out and explicit — the dylib, then the helper with its
   entitlements file, then the app — never `--deep`.
3. Preflight gates: the helper exists and is executable; `otool -L` on it
   lists `@rpath/libdvdread.8.dylib` and system libraries only, no
   `/opt/homebrew` path, no `libdvdcss` load command; `codesign -d
   --entitlements` shows exactly `disable-library-validation` on the helper
   and no entitlements on the app; `Resources/Licenses/libdvdread-COPYING`
   is present; `xcrun stapler validate` still passes with the extra
   Mach-O files. `verify-dmg.sh` additionally runs
   `Helpers/changeover-menudump --version` from the mounted DMG on the
   build machine, which proves the rpath resolves inside the bundle.
4. DMG growth: about 300 KB.

### 2.4 The still decoder — the one open question

`libdvdread` gives decrypted MPEG-2 program-stream bytes; something has to
turn them into a frame. In order of preference: `AVAssetImageGenerator` on a
`.vob` the helper wrote to the job directory (zero new code if AVFoundation
opens MPEG-2 PS on macOS 26 — unverified, and the reason this is a question);
VideoToolbox with a ~150-line PS→ES demux in the helper (MPEG-2 video is a
supported `CMVideoCodecType`); and, last, a vendored `libmpeg2` (GPL, tiny)
inside the helper, which would keep every decode concern in the GPL process.
The capture path needs none of this — `ffmpeg` on joe renders stills today —
so slice 1 (§10) is unblocked either way. One experiment on
`/tmp/menus/vts_01.vob` settles it before slice 2.

---

## 3. Chapter names — the cheapest win

### 3.1 What HandBrake needs

`EncodeController.arguments` already appends a bare `--markers`
(`Changeover/EncodeController.swift`), so the MP4 gets unnamed chapter
markers. `--markers=<file.csv>` names them: one line per chapter,
`<number>,<name>`, e.g.

```
1,World's warriors
2,Dux ducks out
3,A mentor: Tanaka
…
23,Coda and End Credits
```

`HandBrakeCLI 1.11.2 --help` documents only the bare form (line 84 of
`Fixtures/handbrake/help-hb1.11.2-exit0.txt`); the `=file` form is the
documented CLI behaviour upstream and is verified on joe as the first thing
slice 2 does (one short encode, `ffprobe -show_chapters`). Plex shows named
chapters in its chapter picker; Apple TV shows them in the scrubber.

Argument-vector change, pure and testable: `EncodeController.arguments(…,
markers: MarkerSelection = .unnamed)` where `.unnamed` emits `--markers` (the
byte-identical vector every existing test asserts) and `.named(path:)` emits
`--markers=<path>`. `Preflight.requiredHelpTokens()` derives from the
`.unnamed` vector so nothing new is demanded of a host's `--help`. The CSV is
written into the job directory (`DVDPipeline`'s `jobDirectory` under
`workingEncodePath`, next to the marker files) so `WorkingFiles.sweep`
removes it with everything else.

### 3.2 From OCR to names — attach by geometry, verify by number

The chapter menu is the VTS PGC with entry type 0x86 (PTT) plus the pages it
links to (`1-6 7-12 13-18 19-23`). Each chapter thumbnail is a **button**
whose command is `JumpVTS_PTT title, chapter` — so every button already
knows its chapter number before OCR runs. The caption is the text just below
the button:

```swift
nonisolated enum ChapterNames {
    struct Candidate: Equatable, Sendable {
        var chapter: Int           // from the button's JumpVTS_PTT
        var printedNumber: Int?    // the "4" in "4 Training." — nil if absent
        var name: String           // "Training"
        var confidence: Float      // min over the observations used
    }
    /// Pure. `buttons` are the chapter-menu buttons with their rects and
    /// PTT targets; `observations` are that still's OCR boxes in pixel space.
    static func candidates(buttons: [MenuButton], observations: [TextObservation]) -> [Candidate]
    /// Pure. The CSV rows, or nil when the set is not trustworthy (§3.3).
    static func markers(_ candidates: [Candidate], chapterCount: Int) -> [MarkerRow]?
}
```

Attachment rules, in order:

1. Split each observation on chapter-number boundaries: `\b(\d{1,2})\s?`
   at the start of a fragment. `1World's warriors, 2 Dux ducks out. 3 A
   mentor:` becomes three fragments with printed numbers 1, 2, 3.
2. A fragment belongs to the button whose x-span contains the fragment's
   x-centre and whose bottom edge is the nearest one above the fragment
   (within 1.5 caption heights). `Tanaka.` has no number and sits under
   button 3's x-span, so it continues "A mentor:" → "A mentor: Tanaka".
3. Strip the printed number, trailing `.`/`*`/`•` and surrounding
   whitespace. Keep internal punctuation (`Ray vs. Chong Li`).
4. **Cross-check:** `printedNumber`, when present, must equal the button's
   PTT `chapter`. A mismatch marks the candidate `disputed` and it is
   dropped from the CSV (the name stays in the archive).

The printed number is a check, not the source of truth; the button's command
is. On a disc whose chapter menu prints no numbers, step 4 is vacuous and the
mapping is entirely structural.

### 3.3 When the count does not match — and why a wrong name is cheap and a wrong count is not

HandBrake's chapter count for the feature (`DiscTitle.chapterCount`, from
the title's PTTs) and the chapter menu's button count usually agree
(Bloodsport: 23 and 23). When they do not:

| Shape | Cause | Action |
|---|---|---|
| menu names N, HandBrake has N+1 | an unlisted last chapter ("End Credits" was a separate button, not a numbered one) | name 1…N, leave N+1 unnamed; HandBrake keeps the marker |
| menu names N, HandBrake has N−k | the menu addresses PTTs HandBrake merged or dropped (a <1 s stub) | name by PTT number where it resolves; skip the rest |
| menu names fewer than half | a "scene index" with highlights only | no CSV; bare `--markers` as today |
| any `disputed` candidate | printed number ≠ button target | drop that row only |
| two candidates for one chapter | two buttons target the same PTT (page-range buttons share a rect band) | keep the one with a printed number; else none |

**A wrong name is low-risk** because the marker count and positions come
from HandBrake's own scan, not from the CSV: a bad name makes Plex say
"Traning" at the right timestamp. **A wrong count is not**: HandBrake
applies CSV rows by chapter number to markers it has already placed, and a
CSV with more rows than chapters is what turns a clean encode into a failed
one or a muxing warning nobody reads. So `markers(_:chapterCount:)` never
emits a row whose number exceeds `chapterCount`, never emits duplicate
numbers, and returns `nil` rather than a partial CSV when fewer than half the
chapters are named. Rows are sorted, numbers are 1-based and contiguous where
present, names are trimmed and never empty — a chapter with no trustworthy
name is omitted, not written as `""`.

Names are HandBrake metadata, never path components, so #0010's sanitising
does not apply — but commas are: the CSV takes the first comma as the
separator, so a name is written with commas replaced by ` -` unless the
verification encode shows HandBrake accepts a quoted field.

### 3.4 TV discs

On a season disc the "chapter" menu is usually an **episode** menu, its
buttons `JumpVTS_TT` to distinct titles rather than `JumpVTS_PTT` within
one. That is a different product: a list of (title, label) pairs in menu
order — `docs/tv-seasons-plan.md` §3's proposal is "cluster members in
title-index order" with one disc of evidence, and the menu order is a second
witness for it. It is surfaced as a **warning when the two orders disagree**
and as the row label ("e09 · The Vulture — menu says 'The Vulture'") when
they agree. It is not an input to the proposal, per the principle.

---

## 4. Which button starts the feature

### 4.1 Tier 1 — the deterministic layer

From `structure.json`, for every button on every reachable menu PGC:

```swift
nonisolated struct MenuButton: Codable, Equatable, Sendable {
    var pgc: MenuPGCID            // domain, language unit, PGC number
    var number: Int               // 1-based, button group 1
    var rect: PixelRect           // x_start…y_end on the 720×480/576 frame
    var isAutoAction: Bool
    var command: [UInt8]          // the raw 8 bytes — never lost
    var target: ButtonTarget      // decoded, see below
    var label: String?            // OCR text inside/nearest the rect (tier 2)
}

nonisolated enum ButtonTarget: Codable, Equatable, Sendable {
    case title(Int)                        // JumpTT n → VMG title n
    case titleInVTS(vts: Int, ttn: Int)    // JumpVTS_TT — resolved to .title via TT_SRPT
    case chapter(title: Int, ptt: Int)     // JumpVTS_PTT
    case menu(MenuPGCID)                   // LinkPGCN / JumpSS to another menu
    case streams(audio: Int?, subpicture: Int?)  // SetSTN
    case unresolved(mnemonic: String)      // conditional, GPRM-driven, CallSS…
}
```

`VMCommand.decode` is a pure Swift function over the 8 bytes, written from
libdvdnav's `vm/vmcmd.c` mnemonic table, covering the jump/link/set family
and naming everything else `unresolved` with its mnemonic. It follows exactly
one indirection: a `LinkPGCN` to a menu PGC whose *pre-commands* are a single
`JumpTT` resolves to that title (the "Play" button that goes through a
one-cell transition PGC). GPRM-conditional chains are not followed; they are
recorded so the archive can show how common they are.

**HandBrake's title number is the VMG title number.** `JumpTT n` names the
`n`-th entry of `TT_SRPT`; libhb's `hb_dvdread_title_scan` indexes
`tt_srpt->title[t-1]` for its title `t`, so the two agree by construction.
This is asserted, not trusted: the corpus invariant "the play button's
target equals `expect.outcomeIndex` on every movie disc" (§8.6) is the first
thing the archive proves or disproves. Chapters likewise: HandBrake builds
its chapter list from the title's PTTs, so PTT `k` is chapter `k`.

The play-button candidates are the buttons on the **entry menus** (VMGM
title, VTSM root) whose target is `.title`. Then:

- **Exactly one** → resolved structurally. No text, no model. This is the
  common shape and Bloodsport's: four root-menu buttons, one `JumpTT`.
- **Zero** (every root button goes to a submenu, or targets are
  `unresolved`) → widen to the menus one link away; still zero → no
  confirmation line. Recorded.
- **Two or more** (main menu with "Play Movie" and "Play Trailer", "Theatrical"
  and "Director's Cut", "Play" and "Play with commentary" — the last pair
  targets the same title with a `SetSTN`, which collapses to one) → tier 2
  and, if needed, tier 3 decide *which label to show*. Never which title to
  encode.

What the app shows, on Confirm, under the "Main feature — Title N" row:

```
Disc menu: "Play Movie" starts title 1 — matches.                 ← agree (tier 1 or 2/3)
Disc menu: "Play Movie" starts title 3; the scan chose title 1.   ← disagree, plain amber caption; Start unchanged
Disc menu: the Play button starts title 1 — matches.              ← agree, label unknown (no OCR/CSS)
```

The disagree case is information the user did not have before — a disc
that opens through a trailers-plus-feature title, or a second cut — and it
sits beside the runtime verdict as a second independent source, exactly the
role #0025 assigned the TMDB runtime. Whether the structural target may
*preselect* the picker when the heuristic returns `.none` or `.ambiguous`
is a decision for the user (§11); the default is no.

### 4.2 Tier 2 — the lexicon, before any model

Attach labels to buttons by geometry: the observation whose box has the
largest intersection with the button rect, else the nearest observation
whose centre is within half a button height of the rect. Text that is inside
no button is *decoration* — bio filmographies, copyright lines, logos — and
is never a label.

Then a static table, matched case-insensitively after diacritic folding, on
the labels of title-jumping buttons:

```
en: play, play movie, play film, play feature, start, start movie, start film, play all
fr: lecture, lire le film, lecture du film, film, jouer, tout lire
es: reproducir, ver película, ver la película, película, reproducir todo
de: film starten, abspielen, film abspielen, hauptfilm, alle abspielen
it: riproduci, riproduci film, film, riproduci tutto
pt: reproduzir, ver filme, filme
ja: 本編再生, 再生, 本編
```

A lexicon hit on exactly one title-jumping button resolves it with
`resolvedBy: "lexicon"`. The table is seeded from the languages the user's
shelf actually holds and grows only from **verified** archive entries
(§4.4). It is the deterministic answer for the discs that say "Lecture" or
"Reproducir"; the model is for the ones it has not met yet.

### 4.3 Tier 3 — the model, constrained so its answer is always checkable

Only when two or more title-jumping buttons remain after the lexicon, and
only with the model available:

```swift
nonisolated enum MenuJudge {
    struct Question: Equatable, Sendable {
        /// Labels of the *candidate buttons only* — text attached to real
        /// buttons whose target is a real title. Never free text from the still.
        var labels: [String]
        var menuTitleText: String?     // the page heading, for context, e.g. "Special Features"
    }
    enum Answer: Equatable, Sendable {
        case chose(labelIndex: Int)    // an index into `labels`, never a title index
        case none                      // the model picked "none of these" — an acceptable answer
        case unavailable(String)       // availability, refusal, guardrail, locale, any thrown error
    }
    @concurrent static func ask(_ q: Question) async -> Answer
}
```

The implementation, against the API as it stands in the SDK on this Mac:

```swift
guard case .available = SystemLanguageModel.default.availability else { return .unavailable("…") }
let choices = q.labels + [Self.noneLabel]                       // "none of these"
let schema = try GenerationSchema(
    root: DynamicGenerationSchema(name: "PlayButton",
        description: "The DVD menu button that starts playback of the main feature film",
        anyOf: choices),
    dependencies: [])
let session = LanguageModelSession(instructions: Self.instructions)   // ~4 lines: the task, pick one, prefer "none of these" over a guess
let response = try await session.respond(
    to: "Menu buttons: \(choices.map { "\"\($0)\"" }.joined(separator: ", ")). Which one starts the main feature?",
    schema: schema,
    options: GenerationOptions(sampling: .greedy))
let picked = try response.content.value(String.self)
return choices.firstIndex(of: picked).map { $0 == q.labels.count ? .none : .chose(labelIndex: $0) } ?? .none
```

Why this is checkable, structurally:

- **The output is constrained to the enumerated strings.** An `anyOf`
  schema is a closed set; the runtime's guided generation cannot emit a
  label that is not in it. The model has no way to name a title index, a
  file, or a string that does not correspond to a button we are holding —
  "hallucinating a label that is not there" is not a failure mode this
  design can have, and the `firstIndex(of:)` map is belt and braces.
- **The chosen label maps to a button we already resolved in tier 1**, whose
  target is a title that exists in the scan. If that title differs from the
  scan's feature, the caption says so (§4.1's amber line). The model's
  answer is never used for anything the user cannot see.
- **"None of these" is a first-class answer**, and so is every thrown error
  (`refusal`, `guardrailViolation`, `unsupportedLanguageOrLocale`,
  `exceededContextWindowSize`, availability). All of them produce the same
  outcome as "no OCR": no named confirmation line. There is no retry loop
  and no second prompt.
- **Greedy sampling** makes the same input give the same output on the same
  OS build; the archive records the answer, and a change after an OS update
  shows up as a diff in review, not as a different rip.

**#0025's argument against a local model, met head-on.** That ticket
rejected LM Studio for choosing the title because the problem "has one
numeric feature and a threshold; a comparison resolves it exactly", a model
is "non-deterministic across runs", "slower by orders of magnitude", and
"able to hallucinate a title index that does not exist — and a wrong index
here means ripping the wrong thing for forty minutes". All four points are
correct and none applies here, for reasons that are specific, not rhetorical:

1. The title decision is still the comparison. The model is asked a
   different question — a **linguistic** one ("is *Lecture* the play
   button?") for which no threshold exists — and its answer feeds a caption.
2. The answer is drawn from a closed set and verified against a structural
   fact (the button's decoded command). A non-deterministic flip between two
   labels yields either a verified caption or a dropped one, never a
   different encode.
3. One call of a few tokens, ~1–2 s, concurrent with the user's search, on
   a path nothing waits for; #0025's cost comparison was against a 40-minute
   rip *decision*, and this is not on that path.
4. It cannot produce an index. It produces one of the strings we gave it.

The honest residual risk is a **plausible-looking wrong caption** on a disc
where two title-jumping buttons both look like "play" (a double feature, a
theatrical/extended pair). There the caption says which button the model
picked and the title it starts, the runtime verdict still runs, and the
user is choosing on the picker anyway (#0025's `.ambiguous` policy). If the
archive shows this happening, the fix is to say "two play buttons" rather
than to trust the pick.

### 4.4 How the lexicon grows

Every archive entry records `playButton.resolvedBy` (`structure`, `lexicon`,
`model`) and, when tier 1 resolved it alone, also records what the label
*was* — so a label the model was never asked about ("Play Movie") still
enters the table with structural proof behind it. A label resolved by the
model enters the table only after a human review of that disc's manifest
(§8.5) confirms it, the same `reviewed` gate the corpus already uses. The
model is how the table learns words; the table is what makes the next disc
in that language deterministic.

---

## 5. Audio and subtitle labels

### 5.1 The problem

Hornets' Nest (`Fixtures/discs/hornets-nest`) tags every audio stream on
every title `und`; #0027's rule keeps both untagged tracks visible and
#0059's default ticks the first. The picker shows "Track 1" and "Track 2"
and the user has no idea which is Swedish and which is the English dub. The
disc's own Languages menu almost certainly prints the answer — Bloodsport's
says `SPOKEN LANGUAGES: English, Français` and `SUBTITLES: English,
Français, off`.

### 5.2 What the menu can and cannot say about track numbers

Two shapes exist, and only one gives a usable mapping:

1. **Buttons with `SetSTN`.** Each language is a button whose command sets
   the audio (or subpicture) stream number directly. Then "Français" is
   *structurally* attached to DVD audio stream `k`. HandBrake numbers audio
   tracks 1…n in the order of the streams present in the feature PGC's
   audio control table (a stream the PGC does not enable is skipped), so
   DVD stream `k` → HandBrake `TrackNumber` = 1 + (present streams below
   `k`). The helper emits the feature PGC's audio-control bits, the mapping
   is pure, and the corpus invariant "mapped track count == HandBrake's
   audio stream count on the feature" (§8.6) says whether the reading of
   libhb is right. Until that invariant holds on several discs, this is a
   *hint*.
2. **Buttons that set a GPRM**, with the title's pre-commands choosing the
   stream, or a language page that is just text (a listing, no per-language
   button). Then the menu gives an **ordered list of language names and
   nothing else**. The list order usually matches stream order, and
   "usually" is not a mapping.

### 5.3 What to show — the safest form

The user wants the names on the tracks. The safe path to that is a hint the
user confirms, never an automatic assignment:

- **Always** (shape 1 or 2, any confidence): one caption under the Audio
  heading, beside `AudioTrackOptions.notice`'s existing untagged message:
  *"This disc's Languages menu lists: English, Français. The disc does not
  tag its tracks, so this is the menu's order, not a mapping."*
- **Only in shape 1, and only when the mapped count equals the title's
  audio stream count:** a per-row badge, `Track 2 · menu: Français`, in
  the caption font, with a tooltip saying it came from the menu button's
  stream command.
- **Never:** changing `preselection` (the untagged rule stays "first
  track"), changing `languageCode` (an untagged stream stays `nil`; #0027's
  silent-MP4 lesson), or merging untagged tracks because the menu says they
  differ.
- **On request, and off by default (a §11 decision):** a popup on each
  untagged row, prefilled from the badge when there is one, that lets the
  user *name* the track. A confirmed name goes to HandBrake as
  `--aname "Français"` (track title metadata; HandBrake cannot override the
  ISO language tag from the CLI, so the tag stays `und` and Plex shows the
  title). The name never affects which tracks are encoded.

Subtitles: Phase 2's output carries no subtitle track (#0014 §5, #0036
pending), so the subtitle list is only a caption on the read-only rows.
Recorded in the archive regardless — the `off` entry is the tell that a
list is a subtitle list.

---

## 6. A search term when the volume label is useless

`DiscNameSearchTerm.derive` returns `nil` for `DVD_VIDEO`, `UNTITLED`,
`NO_NAME`, `MOVIE` and the like, and `RipFlowController
.attemptSearchPrefill` then prefills nothing. The menu can fill that gap,
under strict rules, because a wrong prefill only seeds the search box
(`SearchPrefill` never overwrites what the user typed):

1. Only when `derive` returned `nil`. A usable volume name always wins.
2. The candidate comes from the **entry menus only** (VMGM title menu, VTSM
   root): the largest-height observation on those stills that is attached
   to no button and is not in the lexicon. Bloodsport's is the logo —
   `Bloodiport` — which TMDB will not match, and which costs nothing.
3. `Title (Year)` strings from **non-entry** pages are never candidates.
   This is the filmography trap: `Bloodsport (1987)` recurs on five cast
   pages, and on a Van Damme disc "Universal Soldier (1992)" recurs across
   the cast just as convincingly. Recurrence is not identity.
4. The candidate is passed through `DiscNameSearchTerm`'s own plausibility
   rules (≥3 characters, contains letters, not a generic name) and its
   title-casing, and is offered through `SearchPrefill.decide` at a lower
   priority than the volume name, once per disc.

Recorded in the archive as `titleText` so a review can say how often the
logo reads well enough to be worth it; if it rarely does, this section is
deleted rather than tuned.

---

## 7. Upgrading an import that already exists — remux, not re-encode

> "For reading a DVD which has already been imported it could show what has
> been included with Plex and if it can enhance chapter and audio titles it
> should offer that upgrade."

### 7.1 The evidence, from the real library

Two files the user already has in `Movies/`, both produced by this app or its
predecessors, both correct in the ways that cost forty minutes and wrong in
the ways that cost two:

| File | What is wrong | What the disc menu has |
|---|---|---|
| `Oppenheimer (2023).mp4` | 20 chapters, every one named `Chapter 1` … `Chapter 20`; the **timings** are right, only the names are missing | a scene-selection menu with the names |
| `The Girl Who Kicked the Hornet's Nest (2009).mp4` | the audio track is tagged `und` — no language at all (the disc tags every stream `und`, `Fixtures/discs/hornets-nest`) | a languages menu that prints the spoken languages |

Neither needs a re-encode. Both are **metadata**, and MP4 metadata can be
rewritten with the video and audio bytes copied untouched — `ffmpeg -c copy`
with new chapter titles and new stream tags — in a minute or two per film,
disk-bound. Because the user keeps every disc, this is not a missed chance
at rip time; it is a pass that can be made over the library disc by disc,
whenever the menu tooling is ready, and repeated if the tooling improves.

### 7.2 What the app knows, and what it has to find out

The duplicate check already recognises the situation: on the Choose step the
selected film's `{tmdb-ID}` is looked up in `Movies/` by `LibraryProbe`
(`docs/log-ui-and-duplicate-check.md`), `LibraryLookup.present([LibraryEntry])`
names the folder and its files, `DuplicatePresentation` renders the notice,
and `StartGate` blocks until a `ReplaceAcknowledgement` — the file is *there*.
What the app does not know is what is *in* it. That is one more optional
probe, pure at its seam:

```swift
/// LibraryFileInventory.swift — pure over ffprobe's JSON.
nonisolated struct LibraryFileInventory: Equatable, Sendable, Codable {
    var durationSeconds: Int
    var video: StreamSummary                 // codec, width, height
    var audio: [AudioSummary]                // index, codec, channels, language ("und"/nil), title
    var subtitleCount: Int
    var chapters: [ChapterSummary]           // start, end (ms), title
    static func parse(ffprobeJSON: Data) -> LibraryFileInventory?
    /// True when every chapter title is empty or matches `^Chapter \d+$` — i.e. nobody named them.
    var chaptersAreUnnamed: Bool
}
```

Filled by `ffprobe -v error -print_format json -show_format -show_streams
-show_chapters <file>` through `ProcessRunner`, with a 10 s watchdog, on the
`@concurrent` pool like `LibraryProbe.lookup`. `ffprobe` and `ffmpeg` are
one Homebrew package (`brew install ffmpeg`), optional, located through a
new `AppSettings.ffmpegPath` beside the HandBrakeCLI path; absent → no
upgrade is offered and one caption says why. They are not bundled — LGPL/GPL
and large — and nothing in the rip path depends on them (§11).

### 7.3 The comparison — what Plex has now versus what the disc offers

Once `menuState` is `.ready` and the inventory is in, a pure
`UpgradeProposal.compare(inventory:menu:disc:)` yields rows. The Confirm
step shows them as a card under the duplicate notice:

```
│ ⚠︎ Already in Plex: Movies/Oppenheimer (2023) {tmdb-872585}/Oppenheimer (2023).mp4  (1.82 GB, Sep 16)
│
│ This disc can improve that file without re-encoding it:
│   Chapters   now: 20, unnamed ("Chapter 1"…"Chapter 20")    disc: 20 names from the scene menu   ✓ upgrade
│   Audio 1    now: AAC stereo, language not set              disc menu: English                   ✓ upgrade
│   Subtitles  now: none                                       —                                    needs a re-rip
│
│ [Reveal]   [Replace (re-rip, ~40 min)]   [Upgrade metadata (remux, ~2 min)]
```

Row rules, each a pure function with the archive behind it:

- **Chapters** are upgradable only when `inventory.chapters.count ==
  names.count` **and** `inventory.chaptersAreUnnamed`. Names attach to the
  file's *existing* chapter timings by chapter number — the timings are
  never moved, added or removed. On a count mismatch the row says "20
  chapters in the file, 21 names on the disc — not upgraded" and offers
  nothing; **never guess** which name to drop. This case is already in the
  library: the scan of the Oppenheimer disc reports **21** chapters on
  title 7 (`Fixtures/discs/oppenheimer/disc.json`,
  `featureChapterCount: 21`) and the file has **20** — the first thing the
  archive should explain, by comparing `ffprobe`'s chapter timings with the
  scan's chapter durations (a trailing sub-second stub that HandBrake's
  marker writer dropped is the likely shape). Until it is explained, that
  file's chapter row is refused, correctly. A file whose chapters already
  carry real names is never renamed unless the user ticks "replace existing
  names" on the card.
- **Audio language and title** are upgradable per track when the disc's
  languages menu gives a *mapping* (§5.2's shape 1) for that track, or when
  the user assigns one on the card's popup (prefilled from the menu's
  ordered list — the same control as §5.3's, in a second place). `language`
  gets the ISO 639-2 code (`eng`, `fra`); `title` gets the menu's own word
  (`Français`). A track that already carries a language is left alone.
- **Everything else is a re-rip**: a missing subtitle (the file has none;
  #0036 is where subtitles enter the output), a second language that was
  never encoded (#0059's one-track default), the wrong feature, a different
  cut, video quality. The card names these as "needs a re-rip" and the
  existing **Replace** path is how — the upgrade card never pretends a
  remux can add data that is not in the file.

### 7.4 Offered, never automatic

The upgrade is a **job** the user starts, shaped like every other job so
nothing new touches the state machine:

- `RipRequest.upgrade: UpgradePlan? = nil` — additive and wire-safe, the
  `tv` pattern. `UpgradePlan` carries the target file, the chapter rows
  (`[MarkerRow]`, already validated against the file's count), and the
  audio tags (`[trackIndex: (language, title)]`). `featureTitleIndex` is
  still set to the disc's feature so `EncodeSelection.make` validates as
  today; `extraTitleIndices` must be empty.
- `StartGate` gains `.upgradeNothingSelected` (the card's rows are all
  refused or unticked) and otherwise treats an upgrade like a Replace: the
  `ReplaceAcknowledgement` is required, keyed on the same
  `(tmdbID, folder)`, because the job **does** overwrite the library file.
- The Ripping step shows `JobProgress.Unit.remux` — indeterminate bar,
  "Rewriting metadata in Oppenheimer (2023).mp4", Cancel allowed until the
  swap begins (`CancelPolicy` treats the swap as `organizing`).
- Done says what changed: "Upgraded: 20 chapter names, 1 audio language.
  Video and audio untouched." plus Reveal; or "Not upgraded — <check that
  failed>; the original is unchanged."

Nothing runs on insertion, on selection, or on the menu read finishing. The
card appears; the user decides.

### 7.5 The mechanism — staged, verified, then swapped (the #0012 pattern)

```
1. ffmetadata file in the job directory:
     ;FFMETADATA1
     [CHAPTER]  TIMEBASE=1/1000  START=<file's own start>  END=<file's own end>  title=World's warriors
     …                                   ← timings copied from the inventory, never from the disc
2. ffmpeg -i <library file> -i chapters.ffmeta
          -map 0 -map_metadata 0 -map_chapters 1 -c copy
          -metadata:s:a:0 language=eng -metadata:s:a:0 title=English
          -movflags +faststart  <staged file in the job directory>
3. ffprobe the staged file and refuse unless ALL hold:
     duration equal to the original within 1 s
     same number of streams, same codec per stream, same channel count per audio stream
     same chapter count, every chapter start/end equal to the original within 1 ms
     size within 2 % of the original (a copy that changed size by more re-encoded something)
4. PlexOrganizer.move: stage onto the destination volume, then replace — the
   original is the last thing touched, and a failure anywhere above leaves it exactly as it was.
5. WorkingFiles.sweep removes the staged copy and the ffmetadata file.
```

Step 3 is what makes "remux, never re-encode" a property the app checks
rather than a promise the command line makes. The verification runs on the
staged copy before the swap, so a `ffmpeg` that silently transcoded (a
missing `-c copy`, a future default change) is caught by the codec and size
checks, and a metadata write that shifted a chapter is caught by the timing
check. A refusal is a Done card with the failed check named; the library
file is untouched.

### 7.6 Where it sits in the step flow

Insert disc → Choose movie (the disc's search term prefills; the duplicate
check runs on selection as today) → **Confirm**, where the duplicate notice
now carries the comparison card once the menu read and the file probe are
both in ("Reading the disc's menus…" until then; the Replace and Reveal
buttons are live throughout) → Ripping (remux) → Done (Upgraded) → Next
Disc. The disc has to be in the drive because the names come from it; the
menu read is the same one the rip path uses, so a disc whose film is already
filed costs the same ~10 s of menu reading and no encode.

Because the collection is permanent, this is also a *loop*: put in a disc,
see what its file is missing, upgrade in two minutes, eject, next disc. The
unattended version of that loop is a Phase 3 decision, not this document's;
the per-disc version needs nothing beyond this section.

### 7.7 What it cannot do, said plainly

- It cannot add a subtitle, a language, or a track that was not encoded —
  those are a Replace.
- It cannot fix a chapter *count* — a mismatch is refused, and the fix is a
  Replace with the disc's chapter names written at encode time (§3).
- It cannot name chapters the disc does not name (a scene index with
  thumbnails and no captions), and it will not invent "Scene 4".
- It does not touch `.mkv` files or anything outside `Movies/<folder>/`; a
  TV file's upgrade path is the same mechanism per episode and is deferred
  with the TV plan.

---

## 8. The data-collection archive — the priority deliverable

The user will rip several discs and review what was captured. This section
is a specification that can be implemented from, without re-deriving
anything. It extends #0055's corpus in place rather than creating a second
archive: **one directory per disc, everything text unless it cannot be**,
reviewed by a human once, swept by one parameterised test.

### 8.1 Two tiers of storage

| Tier | Where | Holds | Lifetime |
|---|---|---|---|
| **raw** | joe, `~/changeover-fixtures/<slug>/` (the staging directory `capture-disc.sh` already uses) | everything the helper and ffmpeg produced, including decrypted menu cells (`.vob`) and full-resolution PNG stills | kept until the user prunes it; never in git |
| **reviewed corpus** | repo, `ChangeoverTests/Fixtures/discs/<slug>/` | the text products, the IFOs, JPEG stills, and the manifest | committed; the regression net |

The raw tier exists so that a better frame chooser or a better OCR setting
can be re-run over old discs without drive time — a convenience, not a
safeguard, because every disc can be put back in. If the raw tier is ever
in the way, delete it and re-capture. The corpus tier is what tests and
reviews read, and it is built **incrementally**: a disc is captured when it
next passes through joe for its own rip or its own upgrade (§7), never on a
special trip, and a capture that turns out thin (no `menus/`, a truncated
motion menu, an OCR setting since improved) is redone the next time that
disc is in the drive.

### 8.2 Folder structure (corpus tier)

```
ChangeoverTests/Fixtures/discs/<slug>/
├── disc.json                    manifest — formatVersion 2 (§8.4)
├── scan.json                    HandBrakeCLI --scan stdout            (existing)
├── scan.stderr.txt              its stderr, separate file (#0039)     (existing)
├── lsdvd.json                   lsdvd -x -Oj output, when lsdvd ran   (new: it was captured and discarded)
├── ifo/
│   ├── VIDEO_TS.IFO             binary, unscrambled, byte-exact copies
│   ├── VTS_01_0.IFO             every VTS's IFO; .BUP files are not kept
│   └── …
└── menus/
    ├── structure.json           helper output: domains, PGCs, cells, buttons, raw commands (§8.3)
    ├── stills/
    │   ├── vmgm-lu1-pgc1.jpg    one per still, named by menu PGC id (§8.3), 720×480/576, JPEG q≈0.8
    │   └── vtsm-01-lu1-pgc3.jpg
    ├── ocr.json                 every observation on every still, with the settings used
    └── derived.json             tiers 1–3 resolved: play button, chapter names, languages, title text, judge record
```

Naming: `<slug>` is the existing kebab-case rule. Still ids are
`vmgm-lu<n>-pgc<n>` and `vtsm-<vts>-lu<n>-pgc<n>`, with `-b` appended for a
motion menu's second still. Language units (`lu`) are 1-based as in the
IFO. Everything under `menus/` is optional as a set: a disc captured before
the helper existed, or one where the helper failed, has no `menus/`
directory and `disc.json.menus.captured == false`. A disc without
`libdvdcss` has `structure.json` but no `stills/`, `ocr.json` or the text
half of `derived.json`.

Text versus binary: `*.json` and `*.txt` are text and reviewable in a diff.
`ifo/*.IFO` and `stills/*.jpg` are binary; they are committed as-is (no
LFS yet — see §8.7) and never edited.

### 8.3 File formats

**`menus/structure.json`** — written by the helper, never by hand.

```json
{
  "format": "changeover-menu-structure/1",
  "helper": { "name": "changeover-menudump", "version": "0.1.0", "libdvdread": "6.1.3", "css": "available" },
  "capturedAt": "2026-09-18T20:41:07Z",
  "frame": { "width": 720, "height": 480, "standard": "NTSC" },
  "titles": [
    { "title": 1, "vts": 1, "vtsTTN": 1, "ptts": 23, "angles": 1 }
  ],
  "featurePGC": { "title": 1, "vts": 1, "pgc": 1, "audioControl": [32768, 32769, 0, 0, 0, 0, 0, 0] },
  "menus": [
    {
      "id": "vtsm-01-lu1-pgc1",
      "domain": "VTSM", "vts": 1, "languageUnit": 1, "languageCode": "en", "pgc": 1,
      "entryType": "root",
      "cells": [ { "firstSector": 0, "lastSector": 2211, "durationMS": 0 } ],
      "reachableFrom": ["entry"],
      "buttonGroups": 1,
      "highlight": { "start": 0, "buttons": 4, "forcedSelect": 1 },
      "buttons": [
        { "number": 1, "rect": [388, 148, 550, 178], "autoAction": false,
          "command": "3002000000010000", "up": 4, "down": 2, "left": 1, "right": 1 }
      ],
      "stills": ["vtsm-01-lu1-pgc1"],
      "truncated": false
    }
  ]
}
```

Commands are the raw 8 bytes as hex; decoding is Swift's job and is pinned
by tests over exactly these strings. `entryType` is one of `title`, `root`,
`subpicture`, `audio`, `angle`, `chapter`, `none`. `rect` is
`[xStart, yStart, xEnd, yEnd]` in frame pixels. `audioControl` is the
feature PGC's eight audio-control words verbatim (§5.2).

**`menus/ocr.json`** — written by the OCR step.

```json
{
  "format": "changeover-menu-ocr/1",
  "engine": { "framework": "Vision", "api": "RecognizeTextRequest", "os": "26.2", "level": "accurate",
              "languageCorrection": false, "languages": ["en","fr","es","de","it","pt","nl","ja"],
              "customWords": 41, "upscale": 2, "minimumTextHeightFraction": 0.02 },
  "stills": [
    {
      "id": "vtsm-01-lu1-pgc3",
      "observations": [
        { "text": "4 Training.", "confidence": 1.0, "rect": [148, 328, 222, 346] },
        { "text": "ONAOC", "confidence": 0.30, "rect": [300, 240, 360, 262] }
      ]
    }
  ]
}
```

Every observation is kept, low-confidence ones included — the archive is
for learning what the engine does, and a filter belongs in the resolver
where a test can see it. `rect` is in frame pixels (converted once from
Vision's normalised, bottom-left-origin box).

**`menus/derived.json`** — written by `Tools/menu-derive` (capture) or the
app (in-app; not persisted there beyond the job's history entry).

```json
{
  "format": "changeover-menu-derived/1",
  "resolver": { "app": "0.9.0", "lexicon": 3 },
  "buttons": [
    { "menu": "vtsm-01-lu1-pgc1", "number": 1, "target": { "title": 1 }, "label": "Play Movie", "labelConfidence": 1.0 }
  ],
  "playButton": { "menu": "vtsm-01-lu1-pgc1", "number": 1, "label": "Play Movie", "title": 1,
                  "resolvedBy": "structure", "candidates": 1 },
  "chapterMenu": { "title": 1, "buttons": 23, "pages": ["vtsm-01-lu1-pgc3", "…"],
                   "names": [ { "chapter": 4, "printedNumber": 4, "name": "Training", "confidence": 1.0, "disputed": false } ],
                   "csvRows": 23 },
  "languages": { "shape": "listing", "spoken": ["English", "Français"], "subtitles": ["English", "Français", "off"],
                 "trackMapping": null },
  "tvSignal": { "value": false, "reason": "no menu with ≥3 title-jumping buttons" },
  "titleText": { "candidate": "Bloodiport", "still": "vmgm-lu1-pgc1", "offered": false, "reason": "volume name was usable" },
  "judge": null
}
```

When the model was asked, `judge` records the question and the answer
verbatim — `{ "labels": [...], "answer": "Lecture", "answerIndex": 0,
"sampling": "greedy", "os": "26.2", "askedAt": "…" }` — or `{ "answer":
"unavailable", "reason": "appleIntelligenceNotEnabled" }`. This is the
record that lets a review ask "would the model have got this one right"
across the archive without a disc.

### 8.4 The manifest — `disc.json`, format version 2

Existing fields are unchanged; `DiscCorpusTests.DiscManifest` decodes
version-1 manifests exactly as before because every addition is optional.
Additions:

```json
{
  "formatVersion": 2,
  "slug": "bloodsport",
  "volumeName": "BLOODSPORT",
  "…": "existing fields unchanged",
  "capture": {
    "tool": "Tools/capture-disc.sh",
    "toolVersion": 2,
    "hostOS": "26.2",
    "ffmpeg": "7.1.1",
    "ifoFiles": 2,
    "rawArchive": "joe:~/changeover-fixtures/bloodsport"
  },
  "menus": {
    "captured": true,
    "css": "available",
    "menuCount": 16,
    "stillCount": 16,
    "truncated": false,
    "ocrRun": true,
    "judgeRun": false
  },
  "expect": {
    "…": "existing expectations unchanged",
    "menu": {
      "playButtonTitle": 1,
      "playButtonLabel": "Play Movie",
      "playButtonResolvedBy": "structure",
      "chapterMenuButtons": 23,
      "chapterNamesEmitted": 23,
      "spokenLanguages": ["English", "Français"],
      "subtitleLanguages": ["English", "Français", "off"],
      "tvSignal": false,
      "titleTextOffered": false
    }
  }
}
```

`formatVersion` is the tell between old and new captures: absent means 1
(the four existing discs), and the sweep treats a missing `menus` block on a
version-2 manifest as a capture bug, not as "no menus". **A format change is
a re-capture, never a migration script.** Because the discs are permanent,
a version-3 format is introduced by bumping the number, letting the sweep
accept both, and re-capturing each old disc as it next goes through the
drive; no code ever rewrites a version-1 or version-2 capture in place. The
four existing discs are the first re-captures (§10, slice 1). `expect.menu` is
`null` on a disc that has no `menus/`; the sweep skips those assertions and
says so by name.

### 8.5 What `Tools/capture-disc.sh` does, step by step (version 2)

Every remote step stays its own trivial `ssh`, stdout and stderr on
separate files, parsing local — the discipline #0055 established.

1. Identify the disc and slug as today; refuse to overwrite an existing
   `disc.json`.
2. `HandBrakeCLI --scan` as today; `lsdvd -x -Oj` as today, but **keep**
   `lsdvd.json` in the corpus directory.
3. `cp /Volumes/<vol>/VIDEO_TS/*.IFO ~/changeover-fixtures/<slug>/ifo/` on
   joe, then `scp` them home. Plain file copies; nothing decrypts.
4. `changeover-menudump --disc /Volumes/<vol> --out ~/changeover-fixtures/<slug>/menus --max-bytes 67108864`
   on joe → `structure.json` and `cells/<menu-id>.vob`. Exit status
   recorded; a failure leaves `menus.captured: false` and the capture
   continues.
5. For each menu in `structure.json`, `ffmpeg -i cells/<id>.vob -vf
   "select=eq(pict_type\,I)" -vsync vfr -frames:v 1 stills/<id>.png` on joe
   (the last-I-frame variant for motion menus takes `-sseof`). PNGs stay in
   the raw tier; `scp` them home, convert to JPEG q=0.8 into
   `menus/stills/`.
6. Locally: `Tools/menu-ocr` (a `swiftc`-built command that links
   `Changeover/MenuOCR.swift`, the same file the app uses) → `ocr.json`.
7. Locally: `Tools/menu-derive` (links the app's `nonisolated` resolver
   sources, the way #0055 compiled the parser standalone) → `derived.json`
   and the `expect.menu` block, written with `reviewed: false`.
8. Print the summary, now including: menu count, still count, the play
   button line, chapter names emitted / chapter count, the language lists,
   and every `unresolved` command mnemonic seen — the review reads this
   first.

The human review that flips `reviewed` now also checks, against the stills:
that the play button line names the right button; that the chapter names
read correctly (spot-check five); that the language lists are what the
menu shows; and that nothing from a bio page leaked into `titleText`.

### 8.6 New invariants for `DiscCorpusTests`

The existing sweep keeps every assertion. For every disc with
`expect.menu != null`, in the same parameterised test:

- `structure.json` decodes; every button's `command` is 16 hex characters;
  every `rect` lies within `frame`; button counts are 1…36 per menu.
- `VMCommand.decode` produces a non-`unresolved` target for every button
  on every entry menu, or the manifest lists the mnemonics it could not
  decode (`expect.menu.unresolvedMnemonics`), so a decoder regression is
  visible and a disc with genuinely opaque commands is honest.
- Every `.title(n)` target is a title in `scan.json` (HandBrake drops
  sub-second stubs with `--min-duration 1`, so the check is ⊆, with the
  count of unmatched targets pinned).
- **The play button's target equals `expect.outcomeIndex`** on every disc
  whose outcome is `single`, and equals the Play All index on `playAll`
  discs. This is the headline invariant: it is what proves the
  `JumpTT`-equals-HandBrake-title claim, disc by disc.
- The chapter menu's button count equals `featureChapterCount`, or the
  manifest records the difference and its reason (§3.3's table).
- `ChapterNames.markers` over the recorded `ocr.json` emits exactly
  `expect.menu.chapterNamesEmitted` rows, no duplicates, none above the
  chapter count, none empty, no `disputed` row included.
- `LanguageHints.lists` over `ocr.json` equals the recorded lists; in
  shape 1, the mapped track count equals the feature's audio stream count.
- `MenuTitleGuess.candidate` never equals a string that appears on a
  non-entry still — the filmography trap, pinned on Bloodsport by name.
- `tvSignal` is `false` on every movie disc and `true` on
  `tv-season-playall` once it is re-captured with menus.
- **The model is never called from the sweep.** A separate
  `MenuJudgeTests` suite runs only when `SystemLanguageModel.default
  .availability == .available` (`@Test(.enabled(if:))`), asks the recorded
  `judge.labels` of every disc that has one, and compares with the recorded
  answer — a *drift* check that is skipped, not failed, on a host without
  the model (gordon may well be one).

### 8.7 Space per disc, and when to revisit

| Item | Size | Basis |
|---|---|---|
| `scan.json` + stderr | 40–240 KB | #0055 |
| `lsdvd.json` | 5–60 KB | `-x` dumps cells |
| `ifo/` | 20 KB–1 MB | `VIDEO_TS.IFO` is small; a feature VTS IFO carries the VOBU address map and can reach several hundred KB |
| `menus/stills/` | 16 × 60–110 KB ≈ 1.0–1.8 MB | JPEG q≈0.8 at 720×480; the run's PNGs were 0.5–0.6 MB each |
| `menus/*.json` | 30–120 KB | 16 stills of observations with boxes |
| **corpus, per disc** | **≈ 1.5–3.5 MB** | |
| raw tier on joe, per disc | 5–70 MB (menu VOB cells + PNGs) | Bloodsport's menu VOB alone is 4.5 MB |

At 50 discs the corpus is ~100–175 MB, which is the point to decide between
git LFS for `stills/` and moving stills to the raw tier only. Not before.
The IFOs and JSON stay in git regardless — they are what the tests read.

One question the user should settle before the first push (§11): menu
stills are copyrighted artwork. In a private repository that is a
non-issue; if the repository is or becomes public, the stills should move
to the raw tier and the corpus keeps only the JSON — which is still enough
for every invariant above.

---

## 9. Risks and failure modes

Every row here ends the same way: the rip proceeds unchanged. That is the
principle, restated as a table.

| Failure | What happens | Where it is caught |
|---|---|---|
| **The filmography trap** — `Bloodsport (1987)` on five bio pages | never a label (no button rect contains it); never a title candidate (non-entry page); at most recorded as decoration | §4.2 attachment rule, §6 rule 3, corpus invariant |
| **Picture menus with no text** (icons, stylised art, text drawn in the subpicture overlay rather than the video) | tier 1 still resolves a lone title-jumping button; no label, caption says "the Play button"; no chapter names; recorded as `ocr.observations == []` | §4.1 "label unknown" caption |
| **Foreign-language menus** | lexicon first; the model second; "none of these" third; the chapter names are whatever language the disc prints (correct behaviour — Plex shows them as authored) | §4.2–4.3 |
| **Menus that boot through trailers** | irrelevant to structure: menus are enumerated from the PGC tables, not by playing the disc. A *play button* that targets a trailers-plus-feature title is the disagree caption — useful information | §4.1 |
| **OCR reads chapter text as a button label**, or a button label as a chapter | labels are attached by rect intersection and chapter captions by the rect *below* the thumbnail; a chapter caption inside no page-button rect is not a label; the printed number must match the PTT | §3.2, §4.2 |
| **The model chooses a label that is not there** | structurally impossible: the output schema is the closed set of labels we passed, and the index map is a second guard | §4.3 |
| **The model chooses wrongly among real labels** | a caption names a button and its title; the scan's choice stands; the runtime verdict runs; the archive records it for review | §4.3 residual risk |
| **Model unavailable** (Apple Intelligence off, model not ready, ineligible device, refusal, guardrail, locale) | `Answer.unavailable` → same as no answer; nothing retries | §4.3 |
| **`libdvdcss` missing** | structure only; no stills; one caption | §2.2 |
| **Helper crashes on a damaged disc** | separate process; `ProcessRunner` reports the exit; `MenuState.unavailable` | §2.1 |
| **Motion menus larger than the cap** | entry menus first, then stop; `truncated: true` | §1.2 |
| **A wrong chapter name** | a wrong label at the right timestamp in Plex | §3.3 |
| **A wrong chapter count** | cannot happen from this code: rows are bounded by HandBrake's own chapter count and deduplicated; fewer than half → no CSV | §3.3 |
| **A wrong language hint** | a caption the user reads beside a picker they still control; no preselection changes | §5.3 |
| **A wrong search term** | seeds an empty search box; the user types over it | §6 |
| **`JumpTT` numbering ≠ HandBrake's** (if the libhb reading is wrong) | the headline corpus invariant fails on the first disc; the caption is disabled until the mapping is fixed | §8.6 |
| **The helper and the scan contend for the drive** | the helper starts only after `scanState` is `.scanned` or `.failed` | §1.4 |
| **The user starts the rip before menu intelligence finishes** | the encode starts with bare `--markers`; the CSV is only passed when `menuState` is `.ready` at `start`; a late result is discarded (logged) — and the names can still be applied later as an upgrade (§7) | §1.4, `JobController.start` |
| **An upgrade remux silently re-encodes or shifts a chapter** | the staged file is `ffprobe`d and refused on any codec, stream-count, duration, chapter-timing or size difference; the original is untouched | §7.5 |
| **An upgrade names the wrong chapters** (disc count ≠ file count) | refused outright; Oppenheimer's 21-vs-20 is the known example | §7.3 |
| **`ffmpeg`/`ffprobe` missing** | no upgrade card; one caption; the rip path is unaffected | §7.2 |

Nothing above changes `StartGate`, `DiscTitleHeuristic`, `AudioTrackOptions
.preselection`, `EncodeSelection.make` or `PlexOrganizer`. If an
implementation finds it needs to touch any of them for a menu reason, that
is the signal it has crossed into the decision path.

---

## 10. Implementation order

### Slice 1 — the archive (ship on its own; nothing in the app changes)

Worth shipping alone because it is what the user asked for first, it needs
no distribution decision, and every later slice is measured against it.

1. `Tools/menudump/`: today's C tool promoted to a repository file with a
   `Makefile` against Homebrew `libdvdread` (the vendored build is slice
   2's), emitting `structure.json` and `cells/*.vob` per §8.3. Its own
   `COPYING`.
2. `Changeover/VMCommand.swift`, `MenuStructure.swift` (pure decode of
   `structure.json`), `Changeover/MenuOCR.swift` (the Vision request, one
   function, `nonisolated`), `ChapterNames.swift`, `LanguageHints.swift`,
   `MenuTitleGuess.swift`, `PlayButtonResolver.swift` (tiers 1–2). All
   `nonisolated`, no UI imports, so `swiftc` builds them into
   `Tools/menu-ocr` and `Tools/menu-derive`.
3. `Tools/capture-disc.sh` version 2 (§8.5); `disc.json` format version 2;
   `DiscCorpusTests` invariants (§8.6), with `MenuJudgeTests` skipped where
   the model is absent.
4. Capture Bloodsport (it is in the drive) and re-capture the four existing
   discs as they next pass through joe. Review. This is where §3–§6's rules
   get their second, third and fourth disc.

### Slice 2 — chapter names in the rip

1. Settle the decoder question (§2.4) with one experiment on joe.
2. `scripts/build-menudump.sh`, the vendored `libdvdread`, the helper in
   `Helpers/`, the entitlement, the preflight gates (§2.3). This is the
   first slice that touches #0102's pipeline, so it lands with `RELEASE.md`
   notes.
3. `JobController.menuState`, the helper launch after the scan, OCR in-app.
4. `EncodeController.arguments(markers:)`, the CSV in the job directory,
   `RipRequest.chapterMarkers: [MarkerRow]? = nil` (additive, wire-safe,
   same shape as `tv`), verified with `ffprobe -show_chapters` on joe.
5. The Confirm caption "23 chapter names from the disc menu will be
   written" and the tier-1 confirmation line.

### Slice 3 — labels and hints

1. Language captions and the shape-1 badge (§5.3); `--aname` behind the
   user's decision.
2. The lexicon and `MenuJudge` (§4.2–4.3), with the archive's `judge`
   record.
3. `MenuTitleGuess` into `SearchPrefill` (§6).
4. `tvSignal` into `RipModeProposal` when the TV plan lands.

### Slice 4 — upgrading existing imports (§7)

1. `AppSettings.ffmpegPath`; `LibraryFileInventory.parse` over captured
   `ffprobe` JSON (fixtures from the two library files named in §7.1).
2. `UpgradeProposal.compare` with the refusal rules, pinned on the
   Oppenheimer 21-vs-20 shape and on Hornet's Nest's `und` tracks.
3. `RipRequest.upgrade`, the remux runner with the staged-then-verified
   swap, `JobProgress.Unit.remux`, the Confirm card and the Done card.
4. Run it over the library, disc by disc, as the discs come back through
   the drive. This slice is independent of slice 3 except for the audio
   mapping (§5.2), and can land before it with chapters only.

### Not in any slice

- Playing menus, rendering subpicture highlights, or following GPRM-driven
  command chains. Record them; do not emulate the VM.
- Using the model on anything but button labels. No summarising, no
  free-text extraction, no "what is this disc".
- Reading title VOBs for any purpose here.
- Blu-ray.

---

## 11. Decisions the user should make

1. **`libdvdcss` stays outside the bundle and is found at runtime** (§2.1).
   The user said `libdvdread` ships; this document recommends that the
   decryption library does not, for the reasons HandBrake has, and that
   its path is a Settings field. Confirm or overrule.
2. **Menu stills in git, or raw-tier only** (§8.7). In git is more useful for
   review; raw-tier only is the right call if the repository is public.
3. **Track names into the file** (§5.3): whether a user-confirmed name on an
   untagged track is written with `--aname`. Recommended yes, off by
   default, because it is the only way the user's "tracks are not named"
   complaint reaches Plex.
4. **May the structural play-button target preselect the picker when the
   heuristic returns `.none` or `.ambiguous`** (§4.1)? Recommended no for
   now — the picker is shown either way, and the archive should first show
   how often the target and the heuristic disagree.
5. **`ffmpeg`/`ffprobe` as an optional Homebrew tool for the upgrade path**
   (§7.2), located through a Settings path like HandBrakeCLI and never
   bundled. The alternative — writing the remux with AVFoundation so no
   tool is needed — is possible for stream tags but awkward for chapter
   titles, and would put the one operation that overwrites a library file
   on code with no `-c copy` guarantee to check against. Recommended:
   ffmpeg, optional, verified by `ffprobe` before every swap.
6. **Whether an upgrade may rename chapters that already carry real
   names** (§7.3). Recommended: only with an explicit tick on the card;
   `Chapter N` placeholders are renamed without asking.
