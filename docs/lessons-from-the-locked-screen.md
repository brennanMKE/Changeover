# What a week of wrong answers cost, and what it taught

Written 2026-09-25, after a session that fixed the disc-eject problem, the
disc-*insert* problem, three identification bugs and a USB fault — most of
which had been misdiagnosed at least once, several of them by me (Claude Opus
5, working with Brennan).

This is not a changelog. It is the list of reasoning failures underneath those
fixes, because the fixes are cheap to redo and the habits are not.

## The shape of every mistake

Nearly all of them are the same move: **concluding from documentation, naming,
or a partial signal, when a short test was available and would have answered
definitively.**

The single most expensive example took four minutes to disprove.

## 1. I said headless disc insertion was impossible. Twice.

A disc inserted while a Mac's screen is locked is ejected by `loginwindow`
within half a second. I established that, then said there was no way around
it, then — after being pushed — said it again in stronger terms and wrote it
into a doc as settled.

It was not settled. DiskArbitration ejects are a **vote**: `diskarbitrationd`
polls every process registered for `DADiskEjectApprovalCallback`, and one
dissenter abandons the eject. A forty-line throwaway probe proved it in one
insertion:

```
APPEARED        disk4 volume=PUMP_UP_THE_VOLUME mediaType=DVD-ROM
EJECT REQUESTED disk4 ... -> DISSENTING
drutil:         Type: DVD-ROM  Name: /dev/disk4   (no volume mounted)
```

And `HandBrakeCLI --input /dev/rdisk4` read the unmounted disc perfectly,
label and all.

**What made this bad** is not that I did not know. It is that I had spent
hours *on the receiving end of exactly this mechanism* — every one of the
app's refused ejects was another process dissenting — and never once asked
whether the app could dissent too. The API was in the same header file as the
calls already in use.

> **Lesson.** When something is being done to you by a mechanism, check
> whether you can use that mechanism. Symmetry is free evidence and it is easy
> to miss when you are reading the failure rather than the system.

> **Lesson.** "There is no solution" is a claim about the world, and it needs
> the same standard of evidence as any other. Four minutes of testing beats
> four hours of reading.

## 2. I invented a preference out of `strings` output

Looking for a way to stop the locked-screen block, I ran `strings` on
`loginwindow` and found:

```
DisableScreenLockDiskPolicy
EnableScreenLockDiskPolicy to block disk mounts during screen lock
```

These read exactly like a preference pair, so I told the user to set one with
`sudo defaults write`, and to reboot to make it take effect. **They are
function names.** The log prints `<function> | <message>`, and the same log I
was already reading showed it plainly:

```
-[LWScreenLock startScreenLock:]    | EnableScreenLockDiskPolicy to block disk mounts…
-[LWScreenLock handleUnlockResult:] | DisableScreenLockDiskPolicy
```

`startScreenLock:` calls one; `handleUnlockResult:` calls the other. They are
the *actions*, not switches over them.

The cost was not the wasted key. It was that the reboot dropped the Mac into
the FileVault pre-boot screen, which has no network, so somebody had to walk
to the machine and type a password.

> **Lesson.** A symbol in a binary is evidence that a symbol exists. It is not
> evidence that a preference exists. Before telling anyone to change their
> system configuration, find the thing that *reads* it.

> **Lesson.** Read the log's *format* before interpreting its content. The
> refutation was in output I had already printed twice.

## 3. I recommended weakening a security control

Before the imaginary preference, my first answer was: turn off the screen
lock, or keep the display awake so it never arms. On an unattended machine.
For the convenience of a disc drive.

The user rejected it immediately and was right to. What makes it worse is that
the correct answer — hold the disc, read it unmounted — leaves the lock
entirely intact and was available the whole time.

> **Lesson.** If the fix is "turn off the protection", the problem has not been
> understood yet. Treat that answer as a signal to go back, not as a trade to
> offer.

## 4. I pronounced hardware healthy from the wrong layer

Discs were being ejected with no app running and the screen unlocked. I ran
`drutil status`, got a clean answer with vendor and firmware, and said the
drive was fine.

It was not fine. The kernel log was repeating, every ten seconds:

```
kernel (IOUSBHostFamily) AppleUSBIORequest::complete:
  device 6 (External@02240000) endpoint 0x81:
  status 0xe0005000 (pipe stalled): 0 bytes transferred
```

`drutil` exercises the **control** endpoint. The **bulk** endpoint — the one
that moves data — was dead, so macOS could not read a table of contents and
spat the disc out. The drive was behind three daisy-chained USB 2.0 hubs. The
user removed one and it has worked since.

> **Lesson.** A component answering on one channel says nothing about another.
> Before declaring hardware healthy, look at the layer that actually carries
> the work — for USB, the kernel log, not the CLI tool.

## 5. I diagnosed against builds that did not contain the fix

More than once I explained why something had failed, using logs produced by a
build that predated the change I was explaining. The user asked, fairly, "how
many times have you fixed this now?"

> **Lesson.** State the running build number with every diagnosis. If it
> cannot be stated, the diagnosis is not ready.

## 6. I inverted a design that was already written down

`docs/disc-name-inference.md` specifies the prompt for disc-title inference in
plain terms:

> One question, one sentence… *"Insert word boundaries into this DVD volume
> label so it reads as a film title."* Input is **only the label**. Not the
> runtime, not the chapter count, not the menu OCR — those are separate
> evidence, and mixing them into the prompt makes a wrong answer impossible to
> attribute.

What I built fed the model sixty lines of menu OCR and told it the title is
*"more often implied by a bonus feature, by scene names, or by cast names"*.

On a disc labelled `THESECRETLIFEOFWALTERMITTY` whose menus OCR'd to noise,
the model dutifully inferred from the noise and answered **"The Caretaker"** —
a real 2026 film with an identical 114-minute runtime. Title matched, runtime
matched, auto-selected. With automatic ripping on it would have filed Walter
Mitty in Plex under the wrong film.

The label spelled the answer perfectly. The model was never told to look at it.

> **Lesson.** Re-read the design doc immediately before implementing, not
> months earlier. A spec that is followed from memory is a spec that is
> paraphrased.

> **Lesson.** When a prompt produces a confident wrong answer, suspect the
> instructions before the model. It did what it was told.

## 7. I declared data missing without looking properly

Asked to analyse identification accuracy, I reported that the disc-label →
chosen-film pairs had never been recorded, called it "the real indictment
here", and sent a subagent to reconstruct them from Plex folder names.

They had been recorded all along — 21 files, exactly as asked for, complete
with the TMDB id:

```json
{ "volumeName": "THESECRETLIFEOFWALTERMITTY",
  "chosenTitle": "The Secret Life of Walter Mitty",
  "tmdbID": "116745", "derivedMatchesChoice": false }
```

I had looked for one file at the top level. They are written one per disc.

> **Lesson.** "I could not find it" and "it does not exist" are different
> claims. Check the code that writes a thing before reporting that nothing
> does.

## 8. I nearly shipped a check that would have broken five discs

The fix for "The Caretaker" was to reject a title the disc's label does not
spell. Sound — until the user asked why the Die Hard discs, labelled `WILLIS`,
had always worked.

`WILLIS` is Bruce Willis. Those are box-set discs whose *menus* name the
films. My check would have rejected the correct answer, because
`thewholenineyards` is nowhere inside `willis`. Measured against the corpus,
it would have broken five discs — including `DIE_HARD_3_DISC1`, a perfectly
ordinary title-shaped label whose condensed form misses the correct answer by
one character.

The measured-safe threshold was 9 characters; my guess was 6.

> **Lesson.** A heuristic invented from one failing example is fitted to that
> example. Measure it against every case on hand before shipping it — the
> corpus existed and took one subagent an hour to assemble.

> **Lesson.** When a user asks "why does this other case work?", that is
> usually a counter-example, not a request for reassurance.

## 9. Three bugs from comparing whole structs

`DiscInsertion` gained a field that is filled in *after* the disc is first
seen (an unmounted disc learns its label from its own scan). Three separate
guards compared the whole value to decide "same disc?", and all three broke:
the menu read's result was discarded, the post-job eject stopped firing, and
`discIdentity` silently reported an untouched disc as already ripped.

> **Lesson.** Equality over a struct that accumulates information is a trap.
> Identity should be an identity field — here `insertionID` — and everything
> else is description that may arrive later.

## 10. Swift's `Codable` ignores property defaults

Adding `var occasion: String = "rip"` to an archived record makes the key
**required** on decode. Every one of the 21 existing records would have thrown
`keyNotFound` and become unreadable. The test written to pin backward
compatibility caught it on the first run.

> **Lesson.** For any persisted type, add fields as optional and test decoding
> a payload written by the previous version. An archive exists to be read
> later; orphaning it is the worst available bug.

## 11. I killed a running rip with my own install

The install script checked whether HandBrake was running *before building the
release*, then quit the app several minutes later. A rip auto-started in
between and was destroyed.

> **Lesson.** Put the guard immediately before the destructive step, not at
> the start of the procedure. Time passes.

## The underlying habit

Reading is cheap and feels like progress, so it expands to fill the available
time. Testing feels expensive and usually is not: the eject veto took four
minutes, the USB diagnosis took one log query, and the naming corpus — which
turned "the label mostly works" into "the label carries the title on 18 of 23
discs, and here are the 5 it does not" — took one subagent an hour.

Every hours-long wrong turn in this project ended with a short test that could
have been run at the start.

**Before asserting that something cannot be done, or that a component is
healthy, or that data is missing: name the test that would prove it, and then
run the test.**
