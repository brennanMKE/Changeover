# Changeover — Roadmap

**Created:** 2026-09-11
**References:** `Plan.md` (Phases 1–10, 12 complete) · `RemoteControl.md` · `Montages.md`

---

## How this roadmap works

Each phase ends in a **demo** — something that can be shown to another person in
a few minutes and that visibly works. Phases are ordered so that every one of
them leaves the app more useful than it was, and none of them leaves it in a
half-finished state that has to be held together with explanation.

Two rules shaped the ordering:

1. **Correctness before capability.** There are real defects in the current
   pipeline. Building remote control on top of a rip that can silently produce
   the wrong movie would mean demoing a bug from across the room.
2. **The physical loop sets the priority.** Discs are swapped by hand, so the
   value of every feature is measured against "how much of the disc-to-Plex loop
   can happen without walking over to the mini."

---

## Where things stand

**Working today** (`Plan.md` Phases 1–10, 12): menu bar app with no Dock icon,
DVD detection via `NSWorkspace`, TMDB search with poster art, Plex-correct
folder and file naming, rip → encode → move pipeline with live log streaming,
settings with a Plex root picker and CLI path detection.

**Known defects carried into Phase 1:**

- `RipController` rips **all** titles, then selects the largest resulting `.mkv`
  from the working directory. A leftover `.mkv` from a previous disc can be
  picked up and encoded as the current movie. The working folder is never
  cleaned (`Plan.md` 11.6).
- Pipeline state lives in `MetadataEntryView` as `@State`. Closing the window
  orphans a running job, and nothing outside the view can observe progress.
- No eject, no completion notification — every disc requires a trip to the mini
  just to open the tray.

---

## Phase overview

| Phase | Theme | Demo in one line |
|---|---|---|
| 1 | Trustworthy single-disc rip | Insert a disc, walk away, it lands in Plex and ejects |
| 2 | Choose what gets ripped | Pick the main feature and audio tracks; skip the junk |
| 3 | Unattended multi-disc | Three discs back to back without babysitting |
| 4 | Remote control from a Mac | Drive the whole loop from the MacBook Air |
| 5 | iPhone and iPad clients | Drive the whole loop from the couch |
| 6 | Ship to other people | Clean-Mac install from a DMG |
| 7 | Montages | A looping montage on a display |

---

## Phase 1 — Trustworthy single-disc rip

**Goal:** The core pipeline is correct and closes its own loop. No manual
cleanup, no trip to the machine to eject, no chance of the wrong file.

### Demo

> Insert a DVD. Search the title, pick the poster, hit Start. Walk away.
> The rip runs, the encode runs, the file appears in the Plex library under the
> correct `Title (Year) {tmdb-ID}` folder, the disc ejects, and a notification
> says it's done. **Then do it a second time with a different disc** — and show
> that the second movie is also correct, which is the part that is broken today.

### Work

- Extract `@Observable JobController` from `MetadataEntryView`; `AppDelegate`
  owns it. Local UI behavior unchanged. *Prerequisite for Phases 3 and 4.*
- Scope each rip to a per-job working subdirectory so a stale `.mkv` from a
  previous disc can never be selected.
- Clean the working folder after a successful encode (`Plan.md` 11.6).
- Auto-eject on completion (`Plan.md` 11.4).
- Completion notification via `UNUserNotificationCenter` (`Plan.md` 11.5).
- Surface actionable failures distinctly: MakeMKV key expired, CLI tool missing
  or wrong path, destination unwritable, disk full.

### Exit criteria

- Two different discs ripped consecutively both produce correct output.
- Working folder is empty after each job.
- Killing the metadata window mid-job does not kill the job.
- Every failure mode above produces a message that names the actual problem.

---

## Phase 2 — Choose what gets ripped

**Goal:** Rip the titles and tracks that are actually wanted, instead of
everything on the disc.

### Demo

> Insert a disc that has bonus features. The app lists every title with its
> duration, chapter count and size, with the main feature already selected by
> the length heuristic. Show the audio track list — pick English and Spanish,
> drop the rest. Start. Point out that it is ripping one title instead of
> fourteen, and show the elapsed time against a full-disc rip of the same movie.

### Work

- `DiscScanner` — run `makemkvcon -r info disc:0` on insertion, parse robot-mode
  `DRV` / `TCOUT` / `TINFO` / `SINFO` output into structured data.
- Verify the `TINFO`/`SINFO` numeric attribute **ids** against real discs. They
  come from `apdefs.h` in the MakeMKV SDK and are **not** in the published
  `usage.txt` — this is a research task before the parser can be trusted. Note
  `id` is the attribute and `code` is a localized-display-name message code;
  transposing them is the easy mistake.
- `DiscInfo` / `DiscTitle` / `DiscStream` models in a form that will move to the
  shared protocol package in Phase 4.
- Default selection heuristic: longest title is the main feature; ignore titles
  under a threshold.
- Title selection UI with durations, chapters, size.
- Audio and subtitle language selection.
- `RipController` rips selected title indices instead of `all`.

### Exit criteria

- Title list matches what MakeMKV.app shows for the same disc.
- A disc with bonus features rips only the chosen title.
- Selected audio languages are present in the output and unselected ones are not.
- Scan failure (expired key, unreadable disc) is reported as itself, not as an
  empty title list.

---

## Phase 3 — Unattended multi-disc

**Goal:** The machine stays busy while the human swaps discs.

### Demo

> Three discs on the table. Insert the first, make the selections, start.
> When it ejects, insert the second and set it up **while the first is still
> encoding**. Same for the third. Sit down. All three land in the Plex library
> correctly, and the queue view shows what happened in what order.

### Work

- Job queue with stable job IDs; the host tracks a queue, not a single current
  job. *Protocol-visible — this is why it comes before Phase 4.*
- Allow a new disc to be scanned and queued while an earlier job is encoding.
- Prevent idle sleep during active jobs (`ProcessInfo.beginActivity`).
- Queue UI: pending, running, done, failed — with per-job logs.
- Decide and enforce concurrency limits (one rip at a time; encode may overlap).

### Exit criteria

- Three discs processed in one sitting with no interaction beyond swapping and
  selecting.
- A failed job does not stall the queue behind it.
- The mini does not sleep mid-encode.

---

## Phase 4 — Remote control from a Mac

**Goal:** Everything except inserting the disc happens from the MacBook Air.

### Demo

> Insert a disc at the mini and walk across the room. On the MacBook, the disc
> appears with its title list already scanned. Search TMDB, confirm the poster,
> choose the title and tracks, hit Start. Watch the rip and encode log stream
> live. When it finishes, the disc ejects across the room and the laptop
> notifies. Then quit and relaunch the client to show it reconnects and
> re-syncs mid-job.

### Work

- `ChangeoverProtocol` Swift package — `RemoteCommand`, `RemoteEvent`,
  `JobState`, and the models shared with the host.
- Transport built against `Network.ListenerProvider` / `BrowserProvider`
  abstractions rather than Bonjour concretely, so Wi-Fi Aware is a later
  provider swap (see `RemoteControl.md`).
- `RemoteServer` on the host — `NetworkListener`, Bonjour `_changeover._tcp`,
  fan-out of `JobController` changes to connected clients.
- Pairing: Mode A (iCloud KVS, same Apple ID, zero-config) with Mode B (six-digit
  PIN) fallback; keys in Keychain; per-peer capability field.
- `Changeover Remote` macOS target reusing `MetadataEntryView`,
  `MovieSearchViewModel` and the Phase 2 title picker.
- Reconnect, `subscribe` → state + disc info + log replay handshake,
  multi-client arbitration.
- `NSLocalNetworkUsageDescription` + `NSBonjourServices`; document the host's
  first-run Local Network prompt.

### Exit criteria

- Full loop driven from a second Mac with no Screen Sharing.
- Client survives host restart, Wi-Fi drop and laptop sleep.
- Two connected clients cannot start conflicting jobs.
- An unpaired device on the same network cannot control the host.

---

## Phase 5 — iPhone and iPad clients

**Goal:** The couch case. This is the payoff for the whole remote track.

### Demo

> Same loop as Phase 4, done entirely on an iPhone while sitting down —
> including the notification when the disc ejects and it's time to swap.
> Then the same thing on an iPad to show the wider split layout.

### Work

- Restructure the remote client as a multiplatform target.
- iOS layout pass — poster list and title picker in compact width.
- iPadOS layout pass — split view.
- Local notification on job completion: "Done — next disc."
- Pairing UX on iOS (PIN entry).

### Exit criteria

- Full loop from an iPhone, start to eject.
- Notifications arrive with the app backgrounded.
- Same build runs correctly on iPad.

---

## Phase 6 — Ship to other people

**Goal:** Someone who is not the author can install this and use it.

### Demo

> On a Mac that has never run Changeover: open a downloaded DMG, drag to
> Applications, launch. No Gatekeeper warning. The app walks through finding
> `makemkvcon` and `HandBrakeCLI`, entering a TMDB key, choosing a Plex root,
> and granting Local Network access. Insert a disc and rip it.

### Work

- Developer ID signing, notarization, stapling, drag-to-Applications DMG.
  *(The `mac-release` skill covers this end to end.)*
- First-run onboarding flow replacing "the Settings window opens and you figure
  it out": detect or prompt for each prerequisite in order, with a clear state
  for each.
- Graceful degradation when a CLI tool is missing — explain and link, don't fail
  at rip time.
- Verify the TMDB key at entry rather than on first search.
- README and setup docs rewritten for someone else's machine.

### Exit criteria

- Clean-Mac install with no `xattr -cr` step and no Gatekeeper prompt.
- Every prerequisite is either auto-detected or explained in the UI.
- A person who has not seen the app before can rip a disc without being told
  anything.

---

## Phase 7 — Montages

**Goal:** A second product on the same library. See `Montages.md` — the design
is deliberately still open, and this phase should be re-planned once Phases 1–3
have settled the library and repository conventions it builds on.

### Demo

> Mark five clips from movies in the library. Build a montage from them. Put it
> on a display on a loop. Change the active montage from a phone and watch the
> display switch.

### Work

Sketched only — see `Montages.md` for open questions, especially whether v1
should render montages into a Plex library rather than build a custom player.

- Clip and montage data model with sidecar JSON persistence.
- Clip marking UI with scrubbing and keyboard in/out points. *This is the
  make-or-break piece — if marking clips is a chore, the feature dies.*
- Local playback on the Mac via `AVQueuePlayer`.
- Time-of-day and day-of-week schedule rules.
- Render + manifest export for clients that cannot seek (Raspberry Pi, browser).
- One remote display target — whichever of Plex-library, tvOS or Pi validates
  cheapest.

### Exit criteria

Deferred — to be defined when the phase is planned.

---

## Cross-cutting notes

**Swift conventions apply throughout** — `@Observable` (never `ObservableObject`),
`@State`-owned view models, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with
explicit `nonisolated` only where a type genuinely must leave the main actor.
See `Plan.md` for the full table.

**Things deliberately not in this roadmap:**

- Off-LAN control (CloudKit, push). No use case — the user has to be in the
  house to swap discs.
- Wi-Fi Aware. Shipped on macOS but every symbol is `@available(macOS,
  unavailable)`. Phase 4's transport abstraction is the preparation for it;
  there is nothing else to do until Apple lifts the gate.
- TV show support (`Plan.md` 11.2). Real work, no current demand.
- Plex API auto-scan (`Plan.md` 11.3). Small and pleasant; fold into whichever
  phase has room.
- Debounced type-to-search and result sorting (`Plan.md` 11.1, 11.7). Polish;
  fold into Phase 2 where the search UI is already being touched.
