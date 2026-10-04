# Driving Changeover from an AI agent

`changeoverctl` is a command-line tool embedded in Changeover.app. It exists so
a program — in practice Claude Code — can watch a disc go through the app, read
everything the app extracted from it, decide what is worth importing, and say
so. It is not a convenience wrapper over the UI. It is the UI's peer: the same
decisions, reachable from a shell, with the app's answers coming back rather
than disappearing into a window nobody is looking at.

> **Status: being built.** Phase 1 (transport, `ping`, `status`, `watch`,
> `help`) shipped in #0189. Phase 2 (#0196) shipped the acting verbs — `eject`,
> `cancel`, `wait`, `report`, `select`, `import`. Still unbuilt: `assets`,
> `library` and `search`. Everything below describes the intended surface; a
> command this document lists is not necessarily shipping yet. `changeoverctl
> help` on the installed binary is the authority on what exists today, and it
> is generated from the same command table the tool dispatches on, so it cannot
> drift from reality the way this file can.

## Why a CLI rather than a URL scheme

A URL scheme (`changeover://…`) launches the app and hands it parameters, and
that is all it can do. It cannot return a value, cannot stream progress, and
exits successfully whatever the app made of the request. For an agent that is
useless: the whole point is that **the output is the product**. `status` has to
print what the app actually believes, `watch` has to report things as they
happen, and an exit code has to mean something, or `if ! changeoverctl …` is a
lie.

That requires a live connection, which requires XPC, which requires a broker
launch agent — because a plain app cannot publish a Mach service name. The
architecture, and the reasoning behind every part of it, is documented in the
`RemoteControl` prototype's `docs/` folder; this file does not repeat it.

## The model an agent should hold

One disc is in one drive. Everything the tool reports is about **that disc**,
and a disc swap invalidates all of it. Disc identity (`discID`, derived from
`lsdvd`'s `dvddiscid` where available) is the key to correlate events across a
session; do not assume the volume label is stable or unique, because catalogue
numbers like `7000078778_1` are common and tell you nothing.

The app is doing its own work the whole time. It scans, reads menus with
Vision, asks the on-device model questions, searches TMDB, and — unless told
otherwise — selects a film and starts a job by itself. **An agent that also
decides will race the app.** Holding a `watch` session open is what stops
that: for as long as one is attached the app makes no decisions of its own.

## Commands

### Observing

| Command | What it gives you |
|---|---|
| `changeoverctl ping` | Broker health. Never involves the app, so it is the first thing to run when anything is wrong. |
| `changeoverctl status` | The whole current picture: app version and pid, whether a disc is present and its label and id, the flow step and disc phase, the scan state, what film is identified (title, year, TMDB id), job phase and percentage if one is running, the Start gate's decision **with its reason**, whether automation is suspended and by how many sessions, and a `library` block giving this installation's Plex paths and naming conventions. |
| `changeoverctl watch` | A JSONL event stream. One object per line, flushed as it happens. |
| `changeoverctl report` | What the last job actually did: each film filed, skipped (with the reason), or failed. |

`status` is the one to run on attach. `watch` tells you what *changes*; it
cannot tell you what is already true, and an agent that only watches has no
idea what it walked into.

### Asking about the disc and the library

| Command | What it gives you |
|---|---|
| `changeoverctl assets` | Everything collected for the disc in the drive, written to a temp cache and the path printed: the HandBrake scan, every menu still, the Vision OCR, the menu structure, the derived menu intelligence, and the audio and subtitle track detail per title. |
| `changeoverctl library <tmdb-id>` | Whether that film is already filed, and which extras its folder already holds — matched by duration, not by filename. |
| `changeoverctl search <term>` | TMDB results, so the id you hand to `import` is one the app will accept. |

`assets` writes under the system temporary directory, keyed on disc id, so
macOS clears it when it needs the space. Treat the path as a cache that can
vanish: re-run `assets` rather than storing the path across a long gap.

The audio and subtitle detail is worth knowing about because it is richer than
it looks. Per stream the app records the codec, the ISO 639-2 language (or
`null` — **an untagged track is not English**, and defaulting it is how a
silent MP4 gets made), the channel count, the bitrate, whether it is forced,
whether it is commentary, and HandBrake's variant axis, which is how
`English (Wide Screen)` and `English (Letterbox)` stay distinguishable.

### Acting

| Command | What it does |
|---|---|
| `changeoverctl select …` | Name the feature, and any extras, to import. |
| `changeoverctl import --disc <insertionID>` | Run it. |
| `changeoverctl cancel [--job <id>]` | Abort a running job. |
| `changeoverctl eject [--force]` | Open the tray. |
| `changeoverctl wait --for <condition> --timeout <sec>` | Block until something happens. |

`wait` exists so an agent does not poll. Polling a disc that takes forty
minutes to encode is both wasteful and badly behaved; one blocking call with a
timeout is what a script wants. The conditions are `disc-inserted`,
`disc-ejected`, `scan-complete`, `identified`, `job-done` and `idle`;
`--timeout` is required and has no default, because a wait with no bound is a
script that hangs. A condition that is **already true** is met immediately —
the predicate is evaluated against the app's state, not against the arrival of
an event, so an agent attaching with the disc already in the drive is told so
rather than waiting for an event that already happened. Bind `job-done` to one
job with `--job <id>`, the id `import` reported, or on a two-film disc the first
film's finished job will satisfy the wait while the second is still queued.

### An acting verb needs an attached `watch` session

**Every one of `eject`, `cancel`, `select` and `import` is refused unless a
`changeoverctl watch` session is attached.** It is not a formality and there is
deliberately no flag that waives it.

The endpoint has no authentication: the broker hands it to whoever asks and asks
nothing of them. That was acceptable while every verb observed. Tying the acting
verbs to a live session buys two things that matter more here than making the
call hard. First, **the act is always visible** — the window's agent banner
(#0195) is drawn from the same session count, so there is no arrangement of
calls that ejects a disc or starts an encode while the window still looks idle.
Second, it **closes the race**: the app suspends its own automation only while a
session is attached, so a verb acting without one would be acting against an app
that is still choosing films and starting countdowns of its own.

It is a capability, not a secret. There is nothing to leak and nothing to
rotate, and the thing that authorises is the thing you can kill.

`--session <id>` is optional and checked when given. Supplying it binds your acts
to *your own* watcher; a stale id is refused rather than silently falling back,
so an agent whose watcher died learns that from the refusal rather than from a
disc that came out of the drive during somebody else's job.

What this is **not**: authentication. Nothing proves the process that called
`eject` is the process holding the session, and a hostile local process can open
its own `watch` session and then act. Closing that needs peer verification at
connection-accept time (`SecCodeCopyGuestWithAttributes` against a
`SecRequirement`), which is Phase 3 and deliberately not on #0196 — an unsigned
development build satisfies no requirement, and a refusal at accept time is
silent, which is the worst failure shape this transport has.

### Adding extras to a film already in Plex

The common second pass, and the user's own words for it: *"We already imported
this movie. We are just going to be adding special features to it."* A film
comes off its own disc; its bonus disc later adds featurettes to the same
`Movies/Title (Year) {tmdb-ID}/` folder.

```sh
"$C" select --disc "$D" --session "$S" --movie 121 --extras-only \
    --extra 1  --extra-kind "Behind The Scenes" --extra-label "On the Set" \
    --extra 2  --extra-kind "Behind The Scenes" --extra-label "Return to Middle-earth" \
    --extra 33 --extra-kind Trailers           --extra-label "Return of the King Preview"
"$C" import --disc "$D" --session "$S"      # reports intent "extrasOnly"
```

`--extras-only` goes with `--movie` and at least one `--extra`, and **without**
`--feature-title`: no film is being encoded, so there is no feature to name.
Both contradictions are refused rather than resolved — a `--feature-title`
alongside it, and `--extras-only` with nothing ticked.

The app checks the library itself and grants this only when a folder for that
film is already there **under the name it would write**. Plex reads a film's
extras from inside the film's own folder, so there has to be one, and Changeover
will not create a second folder beside an existing one with the same `{tmdb-…}`
tag. The refusal says which case it hit: not filed yet, filed under a different
folder name, or the library could not be read.

Nothing can overwrite the film's own file on this path. An extras-only job has
no feature destination at all (`JobIntent.featureDestination` is `nil`), so the
branch that would write it is one the compiler never enters — the same guarantee
the window's "Import Just the Extras" button has, through the same
acknowledgement.

Two things worth knowing about what the app does underneath, because `status`
shows them:

- A **nominal feature title** is selected, and it is not encoded. The pipeline
  resolves a feature index either way, so one is chosen — never a title named as
  an `--extra`, since the extras plan excludes the feature and a collision would
  silently drop one of them. If every scanned title is wanted as an extra, the
  call is refused and says to leave one out for a second pass.
- The **runtime cross-check is skipped**. A bonus title is twelve minutes and
  the film is three hours; comparing them would refuse a selection that is
  exactly right. The check still applies to every ordinary import.

### `import` requires `--disc`, and `eject` distinguishes three outcomes

`import` will not run without `--disc <insertionID>`, taken from `status`. An
agent decides over the course of a scan, an OCR read, a TMDB search and a
library check — minutes, during which a person can swap the disc. Every index it
chose then names a title on a disc that is gone, and the app cannot tell from the
indices, because a different disc's title 1 is also title 1. The insertion token
is minted once per insertion, so it is the only value that can refuse this.

`eject` reports which of three things happened, and the exit code says which:
`ejected` (0), an app refusal such as a running job (4), or a **machine refusal**
(6) — `loginwindow` dissenting the unmount because the screen is locked, the
drive still holding the disc open, or #0049's half-eject where the volume came
down and the tray did not. Exit 6 is recoverable and has nothing to do with this
app; 4 means change what you are asking for.

`--force` on `eject` waives only the running-job refusal, and it waives it by
cancelling the job first rather than ejecting under a live `HandBrakeCLI`.

`--extra-kind` must be one of Plex's eight folder names, spelled exactly. An
unrecognised name is **refused, never corrected to the nearest match** — a
correction would teach an agent that the spelling is forgiving, and the next near
miss would land in a folder Plex scans as a film.

### Taking control — `watch` is the agentic mode

There is no command that switches the app into agent mode, because that would
be a piece of state an agent can crash while holding. Instead:

**For as long as a `watch` session is attached, the app suspends its own
automation.** It will not auto-select a film and it will not auto-start a job.
When the last `watch` session detaches — cleanly, or because the process was
killed, or because the connection dropped — automation resumes by itself.

The thing that suspends the app's decisions is the thing whose death restores
them. That is the whole design: the failure mode where a user's disc sits idle
because an agent died holding a flag cannot occur, since there is no flag.

Two watchers attached and one detaches leaves automation still suspended;
suspension is scoped to the session count, not to a toggle. `status` reports
whether automation is suspended and how many sessions are holding it, so a user
looking at an idle disc can see why.

**One watcher, and everything else brief.** That is the shape to work in: hold
one `watch` open across discs, and let every other command connect, act and
disconnect. Only `watch` and `wait` hold a session at all.

A `wait` running alongside your own watcher is **not** a second agent. It holds
a session — it reads the event stream rather than polling `status`, which would
race the event it is waiting for — but the app knows what the session was opened
for, and a waiting session sustains the agent count without adding to it. The
window says one agent and `automation.heldBySessions` reports 1.

That was a real bug the user caught, not a hypothetical: one agent holding a
watcher and a `wait --for job-done` made the banner say "2 agents" to someone
who could see one working disc. A `wait` on its own still counts, because the
app must not start a job underneath something waiting for a different one.

If you want the literal number of open connections — debugging your own — it is
`app.sessions`, next to `app.clients`. `automation.heldBySessions` is the number
the user is shown.

#### The disc is yours until you eject it

Suspension covers ejecting, too. **While any `watch` session is attached, the
app will not open the tray** — not after a job succeeds, not when it works out
that every film on the disc is already in Plex, and not on the duplicate-edition
path. So the shape of an agent's work on one disc is:

```
changeoverctl watch &                 # attach first, before the disc matters
changeoverctl assets                  # … decide what to take
changeoverctl select … && changeoverctl import …
changeoverctl import … --extras-only  # a second pass off the same disc
changeoverctl eject --disc <id>       # say you are finished with it
```

`eject` is how an agent says it is done. Nothing else will say it on the agent's
behalf while it is attached.

This was decided the other way at first, on the reasoning that opening a tray is
housekeeping with no judgement in it. A session proved otherwise: it imported
The Two Towers, the disc came out the instant the encode finished, and the
extras-only import it had already planned from that same disc had nothing left
to read — the `insertionID` it was holding had gone stale with the disc. Taking
a disc out is a decision whenever something else is mid-plan.

An agent that forgets to eject does not strand the disc. Every eject the guards
held back is reconsidered the moment the last session detaches, by the same
path that resumes auto-start — so a disc whose job finished and whose films are
all in Plex comes out then. And because the session ends when the connection
dies, that includes the case where the agent crashed rather than exited.

An agent that needs the tray open *and* wants to keep watching should call
`eject` explicitly rather than detaching to trigger it: the detach path is a
backstop, and it ejects on the app's reasoning rather than on the agent's.

## Where the files go

**These paths are per-installation and an agent must never guess them.** They
come from `AppSettings`, the user chose them, and they may be a local folder or
a NAS mount. `status --json` reports them under `library`, read from the
running app. `help` prints the conventions and asks the app for the paths when
it can reach it, falling back to the patterns alone when it cannot — the CLI
never reads `UserDefaults` itself, because a second copy of the settings keys
is a second thing that can disagree with the app:

```
mediaRoot   /Volumes/Media/Media
movies      /Volumes/Media/Media/Movies
tvShows     /Volumes/Media/Media/TV Shows
```

The naming convention is strict and Plex depends on it. A film:

```
Movies/Garden State (2004) {tmdb-401}/Garden State (2004).mp4
```

The folder carries the `{tmdb-ID}` tag and the file does not. The tag is what
lets Plex tell apart films that share a title — four films on TMDB are called
*Garden State*, and only the number says which one is in the folder. Different
cuts of one film sit in the same folder as editions rather than in folders of
their own.

Bonus material goes **inside that folder**, in one of the subfolder names Plex
recognises as extras:

```
Movies/Garden State (2004) {tmdb-401}/Behind The Scenes/Making of Garden State.mp4
```

The recognised names are `Behind The Scenes`, `Deleted Scenes`, `Featurettes`,
`Interviews`, `Scenes`, `Shorts`, `Trailers` and `Other`, spelled exactly like
that. The spelling is not cosmetic: Plex excludes these folders from the movie
scan and reads them as the film's extras, so a near miss — `Behind the Scenes`
— is an unrecognised folder, which Plex scans as a film and files as a second
movie with a nonsense name. An agent choosing a subfolder must choose from that
set.

A video that is **not** a recognised extra of a film goes to a separate `Clips`
tree outside the Plex libraries entirely, for exactly the same reason.

TV shows use `TV Shows/Show Name (Year)/Season NN/Show Name - sNNeNN.mp4`.
Changeover does not currently import TV discs — it recognises a season disc and
refuses it rather than filing episodes wrongly — so the path is reported for
completeness and nothing writes there yet.

## Output

Every command takes `--json` and prints one JSON object. `watch --json` prints
one object per line (JSONL), flushed per event. Human-readable output is the
default, because a person debugging this should not have to read JSON — but a
program should never parse the human output. It is allowed to change; the JSON
shape is not, without a version bump.

Exit codes mean something, following the `RemoteControl` prototype:

| Code | Meaning |
|---|---|
| 0 | The thing happened |
| 1 | Usage error — nothing was contacted |
| 2 | Cannot reach the broker — launch agent not registered or not approved |
| 3 | The app is unavailable |
| 4 | The request failed; the reason is in the output |
| 5 | The app ended the session |
| 6 | The app asked and **macOS refused** — recoverable, e.g. a locked screen |
| 7 | `wait` reached its timeout with the condition still false |

6 and 7 were added by #0196 and are additive: a script written against Phase 1
keeps working. Both exist because an agent branches differently on them. 6 says
"ask again later" where 4 says "change what you are asking for", and collapsing
them is what sent six rounds of fixes after a missing entitlement when the cause
was a locked screen. 7 is not a failure of anything — `wait --for job-done
--timeout 7200` leaving with it means the encode is still going.

Every acting verb also reports a stable `outcome` identifier under `action` in
its `--json`, which is what a `case` statement should branch on; `detail` is the
app's own wording and will be reworded.

### `film.chosenBy` — who decided

`status`, every acting verb's reply and the `identification.settled` event all
carry `film.chosenBy`, one of three values:

| Value | Meaning |
|---|---|
| `automation` | The app worked the film out by itself. `film.resolvedBy` says from what — `label`, `menuTitle` or `inference`. |
| `user` | The person at the Mac picked it from the search results. |
| `agent` | A `changeoverctl select` picked it. |

This replaced a boolean `chosenByUser`, which could not express the third case:
an agent's own `select` reported `chosenByUser: false` — exactly what the app
says when it guessed unaided — so an agent could not read its own effect back,
and with two watchers attached neither could tell which of them had chosen.

The same trace found the app side had it backwards and worse. An agent's
`select` reached the flow with the default origin, which is "a person clicked a
row", so the evidence panel a user consults when a wrong film gets filed was
headed *"What the app guessed, and what you chose"* and credited someone who had
never seen the disc. The panel now says *"what the agent chose"*, and marks the
agent's line `⌁` rather than the user's `✎`.

Two related things that tripped this up, worth knowing when reading a snapshot:

- A film's chooser is **final-answer-wins**. A user overriding an agent's pick
  reports `user`, and an agent overriding the user reports `agent`.
- `chosenBy` is correct **before** a job starts. It used to read `automation`
  right up to the moment the rip began, for a user's pick and an agent's alike,
  because the choice was only folded into the identification story at job start.

## What this tool will not do

**It cannot change settings.** There is no `settings set`. An agent that can
repoint the Plex library root or the HandBrake binary from a shell has a blast
radius far larger than anything this is for. Every command here is about one
disc in one drive.

**It cannot overwrite a film silently.** An import that would replace a file
already in the library is refused unless that is explicitly what was asked for.
The extras-only job intent makes this structural rather than careful: for that
intent the feature destination is a value that does not exist, so there is no
branch that could file over the existing film. The CLI routes through that same
intent rather than building a parallel path, because a second path is a second
chance to get it wrong.

**It does not make the app depend on it.** Nothing in the rip flow waits on an
XPC client or behaves differently because one is attached. A disc put in with
no agent watching does exactly what it does today. This matters more than any
feature here: the app's job is to rip discs for a person, and the CLI is an
additional way to reach it, never a component it needs.

## A worked session

Attach, see where things stand, and wait for a disc:

```sh
changeoverctl status --json
changeoverctl wait --for disc-inserted --timeout 600
```

Hold a `watch` session open for the whole job. That is what suspends the app's
own decisions, so it has to be attached **before** the disc is identified, and
has to stay attached until you are finished:

```sh
changeoverctl watch --json > events.jsonl &
WATCHER=$!

changeoverctl wait --for scan-complete --timeout 300
ASSETS=$(changeoverctl assets --json | jq -r .assets.path)
```

The `wait` here runs *alongside* the watcher, which is the intended shape and
not a second agent: the window still says one. Only `watch` and `wait` hold a
session at all — `assets`, `library`, `search`, `select`, `import` and `eject`
each connect, act and disconnect.

Decide. The OCR and the model's answers are in `$ASSETS`; the agent is free to
reason over them in ways the app's own rules do not. Check the library before
committing to an encode that may already exist:

```sh
changeoverctl search "Garden State" --json
changeoverctl library 401 --json
```

Import, watch it, and report:

```sh
DISC=$(changeoverctl status --json | jq -r .status.disc.insertionID)

changeoverctl select --disc "$DISC" --feature-title 1 --movie 401 \
                     --extra 8 --extra-kind "Behind The Scenes" \
                     --extra-label "The Making of Garden State"

JOB=$(changeoverctl import --disc "$DISC" --json | jq -r .action.jobID)
changeoverctl wait --for job-done --job "$JOB" --timeout 7200
changeoverctl report --json
changeoverctl eject --disc "$DISC" || echo "eject returned $? — 6 means macOS refused"
```

`--disc "$DISC"` is required on `import` and checked everywhere it is accepted.
`import` returns as soon as the job starts, with its id, so the `wait` is bound
to that job and not to whatever finishes next.

Then let the watcher go, which hands the app back its own automation:

```sh
kill $WATCHER
```

## Failure modes to expect

**The disc is unreadable.** This is common and it is not a bug in the app.
HandBrake fails with `discUnreadable`, often well into the encode — one disc
failed twice at 49%, thirty minutes in, with no visible damage. `report` names
the reason. Cleaning the disc sometimes fixes it and sometimes does not.

**The menus do not decode.** `structure.json did not decode` means the disc's
menu tables could not be read, so there is no OCR and no model answer — the
identification falls back to the volume label and the runtime alone. An agent
should not treat missing menu assets as an error; plenty of discs are like
this.

**The screen is locked.** `loginwindow` dissents both mounts and unmounts while
a Mac's screen is locked, so an eject can fail for reasons that have nothing to
do with the drive. The failure is recoverable the moment the screen unlocks.

**The on-device model invents things.** Asked to name films on a disc it cannot
read, it answers fluently and wrongly — measured answers include `DREAMSCAPE`
and `DREAMLAND` for a disc holding neither. Everything the model says is
checked against a runtime the disc itself reports before the app acts on it,
and an agent reasoning over `assets` should hold itself to the same standard.
Nothing in the OCR or the model's output is evidence on its own.

## See also

- `docs/menu-intelligence.md` — what the menu read actually extracts, and the
  tiers it goes through.
- `docs/disc-name-inference.md` — how a disc gets a name, and why each rung of
  the ladder exists.
- `docs/foundation-models.md` — the on-device model, and what it may and may
  not decide.
- `docs/eject-and-the-locked-screen.md` — why an eject fails on a locked Mac.
- `/Users/brennan/Developer/brennanMKE/RemoteControl/docs/` — the XPC pattern
  this is built on, written for reuse in another app.
