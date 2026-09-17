# Step-flow UX for the rip window

A design for replacing `MetadataEntryView`'s single scrolling stack with a
step-by-step flow: one focused screen per stage of a rip, earlier decisions
carried forward as a summary, the raw log off the main path entirely.

Written 2026-09-17 against the code as of `f16c95c`, to be implemented in one
sitting. Everything a decision depends on is a pure, `nonisolated` value
function so it is covered by `ChangeoverTests` on gordon — UI tests are
forbidden in this project (`docs/ui-test-crash-prevention.md`).

---

## The problem, in the user's words

> Everything is a scrolling stack and it is all smooshed together once the
> movie search results appear and the DVD is scanned. Not all these details
> need to be presented all the time. […] It could have more of a step by step
> sequence which is more focused on each step and then hide those details
> after moving to the next step. Once the movie is selected those details can
> be carried over but hide the search results. The logs at the bottom are also
> not necessary. […] We can simply see the percentage and ETA to completion
> along with the movie details.

What the window shows today, all at once: search field + TMDB results; the
Plex folder/file preview; scan warnings; the "Main feature — Title N" row
with an extras line; the full title table; the runtime verdict; the audio
checkboxes; the collapsed subtitle summary; a 130-point HandBrake log pane;
and a pinned Start button with a #0053 reason caption. `Changeover-problem.png`
is the screenshot: an empty results list, an orange libdvdcss warning, the
`.none` heuristic text, an empty title table and three `▶ Scanning: N%` log
lines, with Start disabled and nothing telling the user what to do first.

## Design in one paragraph

The window shows exactly one **step** at a time. The step is not stored
anywhere — it is **derived** by a pure function from state the app already
holds (`JobController` + a small new `RipFlowController`), so it can never
disagree with what the app is actually doing, and a Phase 4 client that
mirrors the same inputs derives the same step. Five steps:
**Insert disc → Choose movie → Confirm → Ripping → Done.** Scanning is not
its own step: the scan runs while the user searches, and its status is a
one-line strip on *Choose movie* and the disc panel on *Confirm*. The log
leaves the rip window; the History window (already per-job, #0048) is the
one place it lives, one click away from *Ripping* and *Done*.

---

## 1. The step list as a state machine

```
                    ┌──────────────────────────────────────────────────────────┐
                    │  job running (jobs.current != nil)  ⇒  RIPPING, always   │
                    └──────────────────────────────────────────────────────────┘

 no disc / ejecting /            disc mounted                movie chosen +
 unmounted-but-not-ejected       (scan any state)            Continue pressed
 ┌─────────────┐  insert   ┌──────────────┐  Continue   ┌──────────────┐  Start  ┌──────────┐
 │ INSERT DISC │ ────────▶ │ CHOOSE MOVIE │ ──────────▶ │   CONFIRM    │ ──────▶ │ RIPPING  │
 │             │ ◀──────── │              │ ◀────────── │              │         │          │
 └─────────────┘  removed  └──────────────┘ Change movie└──────────────┘         └────┬─────┘
        ▲            ▲            ▲                             ▲                     │ job ends
        │            │            │                             │                     ▼
        │            │            │  Next disc (disc gone)      │  Adjust & retry  ┌──────────┐
        │            │            └─────────────────────────────┼───────────────── │   DONE   │
        │            │  a *different* disc inserted             │                  │          │
        │            └──────────────────────────────────────────┼───────────────── └──────────┘
        │  Next disc (no disc in drive)                         │
        └───────────────────────────────────────────────────────┘

 Disc swap at any step before RIPPING: SelectionReset.reconcile fires,
 the movie selection clears, step returns to CHOOSE MOVIE for the new disc.
 Disc pulled during RIPPING (#0052): the job ends `.cancelled` with
 `discRemovedDuringJob`, step becomes DONE ("Disc removed").
```

Derivation priority (first match wins) — this is `FlowStep.derive`:

| # | Condition | Step |
|---|-----------|------|
| 1 | `jobs.current != nil` | `.ripping` |
| 2 | `jobs.history.last` exists and its id ≠ `dismissedJobID` and (no disc, or same disc as the job, or the job's disc is unknown) | `.done` |
| 3 | `jobs.isEjecting` | `.insertDisc(.ejecting)` |
| 4 | `jobs.discUnavailable` | `.insertDisc(.discUnavailable)` |
| 5 | `jobs.insertedDisc == nil` | `.insertDisc(.noDisc)` |
| 6 | movie selected **and** `movieConfirmed` | `.confirm` |
| 7 | otherwise | `.chooseMovie` |

Row 2's disc clause is what makes "insert the next disc" leave *Done*
automatically: a *different* disc (by `SelectionReset.sameDisc`) supersedes
the outcome card; the same disc still in the drive (a failed job the user
wants to retry) keeps it. Rows 3–5 never apply while a job runs (row 1) — a
disc pulled mid-job is *Ripping* until the job settles, then *Done*.

The awkward states, and where each lands:

| State | Step | What the user sees |
|---|---|---|
| No disc | Insert disc | "Insert a DVD" + last outcome one-liner |
| Eject in flight (#0045) | Insert disc | "Ejecting…" — nothing actionable |
| Unmounted but not ejected (#0049) | Insert disc | `StartDecision.discUnavailable.reason` + **Eject** button (retry) |
| Scanning | Choose movie / Confirm | one-line strip "Scanning disc…" with **Cancel scan** (#0051); Confirm's disc panel shows the same, Start reason "Waiting for the disc scan to finish." |
| Scan failed | Choose movie / Confirm | strip "Scan failed — <reason>" + **Rescan**; Confirm's disc panel = today's `failedView` |
| No titles (#0039) | Choose movie / Confirm | strip "The scan read no titles" + **Rescan**; Confirm's disc panel = today's `noTitlesView`; Start reason `.noTitlesOnDisc` |
| Play All (#0025) | Confirm | disc panel = today's `.playAll` sentence + full table, nothing preselected; Start reason "Pick a title." |
| `.none` heuristic | Confirm | disc panel = today's `.none` sentence + full table |
| Runtime mismatch (#0032) | Confirm | verdict row in red + **Rip anyway**; Start reason `.runtimeMismatchUnconfirmed` |
| Runtime lookup loading | Confirm | movie card caption "Checking TMDB runtime…"; Start reason `.runtimeLookupLoading` |
| No audio selected (#0027) | Confirm | `AudioTrackOptions.notice`; Start reason `.noAudioTrackSelected` |
| Cancel (#0046) | Ripping | **Cancel** → `AppDelegate.requestCancel` alert; "Cancelling…" until the job settles; disabled during `organizing` with `CancelPolicy` reason as tooltip |
| Disc removed mid-job (#0052) | Ripping → Done | Done shows "Disc removed" + `JobPresentation.discRemovedDetail` |
| Job failed | Done | `FailurePresenter` headline + details, **Retry** (gated by `retryDecision`), **Adjust & retry**, **Show log** |
| Job succeeded | Done | "Filed as <path>", elapsed, disc ejected / could not be ejected, **Next disc** |
| Every #0053 reason | Confirm | unchanged: caption beside Start + tooltip, from `StartGate.decide` |

`StartGate` is untouched. Two of its reasons (`.noDisc`, `.noMovieSelected`)
can no longer be *reached* from the Confirm step because the flow routes
those states elsewhere, but the gate keeps them — it is the failsafe, and
Phase 4 will call it without the flow in front of it.

---

## 2. Per-step wireframes

All steps share one frame. The **body** is the only flexible region; the
**action bar** is pinned and is the only thing with a minimum height, which
is the #0140 rule restated (see §5).

```
┌─ Changeover ─────────────────────────────────────────────┐
│ <step title>                                  <subtitle> │  header, fixed
├──────────────────────────────────────────────────────────┤
│                                                          │
│                      <body>                              │  flexible; scrolls
│                                                          │  only if it must
├──────────────────────────────────────────────────────────┤
│ <secondary links>            <reason caption> [Primary]  │  action bar, pinned
└──────────────────────────────────────────────────────────┘
```

### Step 1 — Insert disc

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Insert a disc                                            │
├──────────────────────────────────────────────────────────┤
│                                                          │
│                   (opticaldisc glyph)                    │
│         Insert a DVD to begin. The disc is scanned       │
│         automatically and this window opens on it.       │
│                                                          │
│   ● Last job: Blade Runner (1982) — finished in 41m 12s  │  only if history non-empty
│                                                          │
├──────────────────────────────────────────────────────────┤
│ History…   Settings…                                     │
└──────────────────────────────────────────────────────────┘

variant .discUnavailable:
│   ⚠ The disc was unmounted but could not be ejected —    │
│     retry Eject or remove the disc before starting.      │
│                                              [Eject]     │
variant .ejecting:
│   ◌ Ejecting…                                            │
```

Hides: everything. Forward: automatic on insertion (`DVDMonitor` →
`insertDisc` → step re-derives). No primary button.

### Step 2 — Choose movie

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Choose the movie                     Disc: FARGO_WS      │
├──────────────────────────────────────────────────────────┤
│ ◌ Scanning disc — this takes tens of seconds…  Cancel    │  ScanStatusStrip
├──────────────────────────────────────────────────────────┤
│ [ Search movies…                              ] [Search] │
├──────────────────────────────────────────────────────────┤
│ ▣ Fargo                                    1996 · tmdb-275│  List, fills body
│ ▢ Fargo                                    2014 · tmdb-…  │
│ ▢ …                                                      │
│                                                          │
├──────────────────────────────────────────────────────────┤
│                                              [Continue]  │  enabled iff a row is selected
└──────────────────────────────────────────────────────────┘

strip variants:  "✓ Scan complete — 8 titles, main feature detected"
                 "✓ Scan complete — 8 titles, choose one on the next step"
                 "✗ Scan failed — <DiscTitleListView.message>   [Rescan]"
                 "✗ The scan read no titles from this disc      [Rescan]"
```

Shows: search, results with posters, the scan's one-line status. Hides: the
folder preview, the title table, tracks, warnings, the log. Forward:
**Continue** (also Return, also double-click a row) → Confirm. Back: none
(Eject is in the status menu). Carries over: query, results, selection,
runtime lookup — all on `MovieSearchViewModel`, unchanged.

### Step 3 — Confirm

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Confirm the rip                                          │
├──────────────────────────────────────────────────────────┤
│ ┌──┐ Fargo (1996)                          Change movie  │  MovieCard
│ │▒▒│ Movies/Fargo (1996) {tmdb-275}/Fargo (1996).mp4     │
│ └──┘ TMDB runtime 1h 38m                                 │
│                                                          │
│ ⚠︎ libdvdcss could not open the raw device … (#0024)     │  scan warnings, if any
│ Main feature — Title 1 · 1:37:52 · 21 chapters · 6.8 GB  │  DiscTitleListView, as today
│ Extras: none  Choose…                     Show all titles│
│ Title 1 matches the TMDB runtime (Δ +14s)                │
│                                                          │
│ Audio                                                    │  TrackSelectionView, as today
│ ☑ English                                                │
│ ☐ English  Commentary                                    │
│ ▸ 6 subtitle tracks, none carried into the output        │
│                                                          │
├──────────────────────────────────────────────────────────┤
│                    Pick a title.  [Start Ripping]        │  StartGate reason + button
└──────────────────────────────────────────────────────────┘

disc panel while scanning:   "◌ Scanning disc…  Cancel scan"
disc panel on scan failure:  today's failedView / noTitlesView with Rescan
```

Shows: the chosen movie as a card, the destination path, the runtime
caption, then the *whole* disc section exactly as `DiscTitleListView` and
`TrackSelectionView` render it today. Hides: the search field and results,
the log. Forward: **Start Ripping** → `jobs.start(request:settings:)`,
step re-derives to Ripping. Back: **Change movie** → Choose movie with the
results still there and the same row still selected. Carries over: the movie
(view model), title/audio/extras/acknowledgement (`JobController`).

### Step 4 — Ripping

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Ripping                                                  │
├──────────────────────────────────────────────────────────┤
│ Fargo (1996)                                             │
│ Movies/Fargo (1996) {tmdb-275}/Fargo (1996).mp4          │
│                                                          │
│ Encoding the feature                                     │  JobPresentation.label
│ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   31 %       │  determinate when known
│ ETA 45 min · 56 fps · elapsed 12m 08s                    │
│                                                          │
│ Then: 2 extras                                            │  only when extras planned
├──────────────────────────────────────────────────────────┤
│ Show log…                                  [Cancel Job]  │
└──────────────────────────────────────────────────────────┘

phase variants for the middle block:
  starting    "Checking setup"                       indeterminate bar, no ETA line
  encoding    "Encoding the feature"                 determinate + ETA/fps
  fallback    "Retrying with MakeMKV"                indeterminate (makemkvcon lines are not parsed today)
  organizing  "Moving into Plex"                     indeterminate; Cancel disabled, tooltip = CancelPolicy reason
  extras      "Encoding extra 2 of 3 — title 7"      determinate + ETA for *that* extra
  cancelling  "Cancelling…"                          indeterminate; Cancel disabled
```

Shows: movie details, phase, percentage, ETA, throughput, elapsed. Hides:
the log, the disc section, search. Forward: automatic when the job settles.
Back: **Cancel Job** (confirmed by the existing `NSAlert`). **Show log…**
opens the History window on this job (`showHistory(selecting:)`).

### Step 5 — Done

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Done                                                     │
├──────────────────────────────────────────────────────────┤
│ ✓ Fargo (1996)                                           │
│   Filed as /Volumes/Plex/Movies/Fargo (1996) {tmdb-275}/ │
│            Fargo (1996).mp4                              │
│   Finished in 41m 12s · disc ejected                     │
│                                                          │
├──────────────────────────────────────────────────────────┤
│ Show log…   Reveal in Finder                [Next Disc]  │
└──────────────────────────────────────────────────────────┘

failed:
│ ✗ Fargo (1996) — Failed                                  │
│   HandBrakeCLI exited with status 3        ← FailurePresenter.headline
│   <details lines>                                        │
│ Show log…            [Adjust & Retry]  [Retry]  [Next Disc]
cancelled:            "Cancelled"                — same buttons as failed
disc removed (#0052): "Disc removed" + discRemovedDetail; only [Next Disc]
eject failed (#0049): success card + "⚠ the disc could not be ejected — retry Eject"  [Eject]
```

Shows: outcome, where the file landed, elapsed, eject result, the next
action. Hides: everything else. Forward: **Next Disc** dismisses the
outcome (`dismissedJobID`) → Insert disc, or Choose movie if a disc is
already in. **Retry** replays the recorded request (`jobs.retry`) → Ripping.
**Adjust & Retry** dismisses and re-enters Confirm with the movie and
selection intact (only offered when `retryDecision == .retry`, i.e. same
disc still in, scan held).

---

## 3. Progress and ETA

HandBrake prints, several times a second, lines like

```
Encoding: task 1 of 1, 4.12 % (66.32 fps, avg 56.07 fps, ETA 00h45m29s)
Encoding: task 1 of 1, Searching for start time, 0.00 %
Scanning title 1 of 1, preview 3, 30.00 %
Muxing: this may take awhile...
```

`EncodeController.isProgressOnly` already matches every one of these shapes
exactly, and `progressFraction(fromLogLine:)` already pulls the percentage.
Neither is wired to anything visible: `JobState.progress` is always `nil`
("no progress parser exists yet"). This design adds the parser and threads
the result onto the job.

### 3.1 The parsed value

```swift
/// One HandBrake progress line, parsed. Pure data; `Codable` so it rides on
/// `JobSnapshot` to a Phase 4 client unchanged.
nonisolated struct HandBrakeProgress: Codable, Sendable, Equatable {
    enum Stage: String, Codable, Sendable {
        case scanning   // "Scanning title n of m …" — the pre-encode read
        case encoding   // "Encoding: task n of m, pp.pp %"
        case muxing     // "Muxing: this may take awhile..." — fraction 1.0
    }
    var stage: Stage
    /// 0…1 within the current task. `Searching for start time` reports 0.
    var fraction: Double
    var task: Int          // "task 1 of 1" → 1; 1 for scanning/muxing
    var taskCount: Int
    var fps: Double?       // instantaneous; nil before HandBrake reports it
    var averageFPS: Double?
    var etaSeconds: Int?   // "ETA 00h45m29s" → 2729; nil when absent
}

nonisolated enum HandBrakeProgressParser {
    /// `nil` for anything that is not a whole progress line — including a
    /// glued progress+log fragment, which `isProgressOnly` already refuses.
    static func parse(_ line: String) -> HandBrakeProgress?
}
```

`parse` guards with `EncodeController.isProgressOnly(line)` first, so the
log buffer, the failure-classifier tail and the progress bar can never
disagree about what a progress line is. `progressFraction(fromLogLine:)`
stays and becomes `parse(line)?.fraction` for `.encoding` — one
implementation, the old signature kept for its existing tests.

### 3.2 Job-level progress: which encode this is

`task 1 of N` is per HandBrake invocation. Today `N` is always 1 (single
pass, no `--subtitle scan`), and **#0031's extras run one `HandBrakeCLI`
per extra**, so a job with two extras sees `task 1 of 1` climb 0→100 three
times. The job has to say *which* encode the fraction belongs to, and the
pipeline is the only thing that knows:

```swift
nonisolated struct JobProgress: Codable, Sendable, Equatable {
    enum Unit: Codable, Sendable, Equatable {
        case feature
        case fallback                       // #0015: the second HandBrake pass over the .mkv
        case extra(index: Int, count: Int, titleIndex: Int)   // 1-based index
    }
    var unit: Unit
    var encode: HandBrakeProgress
    var receivedAt: Date
}
```

Plumbing (all additive, defaults keep every existing call site and test
compiling):

1. `EncodeController.encode(…, progress: @escaping @MainActor (HandBrakeProgress) -> Void = { _ in }, …)`.
   Inside the `ProcessRunner.run` line handler, next to the existing
   `Task { @MainActor in log(line) }`: `if let p = HandBrakeProgressParser.parse(line) { Task { @MainActor in progress(p) } }`.
2. `DVDPipeline.init(…, reportProgress: @MainActor (JobProgress) -> Void = { _ in })`.
   The feature encode passes `{ reportProgress(JobProgress(unit: .feature, encode: $0, receivedAt: .now)) }`;
   the fallback's second pass `.fallback`; the extras loop
   `.extra(index: i + 1, count: extras.items.count, titleIndex: item.titleIndex)`.
3. `JobController.JobContext` gains `let progress: @MainActor (JobProgress) -> Void`,
   bound in `start` to `{ [job] in job.reportProgress($0) }` — the same
   job-bound shape as `log`/`phase`, so a late report can never land on the
   wrong job. `pipelineRunner` passes it through.
4. `Job` gains `private(set) var progress: JobProgress?` and
   `func reportProgress(_:)`, which **drops** a report once
   `state.phase.isTerminal` (mirrors `advance(to:)`'s stance) and otherwise
   assigns. `JobSnapshot` gains `let progress: JobProgress?` — an optional
   with synthesized `Codable`, so an older payload decodes to `nil`.
5. `JobPresentation.make` reads `snapshot.progress?.encode.fraction ??
   snapshot.state.progress` for `.encoding`/`.extras`/`.fallback`. The
   history window's `(31%)` text and the ripping step's bar come from the
   same place. `JobState.progress` is left alone — still always `nil`, still
   wire-compatible; retiring it is not today's work.

Phase edges clear stale progress: `Job.advance(to:)` sets `progress = nil`
on a successful transition, so the `organizing` bar never shows the feature
encode's last 100 %.

### 3.3 Presenting it

```swift
extension JobPresentation {
    nonisolated struct ProgressSummary: Equatable, Sendable {
        let unitLabel: String        // "Encoding the feature" / "Encoding extra 2 of 3 — title 7" / "Retrying with MakeMKV"
        let percentText: String?     // "31 %"; nil when indeterminate
        let etaText: String?         // "ETA 45 min" / "ETA 1h 05m" / "ETA under a minute"; nil when unknown
        let rateText: String?        // "56 fps" (average, not instantaneous — steadier)
        let elapsedText: String      // formatElapsed(now - startDate)
        let isDeterminate: Bool
    }
    nonisolated static func progressSummary(for snapshot: JobSnapshot, now: Date) -> ProgressSummary
    nonisolated static func formatETA(seconds: Int) -> String
}
```

ETA is HandBrake's own per-task number, shown raw and rounded to minutes.
No smoothing, no summing across extras — "ETA" on the ripping step always
means *this encode*, and the "Then: N extras" line says more is coming.

### 3.4 The log

Unchanged as data: `JobLog` per job, `logDisplayRows` on the controller.
It simply has no view in the rip window any more. *Ripping* and *Done* carry
a **Show log…** link → `AppDelegate.showHistory(selecting: job.id)`, which
already exists for notification clicks. `logDisplayRows`/`logLines` stay
(tests read them); `MetadataEntryView.logArea` is deleted with the view.

---

## 4. Types

### 4.1 New — pure, `nonisolated`, unit-tested

**`FlowStep.swift`**

```swift
/// The one screen the rip window shows. Derived, never stored: see `derive`.
/// `Codable` with small payloads so a Phase 4 client can receive it as-is.
nonisolated enum FlowStep: Equatable, Sendable, Codable {
    enum InsertReason: String, Codable, Sendable { case noDisc, ejecting, discUnavailable }
    case insertDisc(InsertReason)
    case chooseMovie
    case confirm
    case ripping(JobID)
    case done(JobID)

    /// Everything `derive` looks at — plain values read off `JobController`
    /// and `RipFlowController` at one instant.
    struct Inputs: Equatable, Sendable {
        var currentJobID: JobID?
        var lastJob: LastJob?               // history.last: id + selectionDisc
        var dismissedJobID: JobID?
        var isEjecting: Bool
        var discUnavailable: Bool
        var insertedDisc: DiscInsertion?
        var hasMovieSelected: Bool
        var movieConfirmed: Bool            // Continue was pressed for this selection
        struct LastJob: Equatable, Sendable { var id: JobID; var disc: DiscInsertion? }
    }

    /// The priority table in §1. Pure.
    static func derive(_ inputs: Inputs) -> FlowStep
}
```

**`ScanStatusLine.swift`** (or a `DiscTitleFormatting` extension)

```swift
nonisolated enum ScanStatusLine {
    enum Action: Equatable, Sendable { case none, cancelScan, rescan }
    struct Line: Equatable, Sendable { let text: String; let tone: JobPresentation.Tone; let action: Action }
    /// The one-liner for the Choose-movie strip and the Insert-disc card.
    static func line(for scanState: ScanState) -> Line?     // nil for .idle
}
```

Reuses `DiscTitleListView.message(for:)` (made `static` internal on
`DiscTitleFormatting` as `scanFailureMessage(_:)`) and
`DiscTitleFormatting.noTitlesMessage` so the strip and the disc panel say
the same thing.

**`HandBrakeProgress.swift`** — `HandBrakeProgress`, `HandBrakeProgressParser` (§3.1).

**`JobProgress`** — in `Jobs/JobProgress.swift` (§3.2).

**`JobPresentation` additions** — `progressSummary`, `formatETA` (§3.3), and:

```swift
extension JobPresentation {
    nonisolated struct OutcomeCard: Equatable, Sendable {
        enum Action: Equatable, Sendable { case nextDisc, retry, adjustAndRetry, eject, revealInFinder(URL), showLog }
        let headline: String          // "Fargo (1996)" / "Fargo (1996) — Failed" / "Disc removed"
        let tone: Tone
        let lines: [String]           // "Filed as …", "Finished in 41m 12s · disc ejected", failure details
        let actions: [Action]         // in display order; primary is last
    }
    /// `retryDecision` from `JobController.retryDecision(id:)`; `discEjected`
    /// is `insertedDisc == nil`; `discUnavailable` is #0049's flag.
    nonisolated static func outcomeCard(
        for snapshot: JobSnapshot, discRemovedDuringJob: Bool,
        retryDecision: RetryDecision, discEjected: Bool, discUnavailable: Bool
    ) -> OutcomeCard
}
```

`DiscTitleFormatting.runtimeCaption(_ lookup: RuntimeLookup) -> String?`
— today's `MetadataEntryView.runtimeCaption`/`formatRuntime`/
`runtimeNotRunText`, moved verbatim so they gain tests.

### 4.2 New — MainActor, `@Observable`

**`RipFlowController.swift`**

```swift
@Observable
final class RipFlowController {
    let search = MovieSearchViewModel()          // lifetime = the flow's, as before
    private(set) var selectedMovieID: Int?
    private(set) var selectionDisc: DiscInsertion?   // #0034, moved from the view's @State
    private(set) var movieConfirmed = false
    private(set) var dismissedJobID: JobID?

    func inputs(jobs: JobController) -> FlowStep.Inputs
    func step(jobs: JobController) -> FlowStep { FlowStep.derive(inputs(jobs: jobs)) }

    // Intents — each a one-line state change; the view calls exactly these.
    func select(movieID: Int?, jobs: JobController, apiKey: String)   // sets selectionDisc, forwards to search.select
    func continueToConfirm()          // movieConfirmed = true (only if a movie is selected)
    func changeMovie()                // movieConfirmed = false; keeps query/results/selection
    func dismissOutcome(jobs:)        // dismissedJobID = jobs.history.last?.id
    func adjustAndRetry(jobs:)        // dismissOutcome + movieConfirmed = true
    func queryChanged(apiKey:)        // clears selectedMovieID + movieConfirmed, forwards (#0030's stuck-repick fix stays)
    func runSearchNow(apiKey:)
    /// #0034 — `SelectionReset.reconcile`, exactly today's `reconcileSelection`.
    /// `.reset` also clears `movieConfirmed`.
    func reconcile(jobs: JobController)
}
```

Owned by `AppDelegate` (`let flow = RipFlowController()`, injected with
`.environment(flow)` beside `settings`/`jobs`) so the flow outlives the
window like the job does, and so Phase 4 can drive it without a window.
`AppDelegate.init(jobs:)` (tests) gets a default. The thin root view still
runs `.onChange(of: jobs.insertedDisc)` / `.onChange(of: jobs.isRunning)` →
`flow.reconcile(jobs:)`, as `MetadataEntryView` does today — the
observation trigger stays in SwiftUI, the decision stays pure.

### 4.3 Views (thin)

| View | Role |
|---|---|
| `RipFlowView` | window root. `switch flow.step(jobs:)` → one step view; owns the shared frame (header / body / pinned action bar). No logic beyond the switch. |
| `InsertDiscStepView` | the three `InsertReason` variants; last-outcome one-liner via `JobPresentation.menuSummary`-style text; Eject via `jobs.ejectDisc()`. |
| `ChooseMovieStepView` | `ScanStatusStrip` + search bar + results `List` (takes `MovieRow` from `MetadataEntryView`). `Continue` = `.keyboardShortcut(.defaultAction)`. |
| `ConfirmStepView` | `MovieCard` (poster from `search.posterURL`, folder/file preview, runtime caption) + `DiscTitleListView` + `TrackSelectionView` in a `ScrollView`; action bar = today's `actionBar` verbatim (`StartGate.decide` → caption + button). |
| `RippingStepView` | reads `jobs.current!.snapshot` → `JobPresentation.progressSummary`; `ProgressView(value:)` or indeterminate; Cancel via `AppDelegate.requestCancel`. |
| `DoneStepView` | `JobPresentation.outcomeCard` → headline/lines/buttons. |
| `ScanStatusStrip` | one `HStack` from `ScanStatusLine.line(for:)`. |
| `MovieCard` | poster + `MovieMetadata.folderName`/`fileName` + runtime caption. |

Reused unchanged: `DiscTitleListView` (its scanning/failed/noTitles branches
*are* the Confirm step's disc panel), `TrackSelectionView`, `JobHistoryView`,
`JobLogView`, `StatusMenuView`, `SettingsView`.

Retired: **`MetadataEntryView`** — split as above; `logArea` and
`failureBanner` deleted (the failure now has a whole step). The file goes.
`MetadataWindowReuseTests` keep passing: they assert window reuse and that
the reused window keeps the same `JobController`, not the view type.

`AppDelegate.showMetadataEntry` hosts `RipFlowView().environment(settings).environment(jobs).environment(flow)`.
Window default `620×680`, `minSize` stays `560×560`.

---

## 5. Constraints, and how the design meets them

**MainActor-by-default, `@Observable`.** `RipFlowController` is a plain
`final class` — MainActor for free, `@Observable`, never
`ObservableObject`. `FlowStep`, `Inputs`, `HandBrakeProgress`, `JobProgress`,
`ProgressSummary`, `OutcomeCard`, `ScanStatusLine` are file-scope
`nonisolated` values, the convention `ScanState`/`RuntimeLookup`/
`StartDecision` established, so `derive`/`parse`/`progressSummary` are
callable from the test target's non-isolated helpers and from the
`nonisolated` pipeline. The progress closure hops with
`Task { @MainActor in progress(p) }` exactly like `log`.

**Every decision behind a pure seam; no UI tests.** Which step is shown
(`FlowStep.derive`), what the strip says (`ScanStatusLine.line`), what the
bar shows (`HandBrakeProgressParser.parse` → `JobPresentation.progressSummary`),
what Done offers (`outcomeCard`), whether Start is enabled (`StartGate`,
unchanged), whether the selection survives a disc swap (`SelectionReset`,
unchanged) — all plain functions. The views contain `switch`, `if let`, and
layout.

**Thin views.** Each step view is under ~80 lines and holds no `@State`
except `DiscTitleListView.showFullTable` / `TrackSelectionView
.subtitlesExpanded`, which already exist and are display-only.

**Window sizing (#0140).** The rule, restated so it survives the rewrite:
*the pinned action bar is the only view that may contribute to the window's
minimum height.* `RipFlowView`'s body slot is `frame(maxHeight: .infinity)`
with no `minHeight`; Choose movie's results `List` and Confirm's
`ScrollView` fill it and scroll internally; Confirm keeps
`TrackSelectionView` at natural height inside the single outer `ScrollView`
(the #0140 review's reasoning about nested scrollers still holds); the
title table keeps its `160…260` cap. Ripping and Done have no scroller at
all — their content is bounded by construction. Nothing regresses on a
7-audio/21-subtitle disc because the Confirm step is today's layout minus
the search results and the log, i.e. strictly shorter.

**Phase 4.** `FlowStep` and `JobProgress` are `Codable` values with no
references. A remote client that subscribes to `JobSnapshot` (already has
progress after this change) plus the handful of `Inputs` fields derives the
same `FlowStep` with the same function — `RemoteControl.md`'s "intended
loop" (search → confirm → start → watch progress → next disc) is these five
steps. `StartGate.decide` gates the remote Start unchanged (#0070's plan).

---

## 6. Test plan (pure parts only, `ChangeoverTests`, run once on gordon)

`FlowStepTests`
- one `@Test` per row of the priority table, plus the interactions:
  running job + disc pulled → `.ripping`; done + same disc → `.done`;
  done + different disc → `.chooseMovie`; done + no disc + dismissed →
  `.insertDisc(.noDisc)`; ejecting beats discUnavailable beats noDisc;
  movie selected but not confirmed → `.chooseMovie`; confirmed + ejecting →
  `.insertDisc(.ejecting)` (environment blockers outrank content, the #0053
  ordering); a `lastJob` with `disc == nil` (test-built) still shows `.done`.

`HandBrakeProgressParserTests`
- the sample line → `.encoding`, `0.0412`, task 1/1, fps 66.32, avg 56.07,
  eta 2729; no parenthetical → nils; `Searching for start time` → 0;
  `task 2 of 2`; `Scanning title 1 of 1, preview 3, 30.00 %` → `.scanning`,
  0.3; `Muxing:` → `.muxing`, 1.0; the two glued fragments from the #0043
  review fixtures (`…ETA 00h00m16s)ERROR: avformatMux…`,
  `…24.35 %Signal 2 received…`) → `nil`; `progressFraction(fromLogLine:)`
  still equals `parse(_:)?.fraction` on every existing fixture line.

`JobProgressTests` / `JobTests` additions
- `reportProgress` after `finish` is dropped; `advance(to:)` clears it;
  `snapshot.progress` round-trips through `JSONEncoder`; a snapshot encoded
  without the key decodes with `progress == nil`.

`JobPresentationTests` additions
- `make` returns `.determinate(0.31)` from `snapshot.progress`;
  `progressSummary` labels: feature / `Encoding extra 2 of 3 — title 7` /
  fallback; `formatETA(2729) == "ETA 45 min"`, `formatETA(3900) == "ETA 1h 05m"`,
  `formatETA(30) == "ETA under a minute"`; `outcomeCard` for succeeded /
  failed (headline + `FailurePresenter` details, `.retry` only when
  `retryDecision == .retry`) / cancelled / disc removed (no retry) /
  `discUnavailable` (adds `.eject`).

`RipFlowControllerTests` (uses `FakeRunnerSupport`'s `JobController`)
- `continueToConfirm` with no selection is a no-op; `changeMovie` keeps
  `search.results` and `selectedMovieID`; `queryChanged` clears
  `movieConfirmed` (the #0030 handoff bug can't come back through the new
  flag); `reconcile` on a different disc resets selection *and*
  `movieConfirmed`; `reconcile` on the same disc keeps both;
  `dismissOutcome` then a job finishing makes `step == .done` again for the
  new job; `adjustAndRetry` lands on `.confirm` with the movie intact.

`ScanStatusLineTests`, `DiscTitleFormattingTests` additions
- one case per `ScanState`; `runtimeCaption` for each `RuntimeLookup` case
  (never reads like a pass for `.unavailable`).

`DVDPipelineProgressReportingTests` (optional — cut first if short on time)
- with the existing `ProcessRunner` script-based fixtures, a fake
  "HandBrakeCLI" that prints one progress line makes `reportProgress`
  fire with `unit == .feature`; the extras loop reports
  `.extra(index: 1, count: 1, …)`.

`DVDPipelineCancellationTests`, `EncodeControllerTests`, `JobControllerTests`
compile unchanged because every new parameter is defaulted.

---

## 7. Implementation order (one sitting)

1. **Parser** — `HandBrakeProgress.swift` + tests. Make
   `progressFraction(fromLogLine:)` delegate to it. (~30 min)
2. **Progress on the job** — `JobProgress`, `Job.progress`/`reportProgress`,
   `JobSnapshot.progress`, `EncodeController.encode(progress:)`,
   `DVDPipeline(reportProgress:)` at the three encode sites,
   `JobContext.progress`, `JobPresentation.make` reads it. Tests. (~45 min)
3. **`FlowStep.derive`** + tests. (~30 min)
4. **`RipFlowController`** — move `selectedID`/`selectionDisc`/
   `reconcileSelection` out of `MetadataEntryView` verbatim; add
   `movieConfirmed`/`dismissedJobID`. `AppDelegate` owns it. Tests. (~45 min)
5. **Presentation helpers** — `ScanStatusLine`, `runtimeCaption` move,
   `progressSummary`/`formatETA`, `outcomeCard`. Tests. (~40 min)
6. **Views** — `RipFlowView` + five step views + `ScanStatusStrip` +
   `MovieCard`; move `MovieRow`; delete `MetadataEntryView.swift`; point
   `showMetadataEntry` at `RipFlowView`. Build. (~90 min)
7. `./run-remote-tests.sh gordon` once; fix; commit per step where sensible
   (memory: commit fixes immediately).

Steps 1–3 and 5 are independent of each other and of the views; 4 depends
on nothing but `SelectionReset`; 6 depends on all of them. A second agent
could take 1–2 while the first takes 3–5.

---

## 8. Cut to land today

- **Breadcrumb header** ("1 Disc › 2 Movie › 3 Confirm › 4 Rip"). A plain
  step title is enough; add later.
- **Search before a disc is in** — today "Open…" with no disc lets the user
  search ahead and `SelectionReset.bind` attaches the pick to the next
  insertion. The Insert-disc step doesn't offer search. `SelectionReset`
  keeps its `.bind` branch and tests (the controller still calls
  `reconcile`); it just becomes unreachable from the UI.
- **Poster on Ripping/Done.** `MovieMetadata` carries no `posterPath`
  (wire format), and the job is the truth on those steps. Confirm shows the
  poster (the view model still has the `TMDBMovie`); Ripping/Done show text.
- **ETA smoothing / stale-progress warning** ("no progress for N min").
  The 30-minute inactivity watchdog already ends a hung encode; a visible
  "last update 4 min ago" is a follow-up.
- **MakeMKV progress** during `.fallback` — indeterminate bar. `PRGV:` lines
  are not parsed.
- **Retiring `JobState.progress`** and `logDisplayRows`/`logLines` —
  both stay; nothing renders them in the rip window any more.
- **`DVDPipelineProgressReportingTests`** if the fake-executable fixture
  takes longer than 20 minutes to set up.

## 9. Decisions the user may disagree with

1. **Continue button rather than auto-advancing on a click.** A single
   misclick on a 40-row TMDB list shouldn't jump the screen; Return and
   double-click also advance, so the common case is still "type, Return,
   Return". Auto-advance is a one-line change (`select` sets
   `movieConfirmed = true`) if the extra click is unwanted.
2. **Scanning is not its own step.** The user listed it as one. The scan
   overlaps with searching, and blocking the search on a tens-of-seconds
   scan would make the loop slower than it is today; it appears as a strip
   on Choose movie and as the disc panel on Confirm instead. Making it a
   blocking step is a two-row change in the `derive` table if preferred.
3. **Done lingers until dismissed or a different disc arrives.** The
   alternative — snap back to Insert disc the moment the job ends — loses
   the failure card and Retry. "Next Disc" is one click, and swapping the
   disc dismisses it without one.
4. **No search without a disc** (see §8). The remote loop never needs it;
   the user might.
5. **The log is only in History.** The user asked for exactly this, but a
   failed job now takes one extra click to see the HandBrake tail. The
   `FailurePresenter` headline and details are on the Done card, so the
   common failures are readable without it.

---

## Review

Reviewed 2026-09-17 against `9ba44d5 ec057c9 9deba83 b261807 a005ad9 0cc61c6
894e1e4` (plus the fix below). **Verdict: ship it to joe.**

Verification re-run by the reviewer, not taken on trust: `./run-remote-tests.sh
gordon` — 952 tests in 76 suites passed, no continuation leaks, all seven new
suites named in the log (`FlowStepTests`, `HandBrakeProgressParserTests`,
`JobProgressTests`, `JobPresentationStepsTests`, `RipFlowControllerTests`,
`ScanStatusLineTests`, `DVDPipelineProgressReportingTests`). A local
`xcodebuild … build` succeeded; the only warning is the pre-existing
`Info.plist in Copy Bundle Resources` one, unchanged by this work.

### What was fixed

`ceb1597` — `FlowStep.derive`'s rows 2–5 had no test pinning their order,
and the #0005 automatic end-of-job eject makes that ordering load-bearing:
it runs *while* the outcome card is going up, so `isEjecting` is true for
the first seconds of every successful rip. Two tests added
(`theOutcomeCardOutranksAnEjectInFlight`,
`theOutcomeCardOutranksAPartialEjectUntilDismissed`), falsified on gordon by
swapping the two blocks in `derive`: both fail, none of the existing 18 do.

### What was checked and found intact

Every behaviour a real disc has already proved still has a place and still
works. #0053's Start reasons and #0027's audio gate are `ConfirmStepView`'s
action bar, `StartGate` untouched. #0026's confirmation row, #0025's Play All
refusal and the full title table, #0039's no-titles state, #0032's mismatch
verdict and "Rip anyway", #0031's extras picker, #0059's audio picker and its
preferred-language notice are `DiscTitleListView`/`TrackSelectionView`
unchanged, now the Confirm step's disc panel. #0051's Cancel scan and the
Rescan buttons are additionally surfaced on Choose movie via
`ScanStatusLine`. #0046's cancel keeps `CancelPolicy` and the `NSAlert`.
#0045/#0049's refusals are `.insertDisc(.ejecting)`/`(.discUnavailable)` plus
the Eject action on the outcome card. #0052's disc-removed job lands on Done
with `discRemovedDetail`. #0043's log is one click away on Ripping and Done.

The derivation's awkward states were walked: a job running while the disc is
ejecting stays `.ripping`; a disc pulled mid-encode and re-inserted keeps the
selection (`SelectionReset` returns `.keep` on a removal and on the same disc
coming back), so "Next Disc" lands on Confirm with the movie intact rather
than stranding; a cancel that loses the race to a finishing encode shows the
success card; a fast disc swap resets through `reconcile` whether or not the
two `insertedDisc` changes coalesce. The progress parser is pinned to the
captured HandBrake corpus — every line in the fixtures that `isProgressOnly`
accepts (>100) must parse, and `progressFraction` must agree with it on every
line. `0cc61c6` hides only the *pre-encode scan's* percentage, never the
encode's: the first `Encoding:` line replaces the `.scanning` report. #0140 is
met — every step puts its body in a `List`/`ScrollView` with no `minHeight`
and its action bar outside it, and Confirm is strictly shorter than the old
window (no search results, no log pane) with no new nested scroller.

### Known, accepted, not fixed

1. **#0052's card denies a Retry that `retryDecision` would allow.**
   `outcomeCard`'s `.cancelled where discRemovedDuringJob` branch hard-codes
   `[.showLog, .nextDisc]`. Its comment says `retryDecision` already refuses —
   true while the drive is empty, but not once the disc is back and rescanned.
   Not a stranding: "Next Disc" lands on Confirm with the movie, title, tracks
   and extras intact, so it costs one extra click, not a re-search.
2. **`DoneStepView` has no scroller.** Its content is bounded
   (`FailurePresenter.details` is at most a few lines), so it is the one step
   whose body could in principle contribute to the window's minimum height.
   Worth a `ScrollView` if a failure card ever looks cramped.
3. **HandBrake's own multi-title pre-encode scan shows an indeterminate
   spinner** labelled "Reading the disc", although `task n of m` is known.
   Honest, but on a USB 2.0 drive that spinner can sit for a while.
4. **Muxing reports fraction 1.0**, so the bar sits at "100 %" still labelled
   "Encoding the feature" while HandBrake muxes.

### Manually unverified

Everything visual. No UI tests were run or written (forbidden here), no disc,
drive or HandBrakeCLI was touched. The five step views, the window's real
minimum size, the progress bar's live behaviour and the ETA's plausibility
have only been exercised through their pure seams.

### What to check on joe first

1. **The Ripping step against a real encode.** Does the bar move and the ETA
   look plausible, or does it stay indeterminate? That is the one path whose
   inputs have only ever been captured text. Watch the handoff out of
   "Reading the disc" into "Encoding the feature".
2. **The Confirm step on the 7-audio/21-subtitle disc.** Start, and its #0053
   reason caption, must stay on screen at the 560×560 minimum, and a trackpad
   scroll over the audio checkboxes must move the outer scroller.
3. **A full loop end to end:** insert → search → Continue → Start → Done →
   "Next Disc" → insert the next disc, confirming the outcome card is
   superseded without a click when a *different* disc goes in.
4. Then, if there is time: pull a disc mid-encode (#0052) and confirm Done
   says "Disc removed"; and let a job fail to confirm "Show log…" opens
   History on that job.
