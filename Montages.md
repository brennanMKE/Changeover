# Changeover — Montages

**Status:** Idea capture — not designed, not scheduled
**Related:** `Plan.md`, `RemoteControl.md`

---

## The idea

Define short clips from favourite movies and play them as continuous montages on
displays around the living space. Loop them. Vary the collection by time of day
and day of week — different mood on a Sunday morning than a Friday night.

Playback targets, in rough order of likelihood:

- A Mac driving a display
- An Apple TV app (tvOS)
- Raspberry Pi–driven displays
- A browser on anything

This is a **second product built on the same media repository** as the DVD
ripping workflow, not a feature of the ripper. Worth keeping the boundary clean
from the start.

---

## Why this fits Changeover

The ripping pipeline already produces exactly what a montage system needs:
a local library of owned video files with known, structured metadata (title,
year, TMDB ID) in predictable paths. Nothing else has to be acquired.

Two pieces of planned work feed it directly:

- **Disc title selection** (`RemoteControl.md` Phase 13.2–13.3) exposes *all*
  titles on a disc, not just the main feature. Bonus features, alternate scenes
  and menu loops become available as clip sources.
- **The remote client codebase** is already a "browse the library, make a
  selection, send it to the host" app. A clip editor is the same shape.

---

## Clip model

**Clips should be non-destructive by default.** A clip is a reference — source
file plus in/out points — not a new video file:

```swift
struct Clip: Codable, Identifiable {
    let id: UUID
    let sourcePath: String        // relative to the media root
    let start: CMTime
    let end: CMTime
    var title: String             // "Lebowski — rug scene"
    var tags: [String]            // ["funny", "dialogue", "90s"]
}

struct Montage: Codable, Identifiable {
    let id: UUID
    var name: String
    var clipIDs: [UUID]
    var shuffle: Bool
    var transition: Transition
}
```

Stored as a sidecar JSON in the media root — never inside the Plex `Movies`
folders, which Plex scans and would be confused by. Something like
`<root>/Montages/library.json`.

Advantages: editing a clip costs nothing, the source stays untouched, and the
whole clip library is a small text file that syncs and version-controls trivially.

### Rendered clips as a second representation

Virtual clips are great for editing and terrible for distribution. A Raspberry Pi
cannot evaluate an `AVComposition`, and neither can a browser.

So: keep virtual clips as the **source of truth**, and *export* a rendered set —
actual short `.mp4` files plus a playlist manifest — for playback clients that
cannot do the seeking themselves. Rendering is an ffmpeg or AVFoundation export,
and can be stream-copy (no re-encode) when cutting on keyframes.

```
<root>/Montages/
  library.json                  ← source of truth: clips, montages, schedule
  rendered/
    friday-night/
      manifest.json             ← ordered list + durations
      001-lebowski-rug.mp4
      002-fifth-element-diva.mp4
      ...
```

This is the common denominator every target can consume.

---

## Playback targets

| Target | Approach | Notes |
|---|---|---|
| **Mac** | `AVPlayer` + `AVQueuePlayer`, or `AVComposition` over virtual clips | Easiest; no rendering needed. Good first target. |
| **tvOS app** | `AVQueuePlayer` reading the rendered manifest over HTTP from the mini | Needs a tvOS target and an Apple TV on the same network. |
| **Raspberry Pi** | `mpv` or VLC in loop mode against the manifest, or a full-screen browser page | Cheap per-display. Pulls rendered clips over HTTP. |
| **Browser** | HTML5 `<video>` playlist page served by the mini | Zero install; also the debugging view. |

**The common requirement is an HTTP surface on the mini** serving rendered clips
and manifests. `RemoteControl.md` also contemplates an HTTP+SSE endpoint as a
web fallback — if both land, they should be one server, not two.

An alternative worth evaluating first: **render each montage as a single long
`.mp4` and let Plex serve it.** Plex already streams to Apple TV and browsers, so
a "Montages" library of pre-rendered loops needs no custom playback client at
all. Much less code; much less flexible (no shuffle, no live schedule changes,
re-render on every edit). Probably the right v1.

---

## Scheduling

Time-of-day and day-of-week rules selecting which montage is active:

```swift
struct ScheduleRule: Codable {
    var montageID: UUID
    var days: Set<Weekday>
    var start: DateComponents      // 18:00
    var end: DateComponents        // 23:00
    var priority: Int
}
```

Open question: does the *host* decide what is playing and push it, or does each
*display* evaluate the schedule itself? Push is simpler to reason about and
makes "change what's on right now" from a phone trivial. Per-display evaluation
survives the mini being asleep. Probably push, with a cached fallback.

Worth considering as inputs beyond time: whether anyone is home, ambient light,
whether the TV is otherwise in use. This edges into Home Assistant territory,
which could drive it rather than Changeover reimplementing it.

---

## Open questions

1. **Same app or separate?** A montage editor has almost nothing in common with a
   ripper except the library. Separate target sharing a package is probably right
   — but the remote client already has the browse-and-select UI to reuse.
2. **Virtual-only, rendered-only, or both?** Determines how much of the above is
   needed. Rendered-only with Plex serving it is by far the cheapest v1.
3. **How are clips marked in the first place?** Scrubbing to find the rug scene
   is the actual work. A good in/out-point UI with keyboard shortcuts and
   thumbnail scrubbing is the difference between this being fun and being a chore.
   This is the feature that decides whether the whole thing gets used.
4. **Audio.** Montages with original audio will be a jarring cut every 20 seconds.
   Music bed with clips muted? Per-clip choice? Affects rendering.
5. **Transitions.** Hard cuts are free; crossfades require real compositing and
   push toward rendering.
6. **Does this need the disc at all?** Clips could be marked from any file in the
   Plex library, regardless of whether Changeover ripped it. That argues for the
   montage tool being library-oriented, not disc-oriented.

---

## Rough sequencing

Nothing here should start before `RemoteControl.md` Phase 13 (the
`JobController` extraction and disc title selection), since that work defines the
library and repository conventions this builds on.

1. Clip data model + sidecar JSON persistence
2. Clip marking UI on the Mac — the make-or-break piece
3. Local playback on the Mac via `AVQueuePlayer`
4. Schedule rules
5. Render + manifest export
6. One remote display target — whichever of Plex-library, tvOS, or Pi proves
   cheapest to validate
7. Remote control of "what's playing now" from phone/tablet, reusing the
   `RemoteControl.md` transport

---

## Note on distribution

The ripping side of this app is intended for general release, and montages would
be too. Two things worth thinking about before that happens, neither of which
blocks personal use:

- Changeover orchestrates MakeMKV and HandBrake but does not itself decrypt
  anything — both are user-installed tools. That separation is worth preserving
  deliberately rather than by accident.
- A montage feature that exports clips from commercial films is a redistribution
  surface in a way that a personal Plex library is not. Keeping everything local
  by default — no sharing, no upload, no cloud — is both the simpler design and
  the safer one.
