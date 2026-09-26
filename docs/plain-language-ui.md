# Plain language by default, precision on request

A design for the *words* inside the five-step rip window, the menu bar
popover and the Settings window — not for the steps themselves. Written
2026-09-21 against `cab5b7d`. The step flow (`docs/ux-step-flow.md`), the
per-step window heights (`WindowSizing`, `RipWindowSizer`,
`docs/window-sizing.md`) and the header buttons (`WindowChrome`,
`docs/window-chrome.md`) are recent, deliberate and liked; nothing here moves
them. This is about what the steps *say*, and how much of it.

Plan only. No Swift was written for this document. The rules the earlier
designs set apply unchanged: `@Observable` only, never `ObservableObject`;
MainActor-by-default with `nonisolated` pure seams; views that only switch
and lay out; every sentence decided by a plain function pinned in
`ChangeoverTests`, because **UI tests are forbidden in this project and are
never run on a physical Mac** (`docs/ui-test-crash-prevention.md`). No step
below asks anyone to run `ChangeoverUITests`.

---

## The problem, in the user's words

> There is a lot of text which degrades the UX. This is meant for
> non-technical users. We can still have an option to expand to see details,
> but the default should be super basic.

The person this app is for puts a disc in, picks the movie, presses a button.
They do not know what a "title", a "PGC", an "RF value", a "remux" or a
"main feature heuristic" is, and they should never have to find out to get
their DVD into Plex.

What they can meet today, on one Confirm step, on one real disc
(Oppenheimer, 2026-09-19):

```
Main feature — Title 1 · 2:59:52 · 21 chapters · 7.6 GB
HandBrake did not name a main feature — chosen because it is the only title at or above 45 minutes.
Title 1 matches the TMDB runtime (Δ +14s)
Already in Plex
Oppenheimer (2023).mp4 · 2.31 GB · added Sep 3
/Volumes/Media/Media/Movies/Oppenheimer (2023) {tmdb-872585}
Ripping again replaces this file once the new encode succeeds.
This disc cannot improve that file:
Chapters   now: 20, unnamed (“Chapter 1”…“Chapter 20”)   21 names from the scene menu   not upgraded
           20 chapters in the file, 21 names on the disc — not upgraded
Audio 1    now: AC3, 5.1, language eng                  —                              —
Subtitles  now: none                                    menu lists: English, Français  needs a re-rip
           a subtitle track has to be encoded, so this needs a re-rip
Disc menu: "Play" starts title 1 — matches.
Chapter names from the disc menu are not being used — the menu names 21 chapters and the disc has 20.
Audio
This disc does not tag its audio languages, so only the first track starts selected. Tick more if …
☑ English   3 tracks
▸ 6 subtitle tracks, none carried into the output
```

Every one of those sentences is precise, honest and was written to answer a
specific past failure (#0025, #0032, #0038, #0039, #0053, #0056, #0059,
#0062, menu-intelligence §7.3). Not one of them is badly written. The
problem is that **precision is the default** when it should be **available
on request**.

## Design in one paragraph

Every user-facing sentence gets two registers: a **plain** one — the
default, one short sentence a person with no vocabulary for DVDs can act on
— and a **detail** one, which is the existing precise string, kept
**verbatim**. The plain string is *added beside* the existing one, never
substituted for it, so the diagnostic record, the tests that pin it and the
History window are untouched. A single persisted **Details** disclosure
(`AppSettings.showsDetails`) switches every step from the plain register to
plain-plus-detail; tooltips (`.help`) always carry the detail register, so a
disabled button explains itself precisely on hover even with Details off. A
third tier — the History window and its log — is the diagnostic record and
is not touched at all. Settings splits the same way: the three things a
person has to set are on top; binaries, paths and the dependency table are
under the same Details disclosure.

---

## 1. The two-level rule

### 1.1 Three tiers, two of them in the rip window

| Tier | Where | Register | Who it is for |
|---|---|---|---|
| **Plain** (default) | Every step body, the action-bar caption, the menu bar summary, the top of Settings | One sentence, no tool names, no counts the person did not ask for, names the control to press | The person ripping a disc |
| **Details** (on request) | The same places, under a `DetailsDisclosure`, plus every `.help` tooltip | The existing strings, verbatim | The repo owner, and anyone whose rip went wrong |
| **Record** (never simplified) | History window: summary card, facts, log pane, Copy Log, notifications' bodies | Verbatim, filtered as today | Bug reports, `DiscReliabilityLog`, the corpus |

The plain tier is what a non-technical person sees on every step unless they
open Details. Opening Details once opens it everywhere and it stays open
across launches (§1.4) — "an option to expand to see details" is a
preference, not a per-screen chore.

### 1.2 The plain register, as rules a test can check

A plain string:

1. **Names no tool.** Never HandBrake, HandBrakeCLI, TMDB, MakeMKV,
   makemkvcon, ffmpeg, ffprobe, libdvdcss, libdvdread, menudump, lsdvd,
   x265, Vision. "Plex" is allowed — it is the destination the person chose.
2. **Uses no DVD vocabulary.** No "title" (say "the movie" or "part of the
   disc"), no "PGC", "chapter marker", "remux", "mux", "mount", "stream",
   "track number", "raw device", "CSS".
3. **Shows no identifiers.** No `tmdb-275`, no paths, no exit statuses,
   no signal numbers, no job ids, no `{tmdb-…}` folder tags.
4. **Rounds.** Minutes, not seconds; "about 45 minutes", not `Δ +14s`. A
   number appears only when the person has to act on it (which language to
   tick, how many extras they chose).
5. **Names the control.** If a sentence sits beside a disabled button it
   says what to press: "Press Rip anyway if you're sure."
6. **Is one sentence, two at most**, and fits beside the Start button at
   the 560-point minimum without wrapping past two lines (#0140's review:
   the current longest reason is 103 characters and wraps to two).
7. **Says nothing when there is nothing to decide.** A caption that only
   explains why the default is the default ("No preferred audio languages
   are set, so the first track starts selected.") is Details.

Rule 1–3 is mechanically checkable: `PlainLanguageTests` (§8) runs every
plain string through a forbidden-terms list. That is the guard that keeps
a later, well-meant, precise sentence from creeping back into the default.

### 1.3 Where the two strings come from — keep the precise ones verbatim

**Decision: every existing precise string is kept byte-for-byte as the
detail text, and a new plain string is added beside it.** Nothing is
rewritten. Where an existing string already meets the plain register
("Choose a movie.", "The scan was cancelled.", "Ejecting…"), it *is* the
plain string and the detail is `nil`.

For:

- **They are the project's diagnostic record.** `FailurePresenter.message`
  is what `JobPresentation.bugReportText` pastes into a bug report;
  `UpgradeProposal`'s "20 chapters in the file, 21 names on the disc — not
  upgraded" is the *only* place both numbers reach the screen, and §7.3's
  count rule exists because of the disc that produced it; #0053's reasons
  were reworded in review to name the exact control. Rewriting them for
  tone risks losing the fact each one was written to carry.
- **They are pinned.** `StartGateTests`, `ScanStatusLineTests`,
  `DiscTitleFormattingTests`, `FailurePresenterTests`,
  `DuplicatePresentationTests`, `UpgradeProposalTests`,
  `JobPresentationStepsTests`, `MenuIntelligenceTests` and
  `AudioTrackOptionsTests` assert these strings (§8 lists which). Adding a
  parallel string changes no existing test; rewriting would touch dozens of
  assertions for no functional gain, and every one of those tests is
  regression coverage against a real disc.
- **They are shared with the Record tier.** `JobPresentation.make(for:).label`
  is the History sidebar *and* the menu bar; `FailurePresenter.headline` is
  the Done card *and* the notification *and* the History card. Splitting
  plain from detail at the *presentation* seam, rather than rewriting the
  source string, is what lets History stay verbatim while the rip window
  goes plain.
- **It is the cheapest implementation with the smallest blast radius.**
  Every change is additive: a `plain…` property or function beside the
  existing one, an exhaustive `switch` so a new case cannot forget its
  plain wording (the idiom `StartDecision.reason` and `FlowStep.title`
  already use). Every step below compiles on its own with the suite green.

Against, honestly:

- A few detail strings read awkwardly *as* details ("the disc's names are
  not chapters 1…20 — not upgraded"). They are still exactly the sentence
  that answers "why did Changeover refuse?", and the person reading Details
  has asked for that. Left alone.
- Two strings in one place (plain + detail) are more text than one when
  Details is open. That is what Details *is*; with it closed the window is
  strictly shorter than today (§2).
- Some current strings are neither plain nor detail but the plain sentence
  *with* a technical clause bolted on ("Scanning disc — this takes tens of
  seconds…"). These are kept verbatim as detail and get a plain sibling
  anyway, rather than being split; consistency of the rule beats a saved
  line.

Conclusion: keep verbatim. The one thing this design *does* change about
existing strings is **where** they appear — several leave the default view
entirely (§4) — never *what* they say.

### 1.4 Mechanism

**The carrier.** One small value type, file-scope and `nonisolated` like
`StartDecision`/`ScanStatusLine.Line`:

```swift
/// A sentence in two registers. `plain` is the default; `detail` is the
/// existing precise wording, verbatim, or `nil` when `plain` already is it.
nonisolated struct Wording: Equatable, Sendable {
    var plain: String
    var detail: String?
    init(plain: String, detail: String? = nil)
    static func plain(_ text: String) -> Wording   // detail == nil
    /// What to draw: `[plain]`, or `[plain, detail]` with Details open —
    /// never the detail twice when it equals the plain text.
    func lines(showingDetails: Bool) -> [String]
}
```

Most producers do **not** return `Wording`; they gain a parallel `plain…`
property next to the existing one, so that the existing signatures, callers
and tests are untouched. `Wording` is assembled at the view seam (or by a
small `…Wording` helper) where a view needs both. `StartDecision` is the
model: `reason` stays, `plainReason` is added, both exhaustive switches.

**The switch.** One persisted boolean:

```swift
// AppSettings
/// The Details disclosure's state, shared by every step and Settings.
/// Persisted on toggle (like `choosePlexRoot`), not on Save.
var showsDetails: Bool = false        // Keys.showsDetails
```

Persisted in `UserDefaults` through the existing `Keys`/`persist()` path;
the toggle calls `settings.persist()` immediately, the way
`choosePlexRoot()` already does, so it never waits on the Settings window's
Save button. `AppSettingsTests` round-trips it through an injected suite.

**The disclosure.** One shared view, used wherever a step has detail content
that is not merely the second line of a `Wording`:

```swift
/// "Details ▸" / "Hide details ▾". Reads and writes `settings.showsDetails`.
/// Content is laid out inside the step's own scroller, never in the action
/// bar, so opening it can never change the window's minimum height (#0140).
struct DetailsDisclosure<Content: View>: View {
    @Environment(AppSettings.self) private var settings
    @ViewBuilder let content: Content
}

/// Renders one `Wording`: the plain line in the given font; with Details
/// open, the detail beneath it in `.caption`/`.secondary`. The plain line is
/// the VoiceOver label; the detail is its own element read after it.
struct WordingText: View { let wording: Wording; var font: Font = .subheadline }
```

`DetailsDisclosure` is a `Button` styled as a link with a chevron, not a
SwiftUI `DisclosureGroup` bound to a `@State`: the state has to be the
shared, persisted one, and the same control must appear identically on
Confirm, Done, Ripping and Settings. Its label is
`Label("Details", systemImage: "chevron.right")`, rotated when open;
`.accessibilityLabel("Details")`, `.accessibilityValue(open ? "shown" : "hidden")`,
`.accessibilityHint("Shows the exact reasons and technical values.")`.
The open/close animation is wrapped in `withAnimation` unless
`accessibilityReduceMotion` is set. Text uses semantic fonts only
(`.subheadline`, `.caption`), with `.fixedSize(horizontal: false, vertical: true)`
so Dynamic Type wraps rather than truncates — the existing convention.

**Tooltips are the detail register.** Every `.help(...)` on a control keeps
its verbatim sentence. The action-bar caption beside Start becomes
`startDecision.plainReason`; the button's `.help` stays
`startDecision.reason`. #0053's rule — "the caption and the tooltip can never
disagree" — still holds in the sense that matters: both come from the same
`StartDecision` value, one per register.

**Where the disclosure sits, per step.** At the *end* of the body's plain
content, once per step, never in the action bar:

| Step | Plain body | `DetailsDisclosure` reveals |
|---|---|---|
| Insert a disc | unchanged | nothing — no disclosure on this step |
| Choose the movie | search, results, one-line disc status | in each `MovieRow`, the `tmdb-275` id; in the strip, the verbatim scan line. No separate disclosure: `WordingText` inline |
| Confirm | movie card, disc summary, audio picker, one-line subtitles note, notices | destination folder/file, the runtime caption, scan warnings, the feature-source caption, the full title table's extra columns, "N tracks" badges, the menu captions, the subtitle rows, the upgrade card, the verbatim lines of every notice |
| Ripping | movie, phase, bar, "About 45 minutes left" | the `Movies/…` path, "56 fps · elapsed 12m 08s", the verbatim unit label, "Show log…" |
| Done | outcome, plain lines, primary actions | "Filed as <path>", verbatim elapsed/eject line, `FailurePresenter` headline + details, "Show log…" |
| Settings | Plex folder, TMDB key, surround toggle, one-line readiness | tool paths, derived paths, languages codes field, Dependencies table |

Nothing about **window sizing** changes. `WindowSizing.heightClass(for:)`
keys on the step, not on `showsDetails`, so the window never moves when
Details opens; the extra content scrolls inside the body, which is #0140's
rule doing its job. With Details **off**, every step's body is strictly
shorter than today's, because the plain tier hides lines rather than adding
them. With Details **on**, Confirm and Done are today's content plus one
plain line per sentence — both already scroll. Ripping has no scroller and
is bounded: with Details off it *loses* the path line; with Details on it
gains back the path line and one caption, which is today's height — still
inside the compact 340 (`docs/window-sizing.md`: Ripping's worst case is
~300). One open question there (§10).

---

## 2. Per-step: the default view after this change

Wireframes show the **plain** tier. Everything that left is listed in §4.

### Step 1 — Insert a disc

```
                   (opticaldisc glyph)
            Put a DVD in the drive to begin.

   Last job: Fargo (1996) — Finished in 41m 12s
```

`.discUnavailable`: "The disc is stuck in the drive. Try Eject again, or
take the disc out by hand." + **Eject**. `.ejecting`: "Ejecting…". No
Details disclosure on this step; the verbatim sentences are tooltips on Eject.

### Step 2 — Choose the movie

```
│ Choose the movie                          FARGO_WS  [⟲][⚙] │
├──────────────────────────────────────────────────────────┤
│ ◌ Reading the disc — this takes a moment…    Cancel Scan │
├──────────────────────────────────────────────────────────┤
│ [ Search movies…                              ] [Search] │
├──────────────────────────────────────────────────────────┤
│ ▣ Fargo                                             1996 │
│ ▢ Fargo                                             2014 │
├──────────────────────────────────────────────────────────┤
│                                              [Continue]  │
```

Strip variants (plain): "Disc ready — the main movie was found." /
"Disc ready — this looks like a TV disc, not a movie; you'll pick what to
rip next." / "Disc ready — you'll pick which part to rip next." /
"The disc couldn't be read. [Scan Again]" / "Nothing playable was found on
this disc. [Scan Again]". With Details open the verbatim line ("Scan
complete — 8 titles, main feature detected", the `HandBrakeCLI exited with
status 3` sentence, HandBrake's last line) appears beneath.

### Step 3 — Confirm

```
│ Confirm the rip                           FARGO_WS  [⟲][⚙] │
├──────────────────────────────────────────────────────────┤
│ ┌──┐ Fargo (1996)                          Change movie  │
│ │▒▒│ Listed length 1h 38m                                │
│ └──┘                                                     │
│                                                          │
│ The movie · 1h 38m ✓ length matches   Show everything on the disc │
│ Extras: none  Add…                                       │
│                                                          │
│ Audio                                                    │
│ ☑ English                                                │
│ ☐ English  Commentary                                    │
│ Subtitles aren't copied to Plex yet.                     │
│                                                          │
│ Details ▸                                                │
├──────────────────────────────────────────────────────────┤
│                                          [Start Ripping] │
```

When something needs deciding it appears here in plain words, in the same
place it does today: the TV-disc / "couldn't tell which part is the movie"
sentence over the (plain) title table; the length-mismatch sentence with
**Rip anyway**; "This movie is already in Plex" with **Replace the Existing
File**; the one-line upgrade offer with its button when — and only when —
the disc can add something. The whole upgrade comparison card, the menu
captions, the scan warnings, the path preview and the runtime caption's
"will not run" reasons are under Details.

### Step 4 — Ripping

```
│ Ripping                                             [⟲][⚙] │
├──────────────────────────────────────────────────────────┤
│ Fargo (1996)                                             │
│                                                          │
│ Ripping the movie                                        │
│ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   31 %         │
│ About 45 minutes left                                    │
│                                                          │
│ Then 2 extras                                            │
│ Details ▸                                                │
├──────────────────────────────────────────────────────────┤
│                                            [Cancel Job]  │
```

Details adds the `Movies/…/….mp4` line, "Encoding the feature · 56 fps ·
elapsed 12m 08s", and "Show log…" in the bar's leading slot.

### Step 5 — Done

```
│ Done                                                [⟲][⚙] │
├──────────────────────────────────────────────────────────┤
│ ● Fargo (1996)                                           │
│   Added to Plex.                                         │
│   Took 41 minutes. The disc has been ejected.            │
│   Details ▸                                              │
├──────────────────────────────────────────────────────────┤
│ Reveal in Finder                            [Next Disc]  │
```

Failed: "● Fargo (1996) — Failed" / plain headline from
`FailurePresenter.plainHeadline` ("This disc couldn't be read. Clean it and
try again.") / "Took 12 minutes. The disc is still in the drive." /
Details ▸ → the verbatim headline and every detail line ("HandBrake said:
“…”", the `brew install` lines) and "Show log…".

---

## 3. The copy: current → plain → detail

Conventions in the tables:

- **Detail** = "verbatim" means the existing string, unchanged, is the
  detail text. "— (plain only)" means the existing string already meets
  the plain register and gets no detail. "Details only" means the existing
  string is *not* shown by default at all and appears, verbatim, only with
  Details open (§4 lists these again with their new home).
- `⟨…⟩` marks a value the plain string interpolates; where it needs a
  formatter the app lacks, the formatter is named in §6.
- Button titles are listed where they change; unlisted ones stay.

### 3.1 `StartGate.swift` — `StartDecision.reason` → add `plainReason`

The caption beside Start shows `plainReason`; the button's `.help` shows
`reason`. Both exhaustive.

| Case | Current `reason` (kept as `.help`) | Plain caption |
|---|---|---|
| `.jobRunning` | A job is already running. | Another disc is still being ripped. |
| `.noDisc` | No disc is mounted — insert a DVD before starting. | Put a DVD in the drive first. |
| `.discUnavailable` | The disc was unmounted but could not be ejected — retry Eject or remove the disc before starting. | The disc is stuck in the drive. Try Eject again, or take it out by hand. |
| `.scanInProgress` | Waiting for the disc scan to finish. | Still reading the disc… |
| `.scanFailed` | The disc scan failed — rescan before starting. | The disc couldn't be read. Press Scan Again. |
| `.noTitlesOnDisc` | The scan read no titles from this disc — rescan before starting. | Nothing playable was found on this disc. Press Scan Again. |
| `.noMovieSelected` | Choose a movie. | Choose a movie. (same) |
| `.noTitleSelected` | Pick a title. | Pick which part of the disc to rip. |
| `.noAudioTrackSelected` | No audio track selected — choose at least one audio track before starting. | Tick at least one audio track. |
| `.runtimeLookupLoading` | Checking the TMDB runtime — this finishes on its own. | Checking the movie's length — one moment. |
| `.runtimeMismatchUnconfirmed` | Confirm the runtime mismatch with Rip anyway. | The length doesn't match. Press Rip anyway if you're sure. |
| `.libraryCheckInProgress` | Checking the Plex library for this movie. | Checking whether this movie is already in Plex… |
| `.duplicateUnacknowledged` | This movie is already in Plex — choose Replace the Existing File to rip it again. | Already in Plex. Press Replace the Existing File to rip it again. |
| `.upgradeNothingSelected` | There is nothing this disc can add to the file already in Plex. | (same — only ever shown inside the upgrade card, which is Details) |
| `.ffmpegMissing` | Upgrading needs ffmpeg — run brew install ffmpeg, then reopen this window. | Details only |
| `.fileCheckInProgress` | Reading what the existing file already has. | Details only |
| `.ready` | `nil` | `nil` |

Start's enabled `.help` "Encode the selected title into the Plex library."
→ "Rip this movie into Plex." (a tooltip, but this one is *not* diagnostic;
plain is the better register for it).

### 3.2 `ScanStatusLine.swift` — `Line.text` → add `Line.plain`

| `ScanState` | Current `text` (verbatim → detail) | Plain |
|---|---|---|
| `.scanning` | Scanning disc — this takes tens of seconds… | Reading the disc — this takes a moment… |
| `.failed(f)` | `scanFailureMessage(f)` (§3.3) | `plainScanFailureMessage(f)` (§3.3) |
| `.scanned`, no titles | `noTitlesMessage(…)` (§3.3) | Nothing playable was found on this disc. |
| `.scanned`, `.single` | Scan complete — ⟨N⟩ titles, main feature detected | Disc ready — the main movie was found. |
| `.scanned`, `.playAll` | Scan complete — ⟨N⟩ titles, none of them looks like a movie | Disc ready — this looks like a TV disc, not a movie. You'll pick what to rip next. |
| `.scanned`, `.none` | Scan complete — ⟨N⟩ titles, choose one on the next step | Disc ready — you'll pick which part to rip next. |

Buttons: "Rescan" → **"Scan Again"** (strip and disc panel). "Cancel Scan"
stays.

### 3.3 `DiscTitleFormatting.swift`

Every function keeps its name and output; a `plain…` sibling is added.

**`scanFailureMessage` → `plainScanFailureMessage`**

| Failure | Current (detail) | Plain |
|---|---|---|
| `.toolMissing(path)` | HandBrakeCLI was not found at ⟨path⟩. Check the path in Settings. | A program Changeover needs isn't installed. Open Settings to fix it. |
| `.launchFailure(msg)` | Could not launch HandBrakeCLI: ⟨msg⟩ | The disc reader couldn't start. Open Settings to check it. |
| `.toolExited(code)` | The disc scan failed (HandBrakeCLI exited with status ⟨code⟩). | The disc couldn't be read. Try Scan Again, or clean the disc. |
| `.jsonMissing` | The disc scan did not complete — no title information came back. | The disc couldn't be read. Try Scan Again. |
| `.titleSetCorrupted` | The disc scan's title data was corrupted and could not be read. | The disc couldn't be read. Try Scan Again, or clean the disc. |
| `.cancelled` | The scan was cancelled. | — (plain only) |

**`noTitlesMessage(warnings:lastLine:)` → `plainNoTitlesMessage`**

| Current (detail, verbatim — including HandBrake's last line and the Full Disk Access hint) | Plain |
|---|---|
| The scan read no titles from this disc. HandBrake's last line: "…" This scan fell back to reading the disc through libdvdcss's raw-device workaround — if that keeps failing to find titles, Changeover may not have permission to read the drive (System Settings → Privacy & Security → Files and Folders, or Full Disk Access). | Nothing playable was found on this disc. Try Scan Again, or clean the disc. |

The permissions hint is genuinely actionable but is "worded as a
possibility, not a diagnosis" (its own doc comment); it stays in Details.
If the user finds it bites often on joe, it can be promoted — a one-line
change to the plain function.

**`confirmationDetail(index:title:)` → `plainFeatureLine(title:)`**

| Current (detail) | Plain |
|---|---|
| Title ⟨i⟩ · 1:37:52 · 21 chapters · 6.8 GB | The movie · 1h 38m |

Needs `plainDuration(_ seconds:)`: whole minutes, rounded, "1h 38m" /
"48m" — `runtime(_ minutes:)` already renders that shape; the new function
rounds seconds to minutes and calls it. The heading "Main feature" becomes
"The movie" in plain (the `Text("Main feature")` in `confirmationRow` and
the table badge); "Main feature" is kept in the detail line.

**`featureSourceCaption(.length)` → `plainFeatureSourceCaption`**

| Current (detail) | Plain |
|---|---|
| HandBrake did not name a main feature — chosen because it is the only title at or above 45 minutes. | Changeover guessed this is the movie because it's the only long part of the disc. Check the length looks right. |

Stays orange in both registers — it is the one guess on the screen.

**`extrasStatusLine(plan)` → `plainExtrasLine`**

| Current (detail) | Plain |
|---|---|
| Extras: none | Extras: none (same) |
| Extras: 2 · 0:48:12 | Extras: 2 · 48m |

Links: "Choose…" → **"Add…"**; "Change…" stays.

**`playAllMessage(index:episodes:disc:)` → `plainPlayAllMessage`**

| Current (detail) | Plain |
|---|---|
| This looks like a TV season disc — 8 titles of about 21 minutes that together match the length of title 12. | This looks like a TV disc, not a movie. Pick the part you want below. |

The second sentence in `DiscTitleListView` ("Ripping is still possible by
picking a title below, but nothing here is treated as a movie.") is
Details only — the plain sentence already says "pick the part you want".

**`.none` sentence (currently a literal in `DiscTitleListView`)** — moves
into `DiscTitleFormatting.noFeatureWording` so it gains a test:

| Current (detail) | Plain |
|---|---|
| This disc did not identify itself — no title looks like a feature. That can happen on a TV disc with no Play All title, or a feature under 45 minutes. Choose one below. | Changeover couldn't tell which part of the disc is the movie. Pick it below — it's usually the longest one. |

**`extrasSummary` (literal in `DiscTitleListView`)** — moves into
`DiscTitleFormatting.extrasSummaryWording(plan)`:

| Current (detail) | Plain |
|---|---|
| 2 extras selected — 0:48:12 total, filed outside the Plex library | Extras: 2 · 48m (the same `plainExtrasLine`) |

**`streamSummary(for:)` → `plainLanguages(for:)`**

| Current (detail) | Plain |
|---|---|
| 2 audio (eng, spa) · 1 sub | English, Spanish |
| no audio or subtitle streams | No sound |

Needs `languageName(_ code:)` — the `Locale.current.localizedString(forLanguageCode:)`
lookup `TrackSelectionView.languageLabel` already does, moved here so both
the table and the picker use one function and it gains a test. Untagged
streams contribute nothing (as today), so a fully untagged title reads
"2 audio tracks".

**`subtitleSummary(count:)` → `plainSubtitleLine`**

| Current (detail; the `DisclosureGroup` label) | Plain (a single caption, no disclosure) |
|---|---|
| 6 subtitle tracks, none carried into the output | Subtitles aren't copied to Plex yet. |

The plain line is constant on purpose — it states #0036's fact about the
output, which *is* the surprise a person needs to hear once; the count is a
detail.

**`runtimeCaption(lookup)` → `plainRuntimeCaption`**

| `RuntimeLookup` | Current (detail) | Plain |
|---|---|---|
| `.loading` | Checking TMDB runtime… | Checking the movie's length… |
| `.loaded(_, m)` | TMDB runtime 1h 38m | Listed length 1h 38m |
| `.unavailable(_, r)` | Runtime cross-check will not run — ⟨`runtimeNotRunText(r)`⟩ | Couldn't check the movie's length. |
| `.idle` | `nil` | `nil` |

`runtimeNotRunText` reasons ("TMDB API key is not configured.", "waiting on
TMDB.", "TMDB has no runtime for this title.", "no disc feature title yet.",
the lookup error) stay verbatim inside the detail string.

**Runtime verdict (currently two literals in `DiscTitleListView.runtimeVerdict`)**
— moves into `DiscTitleFormatting.runtimeVerdictWording(title:verdict:)`
returning `Wording`, so the Δ arithmetic is tested:

| Verdict | Current (detail) | Plain |
|---|---|---|
| `.consistent(δ)` | Title 1 matches the TMDB runtime (Δ +14s) | ✓ Length matches. |
| `.mismatch(δ)`, disc shorter | Title 1 does not match the TMDB runtime (Δ −1832s) — check this is the right title. | This part is about 31 minutes shorter than the movie should be. It may not be the movie — check before ripping. |
| `.mismatch(δ)`, disc longer | (same shape, positive Δ) | This part is about ⟨n⟩ minutes longer than the movie should be. It may not be the movie — check before ripping. |
| acknowledged caption | Confirmed — Start is enabled despite the mismatch. | OK — you've chosen to rip it anyway. |

Minutes = `abs(δ)` rounded to the nearest minute; "about a minute" below
90 seconds. The plain consistent line may fold into the feature line as the
"✓ length matches" suffix in the §2 wireframe; either way it is one
`Wording`.

### 3.4 `DiscTitleListView.swift` — the table and its chrome

The title table is Details-tier *content* by construction on `.single` (it
opens only from "Show everything on the disc") but is the primary control on
`.playAll`/`.none`, so its **rows** get a plain layout too:

| Column | Today | Plain row | Details adds |
|---|---|---|---|
| index | `1` | hidden | `1` |
| duration | `1:37:52` | `1h 38m` | `1:37:52` |
| chapters | `21 ch` | hidden | `21 ch` |
| size | `6.8 GB` | hidden | `6.8 GB` |
| streams | `2 audio (eng, spa) · 6 subs` | `English, Spanish` | verbatim |
| badge | `Main feature` | `The movie` | `Main feature` |
| Extra checkbox | ☐ | ☐ (same) | — |

Other strings in the file:

| Where | Current | Plain | Detail |
|---|---|---|---|
| `scanningView` | Scanning disc — this takes tens of seconds… | Reading the disc — this takes a moment… | verbatim |
| Rescan `.help` (unavailable) | The disc was unmounted but could not be ejected — retry Eject or remove the disc before rescanning. | *(tooltip — stays verbatim)* | — |
| Rescan `.help` | Scan the disc again. | *(tooltip — stays)* | — |
| "Show all titles" / "Hide titles" | | **Show everything on the disc** / **Hide** | — |
| scan warnings `⚠︎ …` | libdvdcss could not open the raw device and fell back to the mounted filesystem — this usually works, but a disc that fails here is a CSS error in disguise | **Details only** | verbatim |
| scan warnings `⚠︎ …` | ⟨N⟩ subtitle decode errors during the scan (non-fatal) — the rip may be missing subtitle data | **Details only** (the output carries no subtitles, #0036) | verbatim |
| Extra checkbox `.help` | Rip this title as an extra, filed outside the Plex library | *(tooltip — stays)* | — |
| "Rip anyway" | | (same) | — |

The libdvdcss warning "usually works" and appears on most real discs; the
subtitle-decode warning concerns data the output does not carry. Neither
gives a person anything to *do*, which is rule 7. Both stay in Details and
in the log.

### 3.5 `TrackSelectionView.swift` / `AudioTrackOptions.notice` → add `plainNotice`

| Case | Current (detail) | Plain |
|---|---|---|
| no options | No audio tracks reported for this title. | This part of the disc has no sound. |
| nothing selected | No audio track selected. Choose at least one to start. | Tick at least one audio track to start. |
| untagged | This disc does not tag its audio languages, so only the first track starts selected. Tick more if this disc carries more than one language. | The disc doesn't say which language each track is. The first is ticked; tick others if you want them too. |
| no preferences set | No preferred audio languages are set, so the first track starts selected. | **Details only** (`nil` in plain) |
| none preferred present | None of your preferred languages (eng, spa) is on this title, so the first track starts selected. | None of your usual languages is on this disc, so the first track is ticked. |
| a preferred language unticked | ⟨spa⟩ is also on this title and one of your preferred languages, but only one track starts selected — tick it to keep it too. | ⟨Spanish⟩ is also on this disc. Tick it if you want to keep it. |
| otherwise | `nil` | `nil` |

Row labels: the language name stays, but in the **proportional** body font
(the monospaced style reads as a terminal); the "⟨N⟩ tracks" merge count is
Details only; the "Commentary" capsule stays in both.

`MenuAudioHint.line` ("This disc's Languages menu lists: English, Français.
…") → **Details only**, verbatim.

Subtitles: the `DisclosureGroup` and `subtitleRowText` rows ("English ·
forced · bitmap — cannot become an MP4 track") are **Details only**; the
plain tier is the single caption from §3.3.

### 3.6 `ConfirmStepView.swift` — the movie card and captions

| Where | Current | Plain | Detail |
|---|---|---|---|
| card line 2 | `Fargo (1996) {tmdb-275}` (folderName, monospaced) | hidden | verbatim, monospaced |
| card line 3 | `Fargo (1996).mp4` (fileName) | hidden | verbatim |
| card line 4 | `runtimeCaption` | `plainRuntimeCaption` (§3.3) | verbatim |
| "Change movie" | | (same) | — |
| Continue `.help` (Choose step) | Choose a movie from the results first. / Confirm the disc title and tracks for this movie. | Pick a movie from the list first. / Next: check the disc, then start. | — |

`menuNotice` — `MenuStatusLine.lines` → add `plainLines`:

| Source | Current (detail) | Plain |
|---|---|---|
| `readingCaption` | Reading the disc's menus… | **Details only** |
| `MenuUnavailable.helperMissing` | Disc menus: not read — changeover-menudump isn't installed (Settings ▸ Dependencies). The rip is unaffected. | **Details only** |
| `.librariesMissing` | Disc menus: buttons only — ⟨list⟩ isn't installed, so the menu text can't be read (Settings ▸ Dependencies). The rip is unaffected. | **Details only** |
| `.noMenus` | Disc menus: nothing readable on this disc. The rip is unaffected. | **Details only** |
| `.failed(r)` | Disc menus: not read — ⟨r⟩. The rip is unaffected. | **Details only** |
| `PlayButtonResolver.confirmationLine`, agrees | Disc menu: "Play" starts title 1 — matches. | **Details only** |
| …, no scan feature | Disc menu: "Play" starts title 3. | **Details only** |
| …, disagrees | Disc menu: "Play" starts title 3; the scan chose title 1. | The disc's own Play button points at a different part than the one picked here. If the length looks wrong, choose a different part. |
| `judgeCaption` | This disc has 4 buttons that start a title; "Play Movie" reads as the feature (title 1). The scan still chooses what is encoded. | **Details only** |
| `chapterLine`, `.write(rows)` | ⟨N⟩ chapter names from the disc menu will be written into the file. | Chapter names from the disc will be included. |
| `chapterLine`, `.refused(r)` | Chapter names from the disc menu are not being used — ⟨r⟩. | **Details only** |

The one that stays plain is the one that can change what the person does
(pick a different part). The refused chapter line is a decision the user may
disagree with (§9): `ChapterMarkerPlan`'s doc says "a refusal the user cannot
see is indistinguishable from a bug" — this design says the *owner*, who has
Details open, sees it, and the person who doesn't know what a chapter marker
is should not be told one was refused.

### 3.7 `DuplicatePresentation.swift` — `DuplicateNotice` gains `plainHeadline`, `plainLines`

| Kind | Current headline / lines (detail, verbatim) | Plain headline / lines |
|---|---|---|
| `.checking` | Checking the Plex library… | Checking whether this movie is already in Plex… |
| `.unreachable(r)` | Couldn't check the Plex library: ⟨r⟩ / If this movie is already there, it will be replaced. | Couldn't check whether this movie is already in Plex. / If it is, it will be replaced. |
| `.present`, one folder, same name | Already in Plex / `Fargo (1996).mp4 · 1.42 GB · added Sep 3` / ⟨folder path⟩ / Ripping again replaces this file once the new encode succeeds. | This movie is already in Plex. / Ripping it again will replace the copy that's there (added ⟨Sep 3⟩). |
| `.present`, different folder name | Already in Plex, as “⟨folder⟩” / … / The new file will be filed as ⟨folderName⟩; the old folder is left in place. | This movie is already in Plex under a different name. / The new copy will be added alongside it. |
| `.present`, several folders | Already in Plex — ⟨N⟩ folders carry {tmdb-⟨id⟩} / … / Ripping again replaces the file in ⟨folder⟩ once the new encode succeeds. | This movie is in Plex more than once. / Ripping it again will replace one of the copies. |
| `.acknowledged` | Will replace ⟨fileLine⟩ (or: Will replace the existing copy in Plex) / ⟨folder path⟩ | OK — the existing copy will be replaced. |

Buttons: "Check again" stays; "Reveal" → **"Show in Finder"**; "Replace the
Existing File" stays (it is deliberately literal). The file line
(`name · size · added date`) and the folder path are Details.

### 3.8 `UpgradePresentation.swift` / `UpgradeProposal.swift` — the card is Details; one plain sentence when there is an offer

The comparison card is the most technical surface in the app and is only
ever a *bonus* on top of a duplicate that the person has already been told
about. Rule: **with Details off, the card renders only when
`proposal.offersUpgrade`, as one sentence and one button; otherwise nothing.**
With Details on, today's card renders verbatim beneath the plain sentence.

New: `UpgradePresentation.plainOffer(card:) -> PlainOffer?` where
`PlainOffer { sentence: String; actionTitle: String }`, built from
`UpgradePlan.changeSummary` (which already renders "20 chapter names, 1
audio language"):

| State | Current (detail, verbatim) | Plain |
|---|---|---|
| offers upgrade | This disc can improve that file without re-encoding it: + rows + footnote | This disc can add ⟨20 chapter names and 1 audio language⟩ to the copy already in Plex — about 2 minutes, nothing is re-encoded. **[Improve the Existing Copy (~2 min)]** |
| `overwriteWouldHelp` only | This disc's chapter names differ from the ones already in the file: + toggle | **Details only** (an expert decision) |
| refused | This disc cannot improve that file: + rows with reasons | **Details only** |
| unchanged | That file already has everything this disc can give it. | **Details only** |
| ffmpeg missing | This disc might be able to improve that file without re-encoding it. / Checking needs ffmpeg, which isn't installed: brew install ffmpeg. Ripping is unaffected. | **Details only** |
| reading file | Reading what that file already has… | **Details only** |
| unreadable | Couldn't read that file: ⟨reason⟩ / Ripping is unaffected. | **Details only** |

Action title "Upgrade metadata (remux, ~2 min)" → plain **"Improve the
Existing Copy (~2 min)"**; the verbatim title stays as `actionTitle` on the
Details card. `changeSummary` needs an "and" joiner for the plain sentence
(`"20 chapter names and 1 audio language"`); add `plainChangeSummary`
rather than changing `changeSummary`, which the Done card and tests use.

Every `UpgradeRow` string — `now:` ("20, unnamed (“Chapter 1”…“Chapter
20”)", "AC3, 5.1, language eng"), `fromDisc:` ("21 names from the scene
menu", "menu lists: English, Français"), the marks ("✓ upgrade", "—", "not
upgraded", "needs a re-rip") and every `.refused`/`.needsRerip` reason:

- ⟨N⟩ chapters in the file, ⟨M⟩ names on the disc — not upgraded
- the disc's names are not chapters 1…⟨N⟩ — not upgraded
- a chapter name from the disc came out empty — not upgraded
- ⟨N⟩ of the file's chapters already carry real names — tick “Replace existing names” to overwrite them
- the file has no chapter markers at all, and a remux cannot add timings
- the disc's menu lists its languages but does not say which track is which — not upgraded
- the disc's menus name no language for this track
- a subtitle track has to be encoded, so this needs a re-rip

— are **Details only, verbatim**. The footnotes ("Tick “Replace existing
chapter names” to write the disc's names over the ones already there.",
"The video and audio are copied untouched, and the new file is checked
against the old one before it replaces it.") likewise.

### 3.9 `RippingStepView.swift` / `JobPresentation.progressSummary`

`ProgressSummary` gains `plainUnitLabel` and `plainETAText`; `formatETA`
stays for History.

| Source | Current (detail, verbatim) | Plain |
|---|---|---|
| unit label, pre-encode scan | Reading the disc | Reading the disc (same) |
| unit label, feature | Encoding the feature | Ripping the movie |
| unit label, extra | Encoding extra 2 of 3 — title 7 | Ripping extra 2 of 3 |
| unit label, extras (no unit) | Encoding extras | Ripping extras |
| unit label, remux | Rewriting metadata in ⟨file⟩ | Updating the copy in Plex |
| `.fallback` | Retrying with MakeMKV | Trying another way to read the disc |
| `.starting` | Checking setup | Getting ready |
| `.organizing` | Moving into Plex | Moving into Plex (same) |
| cancelling | Cancelling… | Cancelling… (same) |
| `formatETA` ≥ 1h | ETA 1h 05m | About 1 h 5 min left |
| `formatETA` minutes | ETA 45 min | About 45 minutes left |
| `formatETA` < 60 s | ETA under a minute | Almost done |
| ETA unknown | `nil` | Working out how long this will take… |
| detail line | ETA 45 min · 56 fps · elapsed 12m 08s | *(the ETA alone; the rest is Details)* |
| path line | `Movies/⟨folder⟩/⟨file⟩` | **Details only** |
| extras line | Then: 2 extras | Then 2 extras |
| "Show log…" | | **Details only** |
| Cancel `.help` refusal (`CancelPolicy`) | the job is being moved into Plex and can't be interrupted | *(tooltip — stays)*; the disabled button's caption, if one is added, is "Almost done — this can't be stopped now." |

"Cancel Job" stays: the confirmation alert's buttons ("Cancel Job" / "Keep
Going") already use it.

### 3.10 `DoneStepView.swift` / `JobPresentation.outcomeCard`

`OutcomeCard` gains `plainLines: [String]`; `lines` stays verbatim for
Details and the tests.

| Phase | Current `lines` (detail, verbatim) | Plain lines |
|---|---|---|
| succeeded | Filed as ⟨/Volumes/…/Fargo (1996).mp4⟩ | Added to Plex. |
| | Finished in 41m 12s · disc ejected | Took 41 minutes. The disc has been ejected. |
| | Finished in 41m 12s · the disc is still in the drive | Took 41 minutes. The disc is still in the drive. |
| | Finished in 41m 12s · the disc could not be ejected | Took 41 minutes. The disc couldn't be ejected. |
| | Finished (no end date) | Finished. |
| | ⚠︎ The disc was unmounted but could not be ejected — retry Eject or remove it by hand. | The disc is stuck in the drive. Try Eject again, or take it out by hand. |
| succeeded, upgrade | Upgraded: ⟨changeSummary⟩. Video and audio untouched. / ⟨filePath⟩ | Added ⟨20 chapter names and 1 audio language⟩ to the copy in Plex. Nothing was re-encoded. |
| failed | `FailurePresenter` headline + details (§3.11) + elapsed | `FailurePresenter.plainHeadline` + plain elapsed |
| cancelled | Finished in … · … | Stopped after ⟨12 minutes⟩. The disc is still in the drive. |
| disc removed | The disc was removed while the job was running. / elapsed | The disc was taken out before ripping finished. Nothing was added to Plex. |
| pruned | That job is no longer in this session's history. | That rip is no longer listed. |

Headlines: "⟨name⟩", "⟨name⟩ — Failed", "⟨name⟩ — Cancelled", "Disc
removed" stay. "⟨name⟩ — Upgraded" → plain **"⟨name⟩ — Updated"**;
"⟨name⟩ — Not upgraded" → plain **"⟨name⟩ — Not updated"**.

"Took ⟨n⟩ minutes" uses whole minutes (`plainElapsed`: "under a minute" /
"⟨n⟩ minutes" / "⟨h⟩ h ⟨m⟩ min"); `formatElapsed`'s "41m 12s" stays for
History and the Insert step's "Last job" line, which is fine as is.

Buttons: "Next Disc", "Retry", "Eject", "Reveal in Finder" stay. "Adjust &
Retry" → **"Go Back & Retry"** (it returns to Confirm). "Show log…" is
Details only — the header's History button is always there.

### 3.11 `FailurePresenter.swift` — add `plainHeadline(for:)`

`message(for:)` and `headline(for:stage:)` are untouched; the Done card's
plain tier shows exactly one sentence, and every `details` line ("Install
it with `brew install handbrake` …", "It said: “…”", "HandBrake said: “…”",
the MakeMKV fallback sentences) is Details only.

| `FailureReason` (stage) | Current headline (detail, verbatim) | Plain headline |
|---|---|---|
| `.toolMissing`, preflight, empty path | No HandBrakeCLI path is set. | A program Changeover needs isn't set up yet. Open Settings to fix it. |
| `.toolMissing`, preflight | HandBrakeCLI isn't at ⟨path⟩. | A program Changeover needs isn't installed. Open Settings to fix it. |
| `.toolMissing`, other | ⟨name⟩ isn't installed at ⟨path⟩. | A program Changeover needs isn't installed. Open Settings to fix it. |
| `.toolLaunchFailed` | ⟨tool⟩ couldn't be started: ⟨msg⟩ | A program Changeover needs couldn't start. Open Settings to check it. |
| `.toolIncompatible`, preflight | This HandBrakeCLI can't run Changeover's encode. | The installed ripping program is the wrong kind or too old. It needs updating. |
| `.toolIncompatible`, other | This ⟨tool⟩ doesn't accept the options Changeover uses. | (same plain) |
| `.toolExited(code)` | ⟨tool⟩ stopped with exit status ⟨code⟩, for a reason Changeover doesn't recognise. | Ripping stopped unexpectedly. Try again; if it keeps happening the disc may be damaged. |
| `.toolExited`, signal (refined) | HandBrakeCLI stopped unexpectedly (signal ⟨n⟩). | (same plain) |
| `.noTitlesProduced` (rip / encode) | MakeMKV found no usable title on this disc. / HandBrake found no title it could encode on this disc. | Nothing playable could be read from this disc. |
| `.destinationUnwritable`, preflight, root | Your Plex media folder isn't available: ⟨path⟩. | Your Plex drive isn't connected. |
| `.destinationUnwritable`, other | Changeover can't write to ⟨path⟩. | Changeover can't save to your Plex folder. Check the drive is connected. |
| `.diskFull`, preflight | There isn't enough free space to start this disc. | Your Plex drive doesn't have enough free space. |
| `.diskFull`, other | The drive holding your Plex library is full. | Your Plex drive is full. |
| `.activationExpired` | MakeMKV's registration key has expired. | The backup disc reader (MakeMKV) needs a new registration key. |
| `.discUnreadable` | HandBrake couldn't read this disc. | This disc couldn't be read. Clean it and try again. |
| `.discUnreadable`, CSS key (refined) | HandBrake couldn't unlock this disc's copy protection. | This disc's copy protection couldn't be unlocked. |
| `.cancelled` | The job was cancelled before it finished. | — (plain only) |
| `.unknown(detail)` | Something went wrong: ⟨detail⟩ | Something went wrong. |

`.activationExpired` names MakeMKV on purpose: the person has to open that
app to fix it, so the name is the instruction. It is the one tool name the
forbidden-terms test allows, and only in this string.

### 3.12 `JobPresentation.make` — add `plainLabel`; the menu bar reads it

`label` stays (History sidebar, History card, tests). `menuSummary` and the
Insert step's "Last job:" line switch to `plainLabel`:

| Phase | `label` (verbatim) | `plainLabel` |
|---|---|---|
| `.starting` | Checking setup | Getting ready |
| `.encoding` | Encoding ⟨name⟩ | Ripping ⟨name⟩ |
| `.encoding`, remux | Rewriting metadata in ⟨file⟩ | Updating ⟨name⟩ in Plex |
| `.fallback` | Retrying with MakeMKV | Trying another way to read the disc |
| `.organizing` | Moving into Plex | (same) |
| `.extras` | Encoding extras | Ripping extras |
| `.succeeded` | Finished in 41m 12s | (same) |
| `.failed` | Failed | (same) |
| `.cancelled` | Cancelled / Disc removed | (same) |
| cancelling | Cancelling… | (same) |

`menuSummary`: "Idle — insert a DVD to begin" → **"Ready — insert a DVD"**;
"Last job failed — ⟨headline⟩" → "Last rip failed — ⟨plainHeadline⟩";
"Settings required" → **"Set up in Settings first"**. `menuTone` unchanged.

### 3.13 `InsertDiscStepView.swift`

| Current | Plain | Detail |
|---|---|---|
| Insert a DVD to begin. The disc is scanned automatically and this window opens on it. | Put a DVD in the drive to begin. | verbatim (as the glyph's `.help`) |
| Ejecting… | (same) | — |
| `StartDecision.discUnavailable.reason` | `plainReason` (§3.1) | verbatim, as Eject's `.help` |
| Last job: ⟨name⟩ — ⟨label⟩ | Last job: ⟨name⟩ — ⟨plainLabel⟩ | — |

### 3.14 `ChooseMovieStepView.swift` / `MovieRow`

| Current | Plain | Detail |
|---|---|---|
| `1996  ·  tmdb-275` | `1996` | `1996 · tmdb-275` |
| `search.errorMessage` (from `TMDBClient`) | The movie search didn't work. Check your internet connection and try again. | verbatim |

### 3.15 `RipFlowView.swift` — step titles and the disc subtitle

Titles ("Insert a disc", "Choose the movie", "Confirm the rip", "Ripping",
"Done") already meet the register; unchanged. The subtitle "Disc: FARGO_WS"
drops its "Disc: " prefix (the header already says what step this is); the
volume name is the disc's own label and is worth keeping so two discs in a
row are distinguishable. Open question in §10 whether it reads as noise.

### 3.16 `SettingsView.swift` / `DependencyPanelView.swift`

Settings gets the same two tiers. **Plain (top of the window, in order):**

1. **Plex folder** — path (shortened: `…/Plex Media`, middle-truncated as
   now) + **Choose…**. Red "Not set" when empty. The `NSOpenPanel` message
   "Select your Plex Media root folder (e.g. Plex Media on the MediaSSD)"
   → "Choose the folder Plex uses for your media — the one that contains
   Movies."
2. **Movie lookup key** — the `SecureField`; caption "Changeover looks
   movies up on The Movie Database. A free key from themoviedb.org is
   needed." (This names TMDB: the person has to visit the site, so the name
   is the instruction — allowed like MakeMKV in §3.11.)
3. **Keep the original surround sound (larger files)** — the
   `keepOriginalAudioTrack` toggle, retitled from "Keep the original 5.1
   track (larger files)".
4. **Readiness** — one line from `DependencyPanel.plainSummary(rows)`:
   "✓ Ready to rip." / "✗ HandBrake isn't installed, so nothing can be
   ripped yet. Open Details for the install command." / (optional tools
   missing) nothing.
5. **Details ▸** — the same `DetailsDisclosure`, same `showsDetails` key.

**Details (under the disclosure), verbatim as today:** the derived-path
preview rows ("Movies", "TV Shows", "Clips", "Fallback rip", "Encoding");
the CLI Tools group (HandBrakeCLI / makemkvcon path fields, Detect, every
`statusLine` string: "✓ Ready", "No path set", "Not found", "That's the
HandBrake app, not HandBrakeCLI", "Missing: …", "Couldn't verify: …",
"Couldn't launch: …", "Installed, fallback available", "Not installed,
fallback unavailable (not required)", the Detect notes); the
"makemkvcon is optional. …" and "lsdvd: …" captions; the whole
`DependencyPanelView` (summary, rows, purposes, `brew` lines, menudump/ffmpeg
path fields, the "Menu reading is optional everywhere. …" footer); the
Languages group with its ISO-code field and its caption ("Comma-separated
ISO 639-2 codes …"); the long Audio caption ("Every selected track is always
encoded to one AAC stereo track at 160 kbps …").

The Languages field is Details rather than plain because a plain version
("English, Spanish") needs a name→code mapping the app does not have
(`LanguageCode.normalize` accepts codes only) — out of scope, §9.

Not changed here, noted for a later pass: the Save button and the 460×300
hand-built window (`docs/settings-screen.md` §2 and §4 already argue for
apply-immediately and content-driven size). `showsDetails` persists on
toggle regardless of Save, as `choosePlexRoot()` does.

### 3.17 `JobLogView.swift`, `JobHistoryView.swift`, `MenuReader.swift` log lines — unchanged

The History window is the Record tier. `HistoryDetail` (facts "Title 1 ·
audio 1, 3 · 2 extras", "Job ⟨id⟩", "Filed as ⟨path⟩"), the `LogPane`
(filter "Important"/"Everything", fold labels "x265 settings" / "libdvdnav"
/ "HandBrake output", "… ⟨N⟩ earlier lines dropped"), `bugReportText`, and
every line `MenuReader`/`DVDPipeline` write to the log — including
"▶ Disc menus: 77 menus, 20 stills read, 0 chapter names", "▶ Disc menus:
archived to ⟨path⟩", "▶ Disc menus: no still could be rendered — chapter
names and hints are unavailable" — stay exactly as they are. They are
reached only through the header's History button (and the Details-tier
"Show log…"), which is the person opting into the record.

If the "▶ Disc menus" line the user cited was seen somewhere *other* than
the History log pane, that is the first thing to check in the screenshot
(§10).

### 3.18 `JobNotifier.swift` — unchanged

The notification bodies ("Encoded and moved into Plex. The disc has been
ejected.", "The disc was removed while the job was running. Nothing new was
filed in Plex.", "Changeover stopped the job before it finished. …") already
meet the register. The failure notification's body is
`FailurePresenter.message(for:).headline` today; it switches to
`plainHeadline` — a notification is the plainest surface the app has.

---

## 4. What leaves the default view entirely, and where it goes

| Gone from the default | Where it lives now |
|---|---|
| Plex folder/file preview on the movie card (`Movies/Fargo (1996) {tmdb-275}/Fargo (1996).mp4`) | Confirm ▸ Details; Ripping ▸ Details; History facts |
| `tmdb-275` in search results | Choose ▸ Details (inline under the year) |
| HandBrake title index, seconds, chapter count, size, subtitle count in the feature line and table rows | Confirm ▸ Details (the table's extra columns; the verbatim feature line) |
| "HandBrake did not name a main feature — …" | Confirm ▸ Details (its plain sibling stays, orange) |
| "Title 1 matches the TMDB runtime (Δ +14s)" | Confirm ▸ Details ("✓ Length matches." stays) |
| Scan warnings (`⚠︎ libdvdcss …`, `⚠︎ N subtitle decode errors …`) | Confirm ▸ Details; the log |
| "Runtime cross-check will not run — ⟨reason⟩" | Confirm ▸ Details ("Couldn't check the movie's length." stays) |
| Every `MenuStatusLine` caption except the Play-button disagreement and "chapter names will be included" | Confirm ▸ Details |
| "This disc's Languages menu lists: …" | Confirm ▸ Details |
| "No preferred audio languages are set, so the first track starts selected." | Confirm ▸ Details |
| "⟨N⟩ tracks" merge badges on audio rows | Confirm ▸ Details |
| The subtitle `DisclosureGroup` and its per-track rows | Confirm ▸ Details (one plain caption stays) |
| The upgrade comparison card (rows, verdicts, reasons, footnotes, overwrite toggle) in every state but "offers upgrade" | Confirm ▸ Details |
| The duplicate notice's file line and folder path | Confirm ▸ Details |
| "Filed as ⟨full path⟩" | Done ▸ Details; History facts; Reveal in Finder |
| "Finished in 41m 12s · disc ejected" | Done ▸ Details; History |
| `FailurePresenter` details (brew lines, "HandBrake said: “…”", fallback sentences) | Done ▸ Details; History card; notification is plain |
| "56 fps · elapsed 12m 08s" | Ripping ▸ Details; History status line |
| "Show log…" on Ripping and Done | Ripping/Done ▸ Details; the header's History button is always present |
| CLI tool paths, Detect, tool status lines, derived path previews, Dependencies table, ISO language codes, the long audio caption | Settings ▸ Details |

Nothing is deleted. Nothing changes in the log, the History window, the
reliability log or the corpus fixtures.

---

## 5. Accessibility

- **VoiceOver** reads the plain sentence as the element's label. Where a
  `Wording` renders both lines, the detail is a separate element after it,
  so a screen-reader user hears the plain sentence first and can move on.
  `DetailsDisclosure` has a label, a value ("shown"/"hidden") and a hint.
  The action-bar caption keeps its existing role; the Start button's
  `.help` remains the detail sentence, which VoiceOver exposes as help text.
- **Dynamic Type**: semantic fonts only (`.subheadline`, `.caption`,
  `.caption2`, `.body`), `fixedSize(horizontal: false, vertical: true)` on
  every multi-line `Text` — the existing convention. The plain strings are
  deliberately short (rule 6) so the action bar still fits two lines at
  large sizes; the #0140 reviewer's 103-character worst case gets shorter,
  not longer.
- **Reduce Motion**: the disclosure's open/close is un-animated when
  `accessibilityReduceMotion` is set, mirroring `WindowSizing.Situation.reduceMotion`.
- **Persistence**: `showsDetails` is the one piece of disclosure state that
  persists; `DiscTitleListView.showFullTable`, `LogPane.filter` and the
  subtitle group's expansion stay display-only `@State` as today.

---

## 6. Types and files

### 6.1 New files

| File | Contents |
|---|---|
| `Changeover/Wording.swift` | `nonisolated struct Wording` (§1.4) |
| `Changeover/DetailsDisclosure.swift` | `DetailsDisclosure<Content>` and `WordingText` (SwiftUI, MainActor by default) |
| `Changeover/PlainLanguage.swift` | `nonisolated enum PlainLanguage` — the shared formatters the plain tier needs and nothing else owns: `minutes(_ seconds:) -> String` ("about 31 minutes", "about a minute"), `elapsed(_ seconds:)` ("41 minutes", "1 h 5 min", "under a minute"), `languageName(_ code:)`, `andList(_:)` ("a, b and c"), and `static let forbiddenTerms: [String]` for the test |

### 6.2 Additions to existing types (all additive; no signature changes)

| Type | Added |
|---|---|
| `AppSettings` | `var showsDetails: Bool`, `Keys.showsDetails`, load in `init`, write in `persist()` |
| `StartDecision` | `var plainReason: String?` |
| `ScanStatusLine.Line` | `let plain: String` (a new stored field; `line(for:)` fills it) |
| `DiscTitleFormatting` | `plainDuration`, `plainFeatureLine(title:)`, `plainScanFailureMessage`, `plainNoTitlesMessage`, `plainFeatureSourceCaption`, `plainExtrasLine`, `plainPlayAllMessage`, `noFeatureWording: Wording`, `extrasSummaryWording(_:)`, `plainLanguages(for:)`, `plainSubtitleLine`, `plainRuntimeCaption`, `runtimeVerdictWording(title:verdict:)`, `acknowledgedWording: Wording` |
| `AudioTrackOptions` | `plainNotice(options:preferred:untagged:selected:) -> String?` |
| `MenuStatusLine` | `plainLines(_:scanFeatureTitle:markerPlan:) -> [String]` |
| `PlayButtonResolver` | `plainConfirmationLine(_:scanFeatureTitle:) -> String?` (non-nil only for the disagreement) |
| `DuplicateNotice` | `let plainHeadline: String`, `let plainLines: [String]` |
| `UpgradePresentation` | `struct PlainOffer`, `plainOffer(card:proposal:) -> PlainOffer?`, `static let plainActionTitle` |
| `UpgradePlan` | `var plainChangeSummary: String` |
| `JobPresentation` | `let plainLabel: String` (a stored field beside `label`, filled by `make`); `menuSummary` reads it |
| `JobPresentation.ProgressSummary` | `let plainUnitLabel: String`, `let plainETAText: String` |
| `JobPresentation` | `static func plainETA(seconds:)`, `plainElapsed(_:)` |
| `JobPresentation.OutcomeCard` | `let plainHeadline: String`, `let plainLines: [String]` |
| `FailurePresenter` | `static func plainHeadline(for failure: JobFailure) -> String` (takes the whole failure so it can apply the same CSS/signal refinements `message(for:)` does) |
| `CancelPolicy.Decision` | `var plainRefusalReason: String?` |
| `DependencyPanel` | `plainSummary(_ rows:) -> String?` |
| `TMDBClient` / `MovieSearchViewModel` | `plainErrorMessage` beside `errorMessage` |

Every new function is `nonisolated static` on a `nonisolated enum` or a
stored `let` on a `nonisolated struct` — the seams `ScanStatusLine`,
`StartDecision` and `JobPresentation` already use, so the test target's
non-isolated helpers can call them and `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` never bites.

### 6.3 Views (thin, switch-and-layout only)

| View | Change |
|---|---|
| `ConfirmStepView` | caption = `plainReason`; card hides folder/file unless `settings.showsDetails`; `menuNotice` reads `plainLines` or `lines`; `upgradeCard` renders `PlainOffer` or the full `UpgradeCardView`; one `DetailsDisclosure` at the end of the `VStack` inside the `ScrollView` |
| `DiscTitleListView` | plain/detail feature line via `WordingText`; warnings only under Details; table columns gated on `showsDetails`; badge text; button titles |
| `TrackSelectionView` | `plainNotice`; proportional font; "N tracks" gated; subtitle section = caption unless Details |
| `DuplicateNoticeView` | reads `plainHeadline`/`plainLines` or the verbatim pair; "Show in Finder" |
| `UpgradeCardView` | unchanged (it is the Details rendering); a new tiny `UpgradeOfferView` renders `PlainOffer` |
| `RippingStepView` | `plainUnitLabel`, `plainETAText`; path and rate line gated; "Show log…" gated |
| `DoneStepView` | `plainHeadline`/`plainLines`, `DetailsDisclosure` inside the `ScrollView`; "Show log…" gated; "Go Back & Retry" |
| `InsertDiscStepView` | plain sentences; verbatim as `.help` |
| `ChooseMovieStepView` / `MovieRow` | `line.plain` in the strip with `line.text` under Details; `tmdb-` gated; "Scan Again"; `plainErrorMessage` |
| `StatusMenuView` | no change (reads `menuSummary`, which now reads `plainLabel`) |
| `SettingsView` | reordered into the plain group + `DetailsDisclosure` containing today's groups verbatim |

`RipFlowView`, `StepActionBar`, `WindowChrome`, `WindowSizing`,
`RipWindowSizer`, `FlowStep`, `RipFlowController`, `JobController`,
`StartGate.decide`: **untouched**.

---

## 7. Implementation order — each step compiles and the suite stays green

Every step is additive; the verbatim strings never change, so no existing
assertion changes. Run `./run-remote-tests.sh gordon` **once**, at the end
(memory: minimise full-suite runs; never on the development Mac; never UI
tests), and commit per step.

1. **Carrier and switch** — `Wording.swift`, `PlainLanguage.swift`
   (formatters + `forbiddenTerms`), `AppSettings.showsDetails` (+ key, load,
   persist), `DetailsDisclosure.swift`. No view uses them yet. Tests:
   `AppSettingsTests` round-trip; `PlainLanguageTests` for the formatters
   (`minutes(1832) == "about 31 minutes"`, `elapsed(2472) == "41 minutes"`,
   `languageName("spa") == "Spanish"` under `en_US`). (~30 min)
2. **Start reasons** — `StartDecision.plainReason`; `ConfirmStepView`
   caption/tooltip split. Tests: `StartGateTests.everyDecisionHasAPlainReason`
   (`CaseIterable`, `nil` only for `.ready`), and the forbidden-terms sweep
   over every `plainReason`. (~20 min)
3. **Disc status** — `ScanStatusLine.Line.plain`; the `DiscTitleFormatting`
   plain functions (§3.3) including the two literals moved out of
   `DiscTitleListView` (`.none` sentence, extras summary) and the runtime
   verdict; `ChooseMovieStepView`, `DiscTitleListView` read them; "Scan
   Again", "Show everything on the disc", "The movie", "Add…". Tests:
   `ScanStatusLineTests` (one plain case per state), `DiscTitleFormattingTests`
   (one per new function; the mismatch minutes both signs; `plainLanguages`
   on the untagged Hornet's Nest fixture renders no "()"). (~60 min)
4. **Audio and subtitles** — `AudioTrackOptions.plainNotice`,
   `plainSubtitleLine`, `TrackSelectionView`. Tests: `AudioTrackOptionsTests`
   mirror of the existing `notice` cases; the "no preferences" case returns
   `nil`. (~25 min)
5. **Confirm notices** — `MenuStatusLine.plainLines`,
   `PlayButtonResolver.plainConfirmationLine`, `DuplicateNotice.plain*`,
   `UpgradePresentation.plainOffer`, `UpgradePlan.plainChangeSummary`,
   `UpgradeOfferView`; `ConfirmStepView`'s `menuNotice`/`duplicateNotice`/
   `upgradeCard` branches; the `DetailsDisclosure` at the end of the body.
   Tests: `MenuIntelligenceTests` (plain lines are empty for every
   `MenuUnavailable`; exactly one line for the Play-button disagreement),
   `DuplicatePresentationTests` (plain headline per kind; the acknowledged
   case), `UpgradeProposalTests`/`UpgradeGateTests` (`plainOffer` is `nil`
   for every refused/unchanged/no-ffmpeg card and non-nil with
   `changeSummary`'s numbers when a plan exists — the Oppenheimer 20/21 case
   must yield `nil`). (~60 min)
6. **Ripping and Done** — `JobPresentation.plainLabel`,
   `ProgressSummary.plainUnitLabel`/`plainETAText`, `plainETA`,
   `plainElapsed`, `OutcomeCard.plainHeadline`/`plainLines`,
   `FailurePresenter.plainHeadline`, `CancelPolicy.Decision.plainRefusalReason`;
   `RippingStepView`, `DoneStepView`, `InsertDiscStepView`; `menuSummary`
   and `JobNotifier`'s failure body read the plain forms. Tests:
   `JobPresentationStepsTests` (plain summary per phase; `plainETA(2729) ==
   "About 45 minutes left"`, `plainETA(30) == "Almost done"`; outcome card
   plain lines for succeeded/failed/cancelled/disc-removed/eject-failed),
   `FailurePresenterTests` (one plain headline per reason × stage, the CSS
   and signal refinements, and the forbidden-terms sweep with the
   `.activationExpired` exemption), `JobPresentationTests` (`plainLabel` per
   phase; `menuSummary` strings), `JobNotifierTests` (failure body). (~60 min)
7. **Settings** — `DependencyPanel.plainSummary`; `SettingsView` regrouped
   with today's groups inside the `DetailsDisclosure`, verbatim. Tests:
   `DependencyPanelTests` (`plainSummary` is `nil` when only optional tools
   are missing, names HandBrake when it is). (~40 min)
8. **The sweep** — `PlainLanguageTests.noPlainStringNamesATool` runs
   `forbiddenTerms` (§8) over every plain producer that can be enumerated
   without a disc: all `StartDecision` cases, every `FailureReason` × stage,
   every `ScanState` the tests can build, every `MenuUnavailable`, every
   `DuplicateNotice.Kind`, every `JobPhase`. Then `./run-remote-tests.sh
   gordon` once; fix; commit. (~20 min + the run)

Steps 2–7 are independent of each other once step 1 is in; two agents could
split them (2–4 and 5–7) without touching the same files, except
`ConfirmStepView`, which step 5 should own.

---

## 8. Tests

All in `ChangeoverTests`, Swift Testing, pure seams only.

**`PlainLanguageTests`** (new)

- formatters (§7 step 1);
- `forbiddenTerms` = `["HandBrake", "HandBrakeCLI", "TMDB", "MakeMKV",
  "makemkvcon", "ffmpeg", "ffprobe", "libdvdcss", "libdvdread", "menudump",
  "lsdvd", "x265", "tmdb-", "exit status", "signal ", "remux", "mux", "PGC",
  "mount", "raw device", "CSS", "chapter marker", "Δ"]` plus the regex
  `\btitles?\b` (so "subtitle" passes and "title 1" fails);
- the sweep: every enumerable plain string contains none of them, with a
  single documented exemption for `.activationExpired` ("MakeMKV") and the
  Settings TMDB caption.

**Existing suites gain one plain assertion per existing verbatim assertion**
(§7 names them): `StartGateTests`, `ScanStatusLineTests`,
`DiscTitleFormattingTests`, `AudioTrackOptionsTests`,
`MenuIntelligenceTests`, `DuplicatePresentationTests`,
`UpgradeProposalTests`, `UpgradeGateTests`, `JobPresentationTests`,
`JobPresentationStepsTests`, `FailurePresenterTests`, `JobNotifierTests`,
`DependencyPanelTests`, `AppSettingsTests`.

**Invariants worth a dedicated test each:**

- `Wording.lines(showingDetails: true)` never repeats a detail equal to the
  plain text.
- `StartDecision.plainReason == nil ⇔ self == .ready` (the same shape the
  existing `reason` test has).
- `UpgradePresentation.plainOffer` is `nil` exactly when
  `proposal?.offersUpgrade != true` — the plain tier never shows the card
  for a refusal.
- `MenuStatusLine.plainLines` is empty for every `MenuUnavailable` and for
  `.reading`.
- Every plain caption that can sit beside Start is ≤ 90 characters (rule 6).
- `MetadataWindowReuseTests.theWindowOpensAtTheStepsHeight` and
  `theSizerMovesTheWindowBetweenTheTwoHeightsAndItStaysThere` pass
  unchanged with `showsDetails` both `false` and `true` — a new
  parameterised case, because the Details content must never raise the
  published minimum (#0140).

No view is tested and no UI test is written or run.

---

## 9. Out of scope, and decisions the user may disagree with

**Out of scope (needs something the app does not compute):**

1. A plain **Preferred languages** field ("English, Spanish") — needs a
   language-name → ISO 639-2 mapping; `LanguageCode.normalize` accepts codes
   only. The codes field stays, under Details.
2. **Localization.** Every string is English; this is not a
   `Localizable.strings` pass. `Wording` would carry `LocalizedStringKey`s
   later without changing its shape.
3. **Settings apply-immediately / window sizing** —
   `docs/settings-screen.md` already covers it; not bundled here.
4. **A plain "why this part?"** beyond `FeatureSource.scanner`/`.length` —
   the heuristic reports no other reason.
5. **Poster on Ripping/Done** — `MovieMetadata` carries no `posterPath`
   (`docs/ux-step-flow.md` §8); unchanged.

**Decisions the user may disagree with:**

1. **One global Details switch, not one per section.** Persisted, shared
   across the five steps and Settings. The alternative (a disclosure per
   notice) is more granular and more clicks; it is a `Bool`-per-section
   change if the screenshot says the Confirm step opens too much at once.
2. **The refused-chapter-names line is Details only.** `ChapterMarkerPlan`'s
   comment says a refusal must be visible; here it is visible to whoever has
   Details open. Promoting it is one line in `plainLines`.
3. **Scan warnings are Details only, with no plain placeholder.** No "read
   with warnings" hedge in the default, because neither warning gives a
   person anything to do.
4. **"Show log…" leaves the default action bar.** The header's History
   button is one click away on every step.
5. **The upgrade card vanishes from the default unless it can do
   something.** The duplicate notice already says the film is in Plex; a
   card explaining what cannot be improved is expert content.
6. **`JobPresentation.label` is not renamed.** `plainLabel` sits beside it
   so History keeps "Encoding Fargo (1996)" while the menu bar says
   "Ripping Fargo (1996)". Two words for one phase, on purpose, by tier.
7. **"Rescan" → "Scan Again", "Reveal" → "Show in Finder", "Adjust & Retry"
   → "Go Back & Retry", "Choose…" → "Add…".** Small, and the only button
   renames; "Rip anyway", "Replace the Existing File", "Cancel Job", "Next
   Disc", "Start Ripping", "Continue" stay.

---

## 10. Open questions a screenshot would settle

Noted rather than guessed; the screenshot of the running app is being
captured separately.

1. **Where was "▶ Disc menus: 77 menus, 20 stills read, 0 chapter names"
   seen?** In the code it reaches only the History log pane (§3.17). If the
   screenshot shows it in the rip window, something is rendering
   `logDisplayRows` that this reading missed, and that becomes step 0.
2. **Does the plain Confirm step still need the 640-point `full` height?**
   With Details off it is a card, one feature line, an audio picker and one
   caption. If it looks empty, `WindowSizing.heightClass` could take
   `showsDetails` into account — but that is a sizing change this design
   deliberately does not make, and the height-class table says Choose and
   Confirm share a height so the Continue → Confirm → Change movie loop
   never hops.
3. **Ripping with Details open** — the path line plus "56 fps · elapsed"
   plus the disclosure row inside the compact 340. §1.4 argues it fits
   (today's content is ~300); confirm on the two-line path case.
4. **One global toggle vs. per-section** (§9.1) — whether the Confirm step,
   fully open on the Oppenheimer disc, is a wall or a reference.
5. **"The movie" as the badge and heading**, versus "Main feature". It reads
   right in prose; whether it reads right as a 10-point capsule is visual.
6. **The header subtitle** (`FARGO_WS` without "Disc: ") — noise or useful?
7. **Settings at 460×300** with the plain group on top — whether the
   `ScrollView`'s 620 cap and the Save bar still make sense, or whether
   `docs/settings-screen.md`'s content-driven size should land first.
8. **Which state the upgrade card was in** when the user saw "20 chapters in
   the file, 21 names on the disc — not upgraded" (a refusal, so the plain
   tier shows nothing at all). Worth confirming that "nothing" is the
   wanted answer rather than a one-line "The copy in Plex is fine as it is."
