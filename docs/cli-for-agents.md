# Driving Changeover from an AI agent

`changeoverctl` is a command-line tool embedded in Changeover.app. It exists so
a program — in practice Claude Code — can watch a disc go through the app, read
everything the app extracted from it, decide what is worth importing, and say
so. It is not a convenience wrapper over the UI. It is the UI's peer: the same
decisions, reachable from a shell, with the app's answers coming back rather
than disappearing into a window nobody is looking at.

> **Status: being built.** Phase 1 (transport, `ping`, `status`, `watch`,
> `help`) is in progress. Everything below describes the intended surface; a
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
| `changeoverctl import` | Run it. |
| `changeoverctl cancel` | Abort a running job. |
| `changeoverctl eject` | Open the tray. |
| `changeoverctl wait --for <condition> --timeout <sec>` | Block until something happens. |

`wait` exists so an agent does not poll. Polling a disc that takes forty
minutes to encode is both wasteful and badly behaved; one blocking call with a
timeout is what a script wants.

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
| 2 | Cannot reach the broker — launch agent not registered or not approved |
| 3 | The app is unavailable |
| 4 | The request failed; the reason is in the output |
| 5 | The app ended the session |

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

Decide. The OCR and the model's answers are in `$ASSETS`; the agent is free to
reason over them in ways the app's own rules do not. Check the library before
committing to an encode that may already exist:

```sh
changeoverctl search "Garden State" --json
changeoverctl library 401 --json
```

Import, watch it, and report:

```sh
changeoverctl select --feature-title 1 --movie 401 \
                     --extra 8 --extra-kind "Behind The Scenes" \
                     --extra-label "The Making of Garden State"
changeoverctl import
changeoverctl wait --for job-done --timeout 7200
changeoverctl report --json
changeoverctl eject
```

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
