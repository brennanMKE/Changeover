# Testing `changeoverctl` with an AI agent

For a Claude Code session driving Changeover on **joe** through the new
command-line tool. Phase 1 shipped the transport and three read-only commands;
nothing here can start, cancel, eject or import, because those verbs are not
built yet.

The point of this round is not to prove the commands print something. It is to
find out whether an agent attached to a real disc **gets what it needs, when it
needs it**, and whether the automation handoff behaves when things go wrong.

## Before you start

```sh
C=/Applications/Changeover.app/Contents/Resources/bin/changeoverctl
"$C" --version          # expect: changeoverctl 0.1.3-pre1 (20261004013349) or newer
"$C" ping               # expect: broker pid …, app endpoint registered
```

`ping` is the highest-value diagnostic. It talks only to the broker launch
agent, never to the app. **If `ping` fails, nothing app-side is worth
investigating yet** — exit 2 means the launch agent is not registered or not
approved, and every other command will fail the same way.

There is no `/usr/local/bin` symlink yet; the full path is the only way in.

### What this tool can and cannot do to the Mac

Everything in Phase 1 **observes**. `status` and `watch` read; neither can
change what the app does — with one deliberate exception, which is the whole
reason for this test:

> **While a `watch` session is attached, the app suspends its own automation.**
> It will not auto-select a film and it will not auto-start a job. When the last
> watcher detaches — cleanly, killed, or crashed — automation resumes by itself.

So an attached watcher *is* the agentic mode. That is the behaviour most worth
breaking on purpose below.

## What to record

For each scenario: what you ran, the exit code, the output (JSON where there is
a `--json`), and whether it matched. **When something is wrong, prefer the
actual bytes over a description** — a pasted JSON object is worth more than
"status looked right".

Three sources of truth beyond the CLI itself:

| Where | What it tells you |
|---|---|
| `~/Library/Application Support/Changeover/flow.log` | The app's own decision trail, written whether or not anyone is watching |
| `/usr/bin/log stream --predicate 'subsystem == "co.sstools.Changeover"'` | The bridge's own logging, app and broker both. **Use the absolute path — `log` is a zsh builtin** |
| `~/Library/Logs/Changeover/disc-reliability.jsonl` | One line per finished job, including why a disc failed |

## Scenarios

### 1. Status with an empty drive

```sh
"$C" status
"$C" status --json | jq .
```

**Expect:** exit 0. `disc` absent from the JSON entirely (not `null`-filled),
`start.decision == "noDisc"`, `automation.suspended == false`, and a `library`
block carrying this installation's real paths — `/Volumes/Media/Media` and its
Movies and TV Shows folders — plus the eight Plex extras folder names.
**There is no Clips path**: #0192 retired that folder, and an extra
nothing named is now filed under `Other` inside the film's own folder
rather than in a tree Plex never scans.

**Why it matters:** an agent cannot guess those paths, and they differ per
installation. If `library` is missing or wrong, nothing downstream can file
anything correctly.

### 2. Attach a watcher, then insert a disc

```sh
"$C" watch --json > /tmp/watch.jsonl &
WATCHER=$!
sleep 2
"$C" status --json | jq .status.automation
# now put a disc in
```

**Expect:** `automation` reports `suspended: true, heldBySessions: 1`. The
first line of `/tmp/watch.jsonl` is `session.attached` **carrying the complete
status snapshot**, then `disc.inserted`, `scan.finished`, and
`identification.settled` as the app works.

**And the thing to actually watch for: the app must NOT start a job on its
own.** Normally it would auto-select the film and begin encoding. With a
watcher attached it should identify the disc and then stop, waiting.

If it starts encoding anyway, that is the most important bug this round can
find — stop and report it.

### 3. Does an agent get enough to decide?

With the disc identified and the watcher still attached:

```sh
"$C" status --json | jq '.status | {film, scan, start, flow}'
```

**The real question is a judgement, not an assertion.** Read it as an agent
would: could you decide what to import from this alone? Specifically —

- Does `film` name the disc's film with a TMDB id you could act on?
- Does `scan` tell you how many titles there are and which is the feature?
- Does `start` tell you whether you *could* start and, if not, **why** —
  without parsing prose? (`start.decision` is the machine-readable one;
  `reason` and `plainReason` are for humans.)
- Is anything you would obviously need simply absent?

Phase 2 adds `assets`, `library`, `search` and `report`. **Note what you
reached for and could not get** — that list is the most valuable output of this
whole exercise, more than any pass or fail above.

### 4. Detach, and watch automation come back

```sh
kill -INT $WATCHER       # clean Ctrl-C equivalent
sleep 2
"$C" status --json | jq .status.automation
```

**Expect:** `suspended: false`, `heldBySessions: 0`, and the app resumes its
own behaviour — with a disc still in the drive it may now auto-select and start
a job on its own. That is correct: you handed control back.

### 5. The failure that matters — kill the watcher outright

```sh
"$C" watch --json > /tmp/watch2.jsonl &
W=$!
sleep 3
"$C" status --json | jq .status.automation    # suspended: true
kill -9 $W                                    # no clean detach, no goodbye
sleep 3
"$C" status --json | jq .status.automation    # MUST be suspended: false
```

**This is the single most important scenario here.** An agent that crashes
while holding the app's automation suspended would leave the user's next disc
sitting there doing nothing, with no explanation and nothing on screen to
suggest why. The design claims that cannot happen, because the thing that
suspends automation is the thing whose death restores it — the app reaps the
session when the connection invalidates.

If `suspended` is still `true` after a `kill -9`, **the design does not hold**
and that outranks every other finding.

### 6. Two watchers

```sh
"$C" watch > /tmp/a.log & A=$!
"$C" watch > /tmp/b.log & B=$!
sleep 2
"$C" status --json | jq .status.automation    # heldBySessions: 2
kill -INT $A; sleep 2
"$C" status --json | jq .status.automation    # still suspended, heldBySessions: 1
kill -INT $B; sleep 2
"$C" status --json | jq .status.automation    # suspended: false
```

**Expect:** suspension is scoped to the session *count*, not a toggle. One
watcher leaving while another is attached must not hand control back.

### 7. The app quits while a watcher is attached

```sh
"$C" watch & W=$!
sleep 2
osascript -e 'tell application "Changeover" to quit'
wait $W; echo "exit $?"
```

**Expect:** the watcher reports the session ended and exits **5**. No hang.

### 8. The broker is restarted underneath

```sh
"$C" watch & W=$!
sleep 2
launchctl kickstart -k "gui/$UID/co.sstools.Changeover.broker"
sleep 3
"$C" status | grep -i broker
```

**Expect:** the attached watcher is undisturbed and `status` still works
without relaunching the app. The broker hands over the endpoint once and is
**not in the data path** afterwards, so restarting it should be invisible to an
established session. The app should log re-registering.

### 9. Watch a real import end to end

Detach every watcher, let the app start a job by itself, then attach:

```sh
"$C" watch --json | jq -r '[.event.kind, .event.summary] | @tsv'
```

**Expect:** `session.attached` first with the whole snapshot — this is what
lets an agent join part-way through and know where it is — then `job.phase`
and `job.progress` as the encode runs, progress throttled to whole percentage
points, and `job.finished` at the end.

**Judgement call:** is the event stream enough to follow a job without polling
`status`? If you find yourself calling `status` after every event, say so —
events are meant to be self-describing and carry the parts of the snapshot
their kind makes relevant.

### 10. Error paths

```sh
"$C" bogus;            echo "exit $?"   # 1, usage
"$C" status --no-launch                 # 3 if the app is not running
"$C" ping --no-launch; echo "exit $?"   # 1 — nothing to launch, so it is a usage error
"$C" status --timeout 1                 # exit 3 if the app cannot answer in time
```

**Expect:** every one of these emits a JSON object under `--json`, including
the failures. A command that errors without parseable output is a bug — the
tool's contract is that `--json` is total.

### 11. The disc stays in while you are holding it

#0199, and the scenario that produced it: an agent imported a film, the app
ejected the disc on its own, and the extras-only pass the agent had planned off
that same disc found its `insertionID` stale.

With a disc in the drive whose film the library already has — the easiest way
to reach an eject the app decides on by itself — and no watcher attached, the
app ejects it. Now do it with one attached:

```sh
"$C" watch --json | jq -r '[.event.kind, .event.summary] | @tsv' &
# … insert that same disc, or run an import to completion
"$C" status --json | jq '{ejecting: .disc.isEjecting, disc: .disc.insertionID}'
```

**Expect:** the disc stays mounted. No `disc.ejected` event, and `status` keeps
reporting the same `insertionID` — which is the thing that has to hold, because
it is what a follow-up `import` is keyed on. This covers all three of the app's
own eject paths: after a job, every-film-already-in-Plex, and duplicate edition.

Then ask for it:

```sh
"$C" eject --disc "$(…)"
```

**Expect:** the tray opens, an `agent.action` event names the eject, and
`disc.ejected` follows.

Finally the backstop — kill the watcher with the disc still in, without
ejecting:

```sh
kill -9 %1
```

**Expect:** the disc comes out by itself within a few seconds. An agent that
dies mid-plan must not leave a disc trapped, so the hold is released by the
same path that resumes auto-start.

**Judgement call:** did anything eject a disc you had not finished with? That
is the bug this scenario exists to catch, and it is worth reporting even if the
sequence above passes.

## Known gaps — do not report these as bugs

- **No `/usr/local/bin` symlink.** The installer did not port: Changeover is a
  menu-bar app with no menu bar to hang a File ▸ Install action on. Open design
  question.
- **A development build has no bridge at all.** Registration is deliberately
  gated on running from `/Applications`, because a login item pointing into
  DerivedData once wedged this Mac badly enough to need a reboot. Only the
  installed copy has a working CLI.
- **TV show paths are reported but nothing writes there.** The app recognises a
  season disc and refuses it rather than filing episodes wrongly.

## What a good report back looks like

1. **Which scenarios failed, with the bytes.** Exit codes and raw JSON.
2. **Scenario 5's result, stated explicitly**, pass or fail. It is the one that
   decides whether the automation design survives.
3. **What you reached for and could not get.** The commands Phase 2 should
   build, in the order an agent actually wanted them.
4. **Where the JSON was awkward to consume.** Shapes that needed unwrapping,
   fields that should have been there, anything that forced a second call.
5. **Anything the app did that surprised you**, including on screen — this
   session is also the first time a person watches the UI while something else
   holds its automation.

## See also

- `docs/cli-for-agents.md` — the surface and the model an agent should hold.
- `CLAUDE.md` — project rules. **Never run the UI tests**; that is not
  negotiable and has nothing to do with this tool.
- `/Users/brennan/Developer/brennanMKE/RemoteControl/README.md` — the prototype
  this transport is lifted from, whose manual test script is the ancestor of
  scenarios 5 through 8.
