# The History window's log, and the "already in Plex" check

Two designs, written 2026-09-17 against `544d27d`, for one implementation
sitting. Both follow the rules the step flow established
(`docs/ux-step-flow.md` §5): `@Observable` never `ObservableObject`;
MainActor-by-default with `nonisolated` pure seams; every decision behind a
plain function covered by `ChangeoverTests` on gordon (UI tests are
forbidden, `docs/ui-test-crash-prevention.md`); views that only `switch`
and lay out; nothing that can push a control off-screen (#0140).

---

# Part 1 — The History window

## The problem, in the user's words

> The logs UI needs work.

The screenshot, taken mid-encode: a sidebar column too narrow to show
"Air (2023) / Encoding Air (202…"; a detail header where the title is clipped
and overlapped by the Cancel Job button and the "Encoding Air (2023) (4%)"
line is half behind it; and below that, HandBrakeCLI's stdout verbatim —
`libdvdread: Couldn't find device name.`, `libdvdnav: Can't read name block`,
23 lines of `x265 [info]: …` build settings, `[21:07:05] sync: expecting 2901
video frames` — with nothing separating a milestone from an error from
encoder chatter. Since #0061 moved the log out of the rip window, this is
the only place the log lives, so it has to answer "what happened to my rip?"
on its own.

## What is there today (read before designing)

- `JobLog` (#0043): per-job capped ring `lines`, an uncapped-in-practice
  `milestones` list, a coalesced `latestProgress`, `droppedCount`, and
  `displayLines` merging the three. Classification is a `Bool`
  (`isMilestone`) decided at append time from the pipeline's own prefixes
  (`──`, `▶`, `✓`, `✗`, `⚠`) plus the three-space continuation rule.
- `JobPresentation.make` (label/tone/progress/detail), `progressSummary`,
  `outcomeCard`, `retryDecision`, `historySelection`, `cancelConfirmation`.
- `JobHistoryView`: `NavigationSplitView`, a `List` of `JobHistoryRow`
  (dot + `baseName` + label), `JobDetailView` (a `VStack` header with the
  title, label, `(N%)`, detail lines and an `HStack` of Cancel/Retry), then
  `JobLogView` — a monospaced `LazyVStack` of every `displayLines` row,
  milestones in `.primary`, everything else `.secondary`, autoscroll while
  at the bottom.
- `AppDelegate.showHistory(selecting:)`: window 720×520, `minSize` 560×420,
  reused; `pendingHistorySelection` for a notification click.
- `HandBrakeFailureClassifier.signature(for:outputPath:)` already decides,
  line by line, whether a HandBrake line is an error signature — the tail
  buffer and `FailurePresenter`'s "HandBrake said: …" both run on it.

## Design in one paragraph

Every log line gets a **category** at append time (the same place
`isMilestone` is decided today), and the window renders **rows** built by a
pure function from `(lines, filter, expanded runs)`: under the default
**Important** filter the pipeline's own milestones, warnings, errors and
their detail lines are shown, and every run of encoder chatter collapses
into one clickable row ("x265 settings · 23 lines"); **Everything** shows
the raw text. The live progress line is a pinned footer, not a list row, so
the tail stays readable. The detail header becomes a fixed **summary card**
— outcome, timings, disc, title/tracks, where the file landed — with Cancel
and Retry moved into the window **toolbar**, where nothing can overlap
them. The sidebar gets a real minimum width and a two-line row built by a
pure function. The raw text stays one click away: **Copy Log** puts the
whole unfiltered log plus the summary on the pasteboard, which is what gets
pasted into a bug report.

## 1. Classification

```swift
/// Jobs/JobLog.swift — additive.
nonisolated enum LogCategory: String, Codable, Sendable, CaseIterable {
    // The pipeline's own lines (DVDPipeline / PlexOrganizer / JobController)
    case section      // "── Starting: …", "── Done. …"
    case step         // "▶ Job …", "▶ Deinterlace: …", "▶ Extra: title 7"
    case success      // "✓ Preflight passed", "✓ Moved to: …"
    case failure      // "✗ …"
    case warning      // "⚠︎ …" / "⚠️ …"
    case detail       // "   …" continuation under any of the five above
    // The tool's lines
    case toolError    // a HandBrakeFailureClassifier signature, "Encode failed (error N).",
                      // "libhb: work result = N" with N ≠ 0, "Signal N received"
    case encoder      // "x265 [info]:", "x265 [warning]:", "[hh:mm:ss] …", "libdvdnav:",
                      // "libdvdread:", "disc.c:NNN: error opening file BDMV/…" (the benign
                      // Blu-ray probe every DVD run prints)
    case plain        // anything else: the HandBrake banner, "Opening …", makemkvcon MSG lines,
                      // "HandBrake has exited."
    case progress     // isProgressOnly — lives in latestProgress, never in lines

    var isMilestone: Bool   // section/step/success/failure/warning/detail — exactly today's rule
    var isImportant: Bool   // isMilestone || toolError
}

nonisolated enum LogClassifier {
    /// Pure. `previousCategory` supplies the continuation rule.
    static func category(for text: String, previousCategory: LogCategory?) -> LogCategory
}
```

Rules, in order (first match wins), all prefix/whole-line checks on the
text — never a general parser of HandBrake's output:

1. `isProgressOnly` → `.progress` (unchanged; routed to `latestProgress`).
2. `JobLog.hasMilestonePrefix` → `.section` for `──`, `.step` for `▶`,
   `.success` for `✓`, `.failure` for `✗`, `.warning` for the `⚠` scalar.
3. Three-space prefix and `previousCategory.isMilestone` → `.detail`.
   (Same one bit of state `previousLineWasMilestone` is today; `.detail`
   after `.detail` is allowed, as today.)
4. `HandBrakeFailureClassifier.signature(for: text, outputPath: "") != nil`,
   or whole-line `Encode failed (error N).`, or `[hh:mm:ss] libhb: work
   result = N` with N ≠ 0, or contains `Signal \d+ received` → `.toolError`.
   The `outputPath: ""` caveat `FailurePresenter` already documents applies:
   `outputOpenFailed` cannot anchor on an empty path and is simply not
   matched here — it still lands in the tail and the presenter.
5. Prefix `x265 [`, `libdvdnav:`, `libdvdread:`, `disc.c:`, or the
   `[hh:mm:ss] ` timestamp → `.encoder`. (`libdvdnav`'s region and
   `Can't read name block` lines are on every successful run of a mounted
   disc; they are chatter, not warnings, and that is exactly what the
   screenshot got wrong.)
6. Otherwise `.plain`.

`LogLine` gains `let category: LogCategory`; `isMilestone` stays as a stored
field equal to `category.isMilestone` so every existing reader and test is
untouched. `LogLine`'s `Codable` gets a hand-written `init(from:)` that
`decodeIfPresent`s `category` and falls back to
`LogClassifier.category(for: text, previousCategory: nil)` — a Phase 4
payload from an older host still decodes. `JobLog.append` calls
`LogClassifier.category` instead of `classify(_:previousLineWasMilestone:)`;
`classify` and `hasMilestonePrefix` stay as thin wrappers so `JobLogTests`
compile unchanged.

## 2. Rows: filter and grouping

```swift
/// Jobs/LogRows.swift — pure.
nonisolated enum LogFilter: String, Codable, Sendable, CaseIterable {
    case important   // default
    case everything
}

nonisolated enum LogRow: Identifiable, Equatable, Sendable {
    case line(LogLine)
    /// A run of consecutive non-important lines hidden by the filter.
    case collapsed(Run)
    nonisolated struct Run: Equatable, Sendable {
        let firstID: Int      // identity of the run and the key in `expanded`
        let lastID: Int
        let count: Int
        let label: String     // "x265 settings" / "libdvdnav" / "HandBrake output" / "Output"
    }
    var id: Int  // line id, or -(firstID + 1) for a collapsed run — unique within one log
}

nonisolated enum LogRows {
    /// `lines` is `JobLog.displayLines` minus the progress line.
    /// `expanded` is the set of `Run.firstID`s the user has opened in place.
    static func build(lines: [LogLine], filter: LogFilter, expanded: Set<Int>) -> [LogRow]
    static func label(for run: ArraySlice<LogLine>) -> String
}
```

`build`:

- `.everything`: every line as `.line`, **except** that runs of `.encoder`
  lines of length ≥ 8 still collapse (with the run's `label`) unless
  expanded. The x265 preamble is 23 lines and `[hh:mm:ss] scan:` runs are
  hundreds; a raw view that is 90 % those is not "everything", it is
  nothing. Under 8 lines a run stays inline — there is nothing to gain.
- `.important`: `.line` for every `isImportant` line; every maximal run of
  non-important lines (`encoder`, `plain`, `toolError` excluded) of any
  length becomes one `.collapsed` row, expanded in place when its
  `firstID` is in `expanded`. Nothing is ever dropped from the view
  silently: the count on the collapsed row is exact.
- `.progress` never appears (it is not in `lines`); the view renders
  `latestProgress` as a footer.
- `label(for:)`: all lines start with `x265 [` → "x265 settings"; all with
  `libdvdnav:`/`libdvdread:` → "libdvdnav"; mixed → "HandBrake output";
  a run with no HandBrake shapes at all (makemkvcon `MSG:` lines) → "Output".

Expansion state (`Set<Int>`) is view `@State`, display-only, the same class
of state as `DiscTitleListView.showFullTable`. The filter is `@AppStorage`
-free `@State` defaulting to `.important` — cut persistence for today.

## 3. The summary card and the toolbar

```swift
/// Jobs/JobPresentationHistory.swift — pure, extension JobPresentation.
nonisolated struct HistoryDetail: Equatable, Sendable {
    let title: String                 // "Air (2023)"
    let statusText: String            // "Encoding · 31 % · ETA 45 min" / "Finished in 41m 12s" / "Failed" / "Cancelled" / "Disc removed"
    let tone: Tone
    let facts: [Fact]                 // label/value pairs, in display order
    let failureLines: [String]        // FailurePresenter headline + details, else []
    let progress: ProgressSummary?    // non-nil only while running
    let actions: [Action]
    nonisolated struct Fact: Equatable, Sendable { let label: String; let value: String }
    nonisolated enum Action: Equatable, Sendable {
        case cancel(enabled: Bool, reason: String?)   // running only
        case retry(enabled: Bool, reason: String?)    // failed/cancelled only
        case revealInFinder(URL)                       // succeeded only
        case copyLog                                   // always
    }
}

extension JobPresentation {
    /// - `request`/`disc`/`discRemovedDuringJob` are read off `Job` by the view
    ///   (host-only, not on `JobSnapshot`, same as `make`'s parameters).
    /// - `fileFacts` is the optional size/modified probe (Part 2's `LibraryProbe`),
    ///   nil until it lands or if it never does.
    nonisolated static func historyDetail(
        for snapshot: JobSnapshot, request: RipRequest?, discVolumeName: String,
        isCancelling: Bool, discRemovedDuringJob: Bool,
        retryDecision: RetryDecision, fileFacts: LibraryFile?, now: Date
    ) -> HistoryDetail
}
```

Facts, in order, omitting any whose value is unknown:

| Label | Value | Source |
|---|---|---|
| Started | `14:02` (today) / `Sep 16, 14:02` | `snapshot.startDate` |
| Finished | same format | `snapshot.endDate` |
| Elapsed | `41m 12s` | `formatElapsed` (live while running, from `now`) |
| Disc | `AIR_2023` | `Job.disc.lastPathComponent` |
| Title | `Title 1 · audio 1, 3 · 2 extras` | `Job.request` |
| Job | `2026-09-17T14-02-11-…` | `snapshot.id.rawValue` (what the working folder and reliability log are named after) |
| Filed as | `/Volumes/Media/Media/Movies/Air (2023) {tmdb-…}/Air (2023).mp4` | `outcome.destination` |
| Size | `1.42 GB` | `fileFacts.sizeBytes` (probe, optional) |

`statusText` for a running job is `progressSummary`'s `unitLabel` +
percent + ETA joined with ` · `; for a finished one it is `make(for:)`'s
label ("Finished in …", "Failed", "Cancelled", "Disc removed"). The
`(N%)` text that overlapped the button today is gone into this one line.

Actions: `cancel` carries `CancelPolicy.decide`'s refusal as `reason`
(tooltip), disabled while `isCancelling`, label "Cancelling…" then; `retry`
carries `retryDecision.refusalReason`. Both are rendered in the
**`NavigationSplitView` detail toolbar** (`ToolbarItemGroup(placement:
.primaryAction)`), never in the content `VStack` — toolbar items are laid
out by AppKit outside the content, so the title can never be clipped by
them and they can never be pushed off-screen. `revealInFinder` and
`copyLog` sit on the log pane's own bar (§4).

## 4. The sidebar row

```swift
nonisolated struct SidebarRow: Equatable, Sendable {
    let title: String      // "Air (2023)"
    let subtitle: String   // "Encoding · 31 %" / "Finished in 41m · 14:02" / "Failed · 14:02" / "Cancelling…"
    let tone: Tone
}
extension JobPresentation {
    nonisolated static func sidebarRow(for snapshot: JobSnapshot, isCancelling: Bool, discRemovedDuringJob: Bool) -> SidebarRow
}
```

The list column gets `.navigationSplitViewColumnWidth(min: 200, ideal: 240,
max: 320)`; the window's `minSize` becomes 720×460 (today 560×420 — the
sidebar's share of 560 is what produced "Encoding Air (202…"). The window
default stays 720×520; ideal becomes 860×560.

## 5. Copy and the raw text

```swift
extension JobLog {
    /// Every retained line in id order — `lines` (the ring) with evicted
    /// milestones spliced ahead of it, i.e. `displayLines` minus the
    /// progress line — never filtered, plus a "… N earlier lines dropped"
    /// first line when `droppedCount > 0`.
    func exportText() -> String
}
extension JobPresentation {
    /// The summary card as text ("Air (2023)\nStatus: Failed\nStarted: …")
    /// followed by a blank line and `logText`. Pure.
    nonisolated static func bugReportText(detail: HistoryDetail, logText: String) -> String
}
```

**Copy Log** writes `bugReportText` to `NSPasteboard.general`. That is the
one raw-text affordance today; "Save Log…" (`NSSavePanel`) is cut (§9).
"Reveal in Finder" on a succeeded job selects the filed `.mp4`.

## 6. Wireframes

Running job, default filter:

```
┌─ History ──────────────────────────────────────────────────────────────────────┐
│ [Clear History]                                        [Cancel Job]  toolbar   │
├────────────────────┬───────────────────────────────────────────────────────────┤
│ ● Air (2023)       │ Air (2023)                                                │
│   Encoding · 31 %  │ ● Encoding the feature · 31 % · ETA 45 min                │
│ ● Fargo (1996)     │ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░                 │
│   Finished in 41m  │ Started 14:02   Elapsed 12m 08s   Disc AIR_2023           │
│   · 13:20          │ Title 1 · audio 1, 3   Job 2026-09-17T14-02-11-8F3A       │
│ ● Heat (1995)      ├───────────────────────────────────────────────────────────┤
│   Failed · 11:41   │ Log  (● Important ○ Everything)         [Copy Log]        │
│                    ├───────────────────────────────────────────────────────────┤
│                    │ ── Starting: Air (2023) {tmdb-964960}                     │
│                    │ ▶ Job 2026-09-17T14-02-11-8F3A                            │
│                    │ ✓ Preflight passed                                        │
│                    │ ▶ Deinterlace: filter=none                                │
│                    │ ▸ HandBrake output · 412 lines                            │
│                    │ ▶ HandBrake selected title 1                              │
│                    │ ▸ x265 settings · 23 lines                                │
│                    │ ▸ HandBrake output · 9 lines                              │
│                    │                                                           │
│                    ├───────────────────────────────────────────────────────────┤
│                    │ Encoding: task 1 of 1, 31.02 % (58.11 fps, avg 56.07 fps, │
│                    │ ETA 00h45m29s)                                  pinned    │
└────────────────────┴───────────────────────────────────────────────────────────┘
```

Failed job, a collapsed run expanded:

```
│ ● Heat (1995)      │ Heat (1995)                                    [Retry]    │  toolbar
│   Failed · 11:41   │ ● Failed                                                  │
│                    │ HandBrake couldn't read this disc.                        │  failureLines
│                    │ Clean the disc and try again.                             │
│                    │ HandBrake said: “libdvdread: Error cracking CSS key …”    │
│                    │ Started 11:03   Finished 11:41   Elapsed 38m 02s          │
│                    │ Disc HEAT_D1   Title 3 · audio 1                          │
│                    ├───────────────────────────────────────────────────────────┤
│                    │ Log  (● Important ○ Everything)         [Copy Log]        │
│                    ├───────────────────────────────────────────────────────────┤
│                    │ ▶ Deinterlace: filter=none                                │
│                    │ ▾ HandBrake output · 88 lines                             │
│                    │   [11:03:41] scan: DVD has 12 title(s)                    │   .encoder rows,
│                    │   [11:03:41] scan: scanning title 1                       │   secondary colour
│                    │   …                                                       │
│                    │ ✗ libdvdread: Error cracking CSS key for /VIDEO_TS/…      │   .toolError, red
│                    │ ✗ HandBrakeCLI exited with status 3                       │
│                    │ ✗ HandBrake couldn't read this disc.                      │
│                    │    Clean the disc and try again.                          │   .detail
│                    │ ⚠︎ Could not remove /…/Working/encoding/2026-…: …          │   .warning, orange
```

Succeeded job: status "Finished in 41m 12s", facts include "Filed as …" and
"Size 1.42 GB", toolbar empty, log bar gains **Reveal in Finder**.

Row styling, all from `LogCategory`: `section` bold; `step`/`success`
primary; `failure`/`toolError` red; `warning` orange; `detail` primary,
indented; `encoder`/`plain` secondary monospaced `caption2` (today's look).
Collapsed rows: a disclosure chevron, `label · N lines`, secondary.

## 7. Types: reused, changed, retired

| | |
|---|---|
| **Reused unchanged** | `JobLog` storage/eviction/`displayLines`/`droppedCount`; `JobPresentation.make`, `progressSummary`, `retryDecision`, `historySelection`, `cancelConfirmation`; `CancelPolicy`; `FailurePresenter`; `HandBrakeFailureClassifier.signature`; `AppDelegate.showHistory`/`requestCancel`; `JobController.retry`/`cancel`/`clearHistory`; `JobHistoryView`'s selection plumbing and `.id(job.id)` |
| **Changed (additive)** | `LogLine.category` + custom decoder; `JobLog.append` classifies via `LogClassifier`; `JobLog.exportText()`; window `minSize` |
| **New pure** | `LogCategory`, `LogClassifier`, `LogFilter`, `LogRow`, `LogRows`, `JobPresentation.historyDetail`/`sidebarRow`/`bugReportText`, `HistoryDetail`, `SidebarRow` |
| **New views (thin)** | `JobSummaryCard` (renders `HistoryDetail`), `LogPane` (filter picker + Copy/Reveal bar + rows + pinned progress footer) |
| **Rewritten** | `JobLogView` → `LogPane` (same file, same autoscroll sentinel); `JobDetailView` → card + toolbar + `LogPane`; `JobHistoryRow` renders `SidebarRow` |
| **Retired** | the `(N%)` text and the in-content Cancel/Retry `HStack`; the `isMilestone ? .primary : .secondary` two-tone rule |
| **Untouched** | `LogDisplayRow`, `JobController.logDisplayRows`/`logLines` (tests read them; nothing renders them) |

## 8. Test plan (pure parts, `ChangeoverTests`, one run on gordon)

`LogClassifierTests`
- One case per category using real fixture lines from
  `ChangeoverTests/Fixtures/handbrake/*.log`: `x265 [info]: HEVC encoder
  version …` → `.encoder`; `libdvdnav: Can't read name block …` →
  `.encoder`; `disc.c:437: error opening file BDMV/index.bdmv` → `.encoder`
  (benign, contains "error", must not be `.toolError`); `[21:07:05] sync:
  expecting 2901 video frames` → `.encoder`; `Encode failed (error 4).` →
  `.toolError`; `[21:07:37] libhb: work result = 4` → `.toolError` and
  `… work result = 0` → `.encoder`; the disk-full `ERROR: avformatMux …`
  line → `.toolError`; `HandBrake has exited.` → `.plain`; every pipeline
  prefix → its milestone case; `"   detail"` after `.failure` → `.detail`,
  after `.encoder` → `.plain`; a glued progress+error fragment → not
  `.progress` (it already is not; pin that it lands `.toolError`).
- Every line of `failure-disk-full-hb1.11.2-exit4.log`: `category ==
  .progress ⇔ isProgressOnly`, and `category.isMilestone == classify(…)` —
  the old and new rules agree on the whole corpus.

`JobLogTests` additions
- `append` stores `category`; `isMilestone == category.isMilestone`;
  a `LogLine` JSON without `category` decodes with the classifier's answer;
  `exportText()` is every line in id order with the dropped-count header
  and no progress line.

`LogRowsTests`
- `.important` on a 40-line synthetic log (section, step, 23 `x265 [info]`,
  9 `[hh:mm:ss] scan:`, toolError, failure, detail): rows are
  `[line, line, collapsed("x265 settings", 23), collapsed("HandBrake output", 9), line, line, line]`.
- Expanding `firstID` of the x265 run puts its 23 lines inline, others stay
  collapsed; counts are exact; `id`s are unique across lines and runs.
- `.everything`: runs < 8 stay inline; runs ≥ 8 collapse; `.plain` never
  collapses under `.everything`.
- A `.detail` line always follows its milestone in the same filter.
- `label(for:)` for the three shapes.

`JobPresentationHistoryTests`
- `historyDetail`: running → `progress != nil`, `actions` has `.cancel`
  with `CancelPolicy`'s reason during `.organizing`, no `.retry`; failed →
  `failureLines == FailurePresenter` headline + details, `.retry(enabled:
  false, reason:)` mirrors `retryDecision`; succeeded → "Filed as" fact,
  `.revealInFinder(destination)`, no cancel/retry; `Size` only with
  `fileFacts`; `.copyLog` always present and last; disc removed → "Disc
  removed".
- `sidebarRow` for each phase; `isCancelling` → "Cancelling…".
- `bugReportText` starts with the title and status, contains every fact,
  then the log text.

## 9. Cut to land today

- **Search box** over the log. `Copy Log` + the user's editor covers it.
- **Persisting the filter** across launches. `@State`, defaults to Important.
- **Save Log…** file export. Copy is the bug-report path.
- **Per-category filter checkboxes** (warnings-only, errors-only). Two
  states; the collapsed rows keep everything reachable.
- **Timestamps per row.** `LogLine.timestamp` exists; a hover tooltip is a
  follow-up.
- **Size/duration facts for a job whose destination is unreachable** —
  the probe fails soft to no fact, no spinner.

---

# Part 2 — Warn when the movie is already in Plex

## The problem, in the user's words

> We should run a check once the movie or TV show has been selected to make
> sure it has not already been imported into Plex. We may find we insert a
> DVD and not know it is already in Plex.

And the decision, given while this was being written:

> We should warn of a duplicate and require confirmation before ripping. We
> may still want to recreate a ripped output but we don't want to find out
> after waiting for the disc to be ripped.

The risk behind it: `PlexOrganizer.move` replaces an existing library file
on purpose (#0012's staged `replaceItemAt`), so a re-rip of a film that is
already there silently overwrites it after a 40-minute encode. The user
re-encoded three films today deliberately, so a re-rip is a workflow, not
an error — the design has to make the duplicate impossible to miss, block
Start until the replacement is confirmed, and make that confirmation one
clear click rather than a dead end.

## Mechanism

Plex naming here is strict and the `{tmdb-ID}` tag is unique per film
(`MovieMetadata.folderName`, `LibraryPaths.resolve`), so "is this film in
the library?" is a **tag match over one directory listing of `Movies/`**.
Matching on the tag rather than the whole folder name also catches a copy
filed under a different title (TMDB renamed it, or an older tool named it).

```swift
/// LibraryProbe.swift — nonisolated, the one place that touches the filesystem.
nonisolated enum LibraryProbe {
    /// One `contentsOfDirectory` of `moviesPath` (names only), then one of
    /// each matching folder with `.fileSizeKey`/`.contentModificationDateKey`.
    /// Never walks deeper. `@concurrent` for the reason `PlexOrganizer.move`
    /// is: an SMB listing is blocking work with no `await` of its own.
    @concurrent
    static func lookup(moviesPath: String, tmdbID: String, timeout: Duration = .seconds(5)) async -> LibraryLookup
    /// Part 1's optional "Size" fact: size + modified date of one file.
    @concurrent
    static func fileFacts(at path: String) async -> LibraryFile?
}

nonisolated enum LibraryLookup: Equatable, Sendable, Codable {
    case absent
    case present([LibraryEntry])            // ≥ 1 entry, each with ≥ 1 video file
    case unreachable(reason: String)        // root missing/unmounted, listing threw, or timed out
}
nonisolated struct LibraryEntry: Equatable, Sendable, Codable {
    let folderName: String                  // as on disk
    let folderPath: String
    let files: [LibraryFile]                // video files only, name-sorted
}
nonisolated struct LibraryFile: Equatable, Sendable, Codable {
    let name: String
    let sizeBytes: Int64?
    let modified: Date?
    let durationSeconds: Int?               // nil today — see §"Cut"
}

/// LibraryMatch.swift — pure, no filesystem.
nonisolated enum LibraryMatch {
    /// Folder names carrying exactly `{tmdb-<id>}` (not a prefix: `{tmdb-78}`
    /// never matches `{tmdb-780}`), case-sensitive on the tag, in listing order.
    static func folders(in names: [String], tmdbID: String) -> [String]
    static func isVideoFile(_ name: String) -> Bool   // mp4, m4v, mkv, avi, mov, ts — Plex's set, not ours
    /// `.present` only when at least one matched folder holds a video file;
    /// an empty or junk-only folder is `.absent` (nothing would be overwritten).
    static func lookup(folders: [(name: String, path: String, files: [LibraryFile])]) -> LibraryLookup
}
```

`lookup` races the listing against `timeout` with a `TaskGroup`; a timeout
is `.unreachable(reason: "The Plex library did not answer in 5 s.")` — a
dead SMB mount must never hold the Confirm step hostage. A missing
`moviesPath` (drive not mounted) is `.unreachable`, **never** `.absent`:
"not there" is only ever said after a successful listing.

Cost: two directory reads over the network, a few KB each. No hashing, no
reading of media, no deep walk. `Preflight` already lists the same root
at job start, so this is not a new class of access.

## Where it runs and what it feeds

```swift
/// RipFlowController — additive.
nonisolated enum LibraryCheck: Equatable, Sendable {
    case idle
    case checking(tmdbID: String)
    case done(tmdbID: String, LibraryLookup)
}
private(set) var libraryCheck: LibraryCheck = .idle
/// #0032's `MismatchAcknowledgement` pattern, not a second one: a plain
/// key struct, compared whole by `StartGate`, cleared by every event that
/// changes what it was given for. Keyed on the movie (`movieID`) and the
/// on-disk folder it was shown (`folderPath`); "per disc" comes from where
/// it lives — `RipFlowController`'s selection state, which `reconcile
/// (.reset)` wipes on a disc swap exactly as it wipes `selectionDisc`.
nonisolated struct ReplaceAcknowledgement: Equatable, Sendable {
    let movieID: Int
    let folderPath: String
}
private(set) var replaceAcknowledgement: ReplaceAcknowledgement?

/// Called from `ConfirmStepView.task(id: flow.libraryCheckKey(settings:))`
/// — the view's only involvement — and by the notice's "Check again" link.
/// `libraryCheckKey` is a `Hashable` pair (movieID, moviesPath), so the task
/// re-fires only when either changes. Generation-guarded like `startScan`,
/// so a result for a movie no longer selected is discarded.
nonisolated struct LibraryCheckKey: Hashable, Sendable { let movieID: Int; let moviesPath: String }
func libraryCheckKey(settings: AppSettings) -> LibraryCheckKey?
func checkLibrary(settings: AppSettings, probe: LibraryProbeRunner = LibraryProbe.lookup) async
func acknowledgeReplace()      // "Replace the Existing File" — records movieID + folderPath from `.done`
```

**Early, by construction.** The check starts the moment the Confirm step
appears for a movie — `continueToConfirm`, `adjustAndRetry`, or a new
movie after "Change movie" all change the `.task(id:)` key — so the answer
is on screen seconds after the film is chosen, tens of minutes before an
encode would have found out. It is never deferred to Start.

`select(movieID:)` with a different id, `queryChanged`, `reconcile(.reset)`
and `changeMovie` all clear `replaceAcknowledgement` and reset
`libraryCheck` to `.idle` — an acknowledgement given for one film can never
carry to another (the #0026 lesson, keyed the same way).

`StartGate.decide` gains two parameters and two `StartDecision` cases,
checked **last** — only after every existing check passes, so the caption
names the first thing to do and a duplicate is never reported before the
disc is even scanned:

```swift
case libraryCheckInProgress   // "Checking the Plex library for this movie."
case duplicateUnacknowledged  // "This movie is already in Plex — choose Replace the Existing File to rip it again."
// decide(..., libraryCheck: LibraryCheck, replaceAcknowledgement: ReplaceAcknowledgement?)
```

- `.checking` → `.libraryCheckInProgress` (the `.runtimeLookupLoading`
  precedent; bounded by the 5 s timeout).
- `.done(_, .present)` without a matching acknowledgement →
  `.duplicateUnacknowledged`.
- `.done(_, .present)` with `replaceAcknowledgement == ReplaceAcknowledgement
  (movieID: <selected>, folderPath: <first entry's path>)` → `.ready`.
- `.done(_, .absent)`, `.done(_, .unreachable)`, `.idle` → `.ready`.
  **Unreachable is fail-soft but never silent:** Start is not blocked by
  an unknown, and the notice stays on the Confirm step in neutral tone —
  "Couldn't check the Plex library: <reason>. If this movie is already
  there, it will be replaced." — with a **Check again** link that re-runs
  the probe. The uncertainty is on screen next to the movie until the user
  starts or the library answers.
- Defaults `libraryCheck: .idle, replaceAcknowledgement: nil` keep every
  existing `StartGate` call site and test compiling.

`JobController.start` is **not** changed. `StartGate` is the button's gate;
the point-of-harm guard for "did the user mean to replace?" would be a
second listing at start time, and #0012's staged replace already guarantees
the existing copy survives anything short of a successful, duration-checked
encode. The one failsafe worth adding is a single log line in
`DVDPipeline.run()` right before `PlexOrganizer.move`: `⚠︎ Replacing the
existing copy at <path>` when the destination exists — so a replacement is
never invisible in the log (Part 1 shows it as a warning).

## Blocking: one click, and why that shape

**Start is disabled until the user clicks "Replace the Existing File"** (the
user's decision). Not a modal, not a second confirmation on Start, and zero
extra clicks when the film is not already there.

The alternative — a banner with Start left enabled — also fails on the keyboard:
Start is the step's `.keyboardShortcut(.defaultAction)`, and the step flow
was designed for "type, Return, Return". A user who does not look at the
window between the second and third Return replaces a library copy after a
40-minute encode. A banner cannot stop a reflex; a disabled button can.
The deliberate re-rip costs one click on a button whose label says exactly
what will happen, which is also what the user re-encoding three films for
size would want to see confirmed. This mirrors #0032's runtime mismatch:
a stop-and-ask, keyed to the movie, with the reason beside Start.

## The Confirm step, with the notice

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Confirm the rip                                          │
├──────────────────────────────────────────────────────────┤
│ ┌──┐ Air (2023)                              Change movie│
│ │▒▒│ Movies/Air (2023) {tmdb-964960}/Air (2023).mp4      │
│ └──┘ TMDB runtime 1h 52m                                 │
│ ┌────────────────────────────────────────────────────────┐
│ │ ⚠︎ Already in Plex                                      │
│ │ Air (2023).mp4 · 1.42 GB · added Sep 3, 2026           │
│ │ /Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}/  │
│ │ Ripping again replaces this file once the new encode   │
│ │ succeeds.               [Reveal]  [Replace the Existing File]
│ └────────────────────────────────────────────────────────┘
│ Main feature — Title 1 · 1:52:04 · 18 chapters · 6.9 GB  │
│ …                                                        │
├──────────────────────────────────────────────────────────┤
│ This movie is already in Plex — choose Replace the       │
│ Existing File to rip it again.           [Start Ripping] │  disabled
└──────────────────────────────────────────────────────────┘

after the click:
│ │ ✓ Will replace Air (2023).mp4 · 1.42 GB · added Sep 3  │
│                                          [Start Ripping] │  enabled

filed under a different name:
│ │ ⚠︎ Already in Plex, as “Air: Courting a Legend (2023) {tmdb-964960}” │
│ │ Air - Courting a Legend (2023).mp4 · 1.40 GB · added …                │
│ │ The new file will be filed as Air (2023) {tmdb-964960}; the old       │
│ │ folder is left in place.                                              │

two matches (should not happen; say so):
│ │ ⚠︎ Already in Plex — 2 folders carry {tmdb-964960}                     │
│ │ … one line per folder …                                               │

unreachable (stays until the library answers or the user starts):
│ │ ◌ Couldn't check the Plex library: /Volumes/Media/Media/Movies isn't   │
│ │ available. If this movie is already there, it will be replaced.        │
│ │                                                          Check again   │
│                                          [Start Ripping] │  enabled

checking (≤ 5 s):  │ ◌ Checking the Plex library…                          [Start Ripping]  disabled
```

The notice is one `DuplicateNoticeView` rendering a pure
`DuplicatePresentation.notice(...)`:

```swift
nonisolated struct DuplicateNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case checking, present, acknowledged, unreachable }
    let kind: Kind
    let headline: String
    let lines: [String]              // per file: "name · size · added date"; the path; the consequence sentence
    let tone: JobPresentation.Tone   // warning / success / neutral
    let offersReplace: Bool          // present && !acknowledged
    let offersRecheck: Bool          // unreachable
    let revealPath: String?          // the first matched folder
}
nonisolated enum DuplicatePresentation {
    /// nil for `.idle` and for `.done(_, .absent)` — no notice at all when there is nothing to say.
    static func notice(check: LibraryCheck, acknowledgement: ReplaceAcknowledgement?, metadata: MovieMetadata, now: Date) -> DuplicateNotice?
}
```

The "different name" line is decided by `entry.folderName != metadata.folderName`.
Sizes via `ByteCountFormatter` `.file`; dates via a fixed
`yMMMd` format so tests can pin them.

Since the notice sits inside the Confirm step's single `ScrollView`, it can
never push Start out of the window (#0140): the action bar is outside the
scroller, as today.

## TV, honestly

`LibraryRoots.tvPath` exists (`<root>/TV Shows`) but Changeover has no TV
support: no TMDB TV search, no show/season/episode metadata type, and
#0025's disc classifier refuses Play-All discs rather than ripping episodes
(Roadmap: "TV show support — real work, no current demand"). So today
**nothing about a TV disc can be checked**, and this design does not
pretend otherwise.

What carries over when TV arrives: Plex's TV convention is
`TV Shows/Show (Year) {tmdb-ID}/Season NN/Show - sNNeNN.mp4`, so the
show-folder question ("is this show in the library at all?") is
`LibraryMatch.folders(in: <listing of tvPath>, tmdbID:)` unchanged. The
question that actually matters for a disc — "are *these episodes* already
there?" — needs episode numbers Changeover cannot derive from a DVD today,
and is not designed here.

## Types: reused, new, retired

| | |
|---|---|
| **Reused unchanged** | `MovieMetadata.folderName`/`tmdbID`; `LibraryRoots`/`LibraryPaths`; `AppSettings.plexMoviesPath`; `StartGate`'s ordering and every existing case; `MismatchAcknowledgement`'s shape; `ConfirmStepView`'s action bar; `PlexOrganizer` (its replace stays) |
| **New pure** | `LibraryMatch`, `LibraryLookup`/`LibraryEntry`/`LibraryFile`, `LibraryCheck`, `ReplaceAcknowledgement`, `DuplicatePresentation`/`DuplicateNotice`, two `StartDecision` cases |
| **New nonisolated I/O** | `LibraryProbe.lookup`/`fileFacts` (`@concurrent`, timeout) |
| **Changed** | `RipFlowController` (+ `libraryCheck`, `replaceAcknowledgement`, `checkLibrary`, `acknowledgeReplace`; clears in `select`/`queryChanged`/`changeMovie`/`reconcile`); `StartGate.decide` (+2 defaulted parameters); `DVDPipeline.run` (+1 warning line before the move) |
| **New view (thin)** | `DuplicateNoticeView` inside `ConfirmStepView.movieCard`'s column; `.task(id:)` on the step |
| **Retired** | nothing |

`LibraryProbeRunner` is a `typealias (String, String) async -> LibraryLookup`
injected into `checkLibrary` — the `ScanRunner` pattern — so
`RipFlowControllerTests` never list a real directory.

## Test plan

`LibraryMatchTests`
- exact folder → match; different title, same tag → match; `{tmdb-78}` vs
  `{tmdb-780}` and `{tmdb-178}` → no match; tag in the middle of a name
  (junk suffix) → match; no tag → no match; two folders → both, in order.
- `isVideoFile`: the extension set, case-insensitive; `.jpg`, `.nfo`,
  `.DS_Store`, `.srt` → false.
- `lookup(folders:)`: a matched folder with only `.jpg` → `.absent`; one
  video → `.present` with one entry; files name-sorted.

`LibraryProbeTests` (temp directory, no network, the `WorkingFilesTests` style)
- `Movies/Foo (2001) {tmdb-5}/Foo (2001).mp4` (a few bytes) → `.present`,
  `sizeBytes` correct, `modified` non-nil; missing `Movies` → `.unreachable`;
  `Movies` present and empty → `.absent`; a file (not a directory) at
  `moviesPath` → `.unreachable`; runs off the main actor (the
  `moveNeverRunsOnTheMainActor` pattern).

`DuplicatePresentationTests`
- `.idle`/`.absent` → nil; `.checking` → the checking notice, no replace
  button; `.present` with the expected folder name → headline "Already in
  Plex", one file line with size and date, `offersReplace`; a different
  folder name → the "as “…”" headline and the "filed as / left in place"
  sentence; two entries → the count headline; acknowledged → `.acknowledged`,
  success tone, no button; `.unreachable` → neutral tone, reason in the
  text, the "will be replaced" sentence, `offersRecheck`, no replace button.

`StartGateTests` additions
- Everything ready + `.checking` → `.libraryCheckInProgress`; + `.present`
  unacknowledged → `.duplicateUnacknowledged`; acknowledged for the same
  movieID and folderPath → `.ready`; acknowledged for another movieID, or
  the same movie but another folderPath → still refused; `.unreachable` →
  `.ready`; a duplicate **and** no title selected → `.noTitleSelected` (the
  duplicate is checked last); every `StartDecision` case has a non-nil
  `reason` except `.ready` (extend the existing #0053 completeness test);
  defaults → every existing test unchanged.

`RipFlowControllerTests` additions (fake probe)
- `checkLibrary` stores `.done` for the selected tmdbID; a result arriving
  after `select` moved to another movie is discarded; `acknowledgeReplace`
  then `select(differentMovie)` clears it; `changeMovie` → `continueToConfirm`
  on the same movie keeps `.done` (no re-list) — or re-runs; pick one and
  pin it (re-run is simpler: the key changes only when the view's task id
  does, and `changeMovie` doesn't change tmdbID, so **keeps**); `reconcile
  (.reset)` clears both; `queryChanged` clears both.

`DVDPipeline` (existing `ExtrasPipelineTests`/`EncodeControllerTests` fixtures)
- with a file already at the destination, the log contains
  `⚠︎ Replacing the existing copy at …` before `✓ Moved to:`; without one, it
  does not.

## Cut to land today

- **Duration of the existing file.** `OutputDurationCheck.measureSeconds`
  (`AVURLAsset`) would work over SMB, but HandBrake writes the `moov` atom
  at the end of the file, so it is a seek to the tail of a 1–2 GB file on a
  USB-2-class network path for a number the size already implies.
  `LibraryFile.durationSeconds` stays `nil`; the field exists so adding it
  is not a wire change.
- **Checking `Clips/` for extras** — an extra's re-encode overwrites a clip
  nobody curates; not worth a listing.
- **A start-time re-check** in `JobController.start` (see above).
- **Persisting acknowledgements** — per selection only, on purpose.

---

# Implementation order (one sitting, two agents possible)

1. `LogCategory` + `LogClassifier` + `LogLine.category` + tests (~40 min).
   Independent of everything else.
2. `LogRows` + tests (~30 min). Depends on 1.
3. `JobPresentation.historyDetail`/`sidebarRow`/`bugReportText` +
   `JobLog.exportText` + tests (~40 min). Depends on 1 only for the type.
4. `LibraryMatch` + `LibraryLookup` types + tests (~30 min). Independent.
5. `LibraryProbe` + temp-dir tests (~30 min). Depends on 4.
6. `StartGate` cases + `DuplicatePresentation` + tests (~40 min). Depends on 4.
7. `RipFlowController.checkLibrary`/acknowledgement + tests (~30 min).
   Depends on 4–6.
8. `DVDPipeline` replace-warning line + test (~15 min). Independent.
9. Views: `JobHistoryView` (toolbar, card, sidebar widths, window
   `minSize`), `LogPane`, `DuplicateNoticeView`, `ConfirmStepView.task(id:)`
   (~90 min). Depends on all of the above. Build locally.
10. `./run-remote-tests.sh gordon` once; fix; commit per step.

Agent A takes 1–3 then the History views; agent B takes 4–8 then the
Confirm view. Neither touches joe, a disc or a drive.

# Decisions the user may disagree with

1. **A duplicate check that cannot reach the library does not block.**
   The alternative (block until the library answers) turns an unmounted
   NAS into a rip that cannot start, for a check that #0012 already makes
   non-destructive-until-success. The notice and "Check again" keep the
   uncertainty visible instead. (The blocking-on-a-found-duplicate half is
   the user's own decision and is not up for debate here.)
2. **The confirmation does not survive "Change movie" → the same movie.**
   `changeMovie` keeps `selectedMovieID`, so `libraryCheck` is kept, but
   any re-selection clears the acknowledgement — one extra click on a
   round trip through the results list, in exchange for never carrying it
   across a re-pick that only looked like the same film.
3. **`.everything` still folds encoder runs of eight or more lines.** If
   "everything" must mean the raw scroll, drop the threshold to `Int.max`
   for that filter; `Copy Log` is always raw regardless.
4. **The History window's minimum width grows from 560 to 720.** The
   sidebar cannot show a title and a status on two lines at less than
   ~200 points, and the summary card wants ~480.
5. **`libdvdnav`/`libdvdread` lines are chatter, not warnings**, because
   they print on every successful run. A real CSS failure still surfaces
   as `.toolError` through the classifier's signature, and as the failure
   card's "HandBrake said: …".
