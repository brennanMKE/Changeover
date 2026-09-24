# Auditing the library, and fixing what is already in it

Plan only. Nothing here is built.

## What this is for

Two discs of The Jackal are one film with two cuts, and Changeover now knows
that (`{edition-…}`, `docs/…` and `DiscEdition`). But the library already
holds imports made before it knew: **The Hangover is a special edition filed
as the ordinary release**, and there will be others nobody has noticed.

The tell is runtime. A file whose duration is well off TMDB's listing is
either a different cut, or a mistake — and both are worth knowing. So:

1. list every import whose duration does not match TMDB's,
2. say what each one most likely is,
3. and fix it **without re-ripping**, because the fix is usually a rename.

That last point is what makes this worth building. Tagging a file
`{edition-Special Edition}` and asking Plex to refresh costs a second. Re-
ripping The Hangover costs forty minutes and a trip to the shelf.

## Where the data comes from

Plex, not the filesystem.

One request per library section returns every item with its duration, its
`{tmdb-…}` guid, its file path and its size. That is the whole audit in two
round trips. The alternative — `ffprobe` over every file — is minutes of disk
I/O for the same numbers Plex already has indexed, and Changeover has no
reason to open those files.

Curator already does exactly this read (`Curator/Plex/PlexClient.swift`, ~500
lines including models). Changeover has none of it: it talks to Plex only to
trigger a refresh and an analyze, using the token from
`defaults read com.plexapp.plexmediaserver PlexOnlineToken`.

**Copy the read path, do not share a package yet.** A shared Swift package
across two apps is the right end state and the wrong first step: it turns a
contained feature into a refactor of two shipping apps. Copy the subset —
sections, items, durations, guids, paths — and extract later if a third
caller appears.

## The comparison

For each movie in the library:

| Source | Value |
|---|---|
| Plex | `duration` in ms, `guid` → tmdb id, file name, file size |
| TMDB | `runtime` in minutes, for that id |

Compare with `RuntimeCrossCheck`'s existing tolerance — 6% plus 60 seconds —
which exists because a PAL transfer runs about 4% fast and two cuts less than
eight minutes apart are not separable by runtime at all. Reusing it means the
audit and the rip agree about what "close enough" means, rather than growing
a second opinion.

**Direction matters more than magnitude**, and this is the part a naive
report gets wrong:

| Shape | Most likely cause | Suggested fix |
|---|---|---|
| Longer than TMDB, by 2–30 min | extended / special / director's cut | tag `{edition-…}` |
| Longer by a lot (2×+) | a Play All title was ripped, not the feature | re-rip, pick the feature |
| Shorter by ~4% | PAL transfer | nothing — already inside tolerance |
| Shorter by a lot | wrong title ripped, or a damaged read | re-rip |
| Any direction, title clearly different | the wrong film was selected | re-match, rename folder |

A report that only sorted by "most wrong" would put the PAL discs and the
genuinely broken imports next to each other. The shape is the finding.

## What the user does with it

A list, and one button per row. The buttons are the point; a read-only report
would just be a list of chores.

- **Tag as an edition** — rename the file to add `{edition-…}`, then ask Plex
  to refresh that section. No re-rip. This is the common case and the one The
  Hangover needs.
- **Change the film** — search TMDB and re-point the import at a different
  id. This is the fix for an import matched to the wrong film, which a
  runtime mismatch is often the first sign of, and it is a bigger operation
  than tagging an edition: the `{tmdb-…}` tag lives on the **folder**, so the
  folder is renamed and the file inside it with it. The search UI is the one
  already in the rip flow (`ChooseMovieStepView`), pointed at an existing
  import rather than a disc — which is most of why this is worth building on
  the same code rather than beside it.
- **Reveal in Finder** — for anything the app should not decide.
- **Re-rip** — hand it to the existing flow with the movie pre-selected, so
  the disc goes in and everything else is already known.

Renaming a **file** is the safe kind of destructive: the bytes are untouched,
the folder does not move, and Plex re-reads it in place. Renaming a **folder**
— which changing the TMDB id requires — is a bigger claim, because Plex loses
and re-creates the library item, and anything attached to it (watched state,
ratings, collections) goes with it. Worth saying out loud in the UI rather
than discovering afterwards.

Either way it wants the same care `PlexOrganizer` takes — refuse if the
destination name already exists, and never rename a file Plex is currently
playing.

## Where it lives in the app

A window, not a step in the rip flow. The rip flow is about the disc in the
drive; this is about everything already imported, and wedging it into the
five-step flow would make both worse.

Reachable from the menu bar item, beside History. Off the critical path: it
touches nothing the rip does, and with the Plex server unreachable it shows
that and nothing else.

## Sequencing

0. **Re-pointing an import at a different TMDB id** is part of this, not a
   follow-on. An import whose runtime is wrong is as likely to be the wrong
   film as the wrong cut, and a tool that can only say "tag this as an
   edition" would file a misidentified import under a cut of a film it is
   not. The two fixes are the same gesture from the user's side — *this is
   actually X* — and differ only in whether the folder moves.

1. **The read.** Plex sections → items with duration, guid, path. No UI.
   Provable against joe's real library from a test tool before any view
   exists.
2. **The comparison.** Pure, over plain values, with the shape table above as
   its cases. Unit-tested with no server and no network — this is where the
   PAL case and the Play All case are pinned.
3. **The list.** Read-only first. Look at what it says about a real library of
   ~100 films before building any button, because the shape of the real
   answer decides which buttons are worth having.
4. **The rename.** With its own confirmation, and refusing anything ambiguous.
5. **Re-rip hand-off**, if the list shows enough of them to be worth it.

Step 3 is a deliberate stop. The interesting question — how many of these are
editions, how many are mistakes, how many are TMDB being wrong — is
unanswerable until the list exists, and the answer decides whether steps 4
and 5 are one afternoon or a week.

## Open questions

- **Does Plex's `duration` match the file?** It is what Plex analyzed, and an
  unanalyzed item can carry the *metadata* runtime instead — which would make
  a file look correct when it is not. Worth checking against `ffprobe` on a
  handful before trusting it wholesale.
- **TV.** The same mismatch exists per episode and the fix is different. Out
  of scope until movies are done.
- **Rate limits.** One TMDB request per distinct film. About 100 films is
  fine; a 2,000-film library needs caching, and the naming archive
  (`naming.json`) is already a place to put it.
- **The `{edition-Theatrical}` question.** Plex shows an untagged file as an
  unnamed default beside a named one. Once a second cut exists, tagging the
  first as Theatrical reads better — but it means renaming a file that was
  never wrong, which is a bigger claim than tagging one that was.
