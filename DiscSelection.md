# Changeover — Disc Title Selection

**Experiment run:** 2026-09-11 · 7 DVDs on `joe` (Mac mini M1, MakeMKV v1.18.4)
**Fixtures:** `ChangeoverTests/Fixtures/makemkvcon/` — 14,175 lines across 13 files
**Related:** `Roadmap.md` Phase 2 · `RemoteControl.md` · `Montages.md` · issues `0020`–`0030`

---

## Why this experiment existed

DVD authoring deliberately obscures which title is the real movie. The manual
workaround is to open MakeMKV.app, eyeball the list, and pick the biggest title.
The question was whether that judgement could be automated — by heuristics, or
failing that, by a local LLM scoring the structured title list.

The answer turned out to be simpler than either. But the more valuable output was
seven captured fixtures that disproved four things the plan had asserted from
documentation.

---

## Result: one rule, 7/7

**Scan once at an explicit minimum title length. The movie is the only title
longer than 45 minutes.**

| disc | titles (`min0`) | titles (default) | ≥45min | main idx | chapters | duration | size |
|---|---|---|---|---|---|---|---|
| Weird Science | 11 | — | **1** | 0 | 18 | 1:33:22 | 5.8 GB |
| The Girl With The Dragon Tattoo | 5 | — | **1** | 0 | 16 | 2:37:51 | 6.9 GB |
| The Girl in the Spider's Web | 26 | 5 | **1** | 0 | 16 | 1:55:11 | 5.4 GB |
| Hornets' Nest | 10 | 4 | **1** | **9** | 16 | 2:26:47 | 5.6 GB |
| Hanna | 16 | 8 | **1** | **3** | 21 | 1:50:45 | 6.3 GB |
| Super Troopers | 22 | 9 | **1** | 0 | 21 | 1:39:47 | 5.0 GB |
| Super Troopers 2 | 35 | 7 | **1** | 0 | 25 | 1:39:15 | 5.0 GB |

Every disc: exactly one feature-length title, out of 5 to 35 total.

### Heuristic scorecard

| rule | score | verdict |
|---|---|---|
| **exactly one title ≥ 45 min** | **7/7** | ✅ adopt |
| largest title | 7/7 | redundant with the above |
| most chapters | 7/7 | redundant, but a good cross-check |
| duration matches TMDB runtime | 7/7 | keep for the 2+ fallback and remake disambiguation |
| **first title (index 0)** | **5/7** | ❌ never assume |

**No LLM is warranted.** The problem has one numeric feature and a threshold.
A local model via LM Studio would be non-deterministic, slower, and could
hallucinate a title index, for a decision that a comparison resolves exactly.
Use the fixtures to test one offline if curiosity demands, but not in the app.

### Why the runtime check still earns its place

It is not needed to find the title, but it does two things a threshold cannot:

- **Disambiguates remakes.** *The Girl With The Dragon Tattoo* exists as a 2009
  Swedish film (152 min) and a 2011 Fincher film (158 min). The disc's title ran
  2:37:51 — 157.9 min — identifying *which film* the disc is, not merely which
  title. This is the same ambiguity the `{tmdb-ID}` folder convention exists to
  resolve, answered from the same signal.
- **Breaks the 2+ tie.** When a disc carries both a theatrical and an extended
  cut, runtime is what distinguishes them.

Note `TMDBClient` only calls `/search/movie` today, which does **not** return
`runtime`. A `/movie/{id}` fetch is required. PAL transfers also run ~4% fast, so
any tolerance must accommodate that.

---

## Four things the fixtures disproved

Each of these was asserted in the plan from documentation or reasoning, and each
is wrong. They are the real return on the experiment.

### 1. Title indices are not stable across `--minlength` — and the filenames collide too

MakeMKV assigns title indices **after** applying the minimum-length filter. The
same index means different titles at different thresholds. On Hanna:

```
D1_t01.mkv   at --minlength=0      0:00:13     11.6 MB
D1_t01.mkv   at default (120s)     1:50:45      6.3 GB
```

**Identical output filename, 543× size difference, same disc.** Ticket `0028`
planned to verify a rip by checking the expected filename from attribute 27 —
that check is defeated here, because the filename matches while the content is
entirely wrong.

The destructive direction was demonstrated on Hornets' Nest:

```
scan at default → user picks idx 3 → 2:26:47, the movie
rip  at min0    →      idx 3       → 0:01:32, a clip
```

`makemkvcon` exits 0 either way.

**Rules:** pass one explicit `--minlength` to both scan and rip — never inherit
the default. Never mix indices from two scans. Verify the rip by **duration**,
never by filename. Note `MSG:3025` carries the effective threshold as a
parameter (`"2","5","120"`), so the app can read it rather than assume it.

### 2. Exit status decides success — error text does not

Two discs produced genuine error output inside a scan that exited 0 and reported
`MSG:5011 "Operation successfully completed"`:

```
MSG:2003  "Scsi error - ILLEGAL REQUEST:READ OF SCRAMBLED SECTOR WITHOUT
           AUTHENTICATION ... at offset '1048576'"          (bootleg disc)
MSG:4004  "The source file '/VIDEO_TS/VTS_01_1.VOB' is corrupt or invalid
           at offset 104448"  × 28                          (damaged disc)
```

Tickets `0009` and `0024` plan to classify failures by text-matching output.
That would fail both discs. **Exit status decides; MSG codes explain.** A
successful scan carrying `MSG:4004` should still surface a warning — "28 read
errors during scan" — because the resulting rip may be silently corrupt.

### 3. Language tags are optional

Hornets' Nest carries **no language attribute at all** on any stream — two
identical `DD Surround 5.1` audio tracks and one untagged VOBSUB. A preference
filter of `["eng","spa"]` matches nothing and would drop every audio track,
producing a silent MP4.

**Rule:** if no stream on the title carries a language tag, keep everything.

### 4. Not every subtitle is a bitmap

Ticket `0029` recommended deferring subtitle support because DVD subtitles are
VOBSUB bitmaps that MP4 cannot carry as selectable tracks. True for most — but
two discs carried a `S_CC608/DVD` stream that MakeMKV converts to **text**:

```
SINFO:0,10,5,0,"S_CC608/DVD"
SINFO:0,10,30,0,"CC→Text English ( Lossy conversion )"
```

Text subtitles can go into MP4. The blanket deferral is too broad — bitmap subs
are genuinely blocked, CC608-derived text ones are not.

---

## The attribute table, verified

MakeMKV's published `usage.txt` is **wrong about its own output format**. It
prints `TINFO:id,code,value` and `TCOUT:count`; real output is:

```
DRV:index,visible,enabled,flags,drive name,disc name,device path
TCOUNT:count                            ← not TCOUT
CINFO:id,code,value
TINFO:title,id,code,value               ← extra leading field
SINFO:title,stream,id,code,value        ← two extra leading fields
```

`id` is the attribute; `code` is a message code for a localized display name.
Transposing them is the easy mistake.

The attribute ids below were confirmed against an independent oracle — the
MakeMKV.app Info panel, which is a direct rendering of them:

| GUI field | attr | example |
|---|---|---|
| Name | 2 | `Girl in the Spider's Web, The` |
| Chapters count | **8** | `16` |
| Duration | **9** | `1:55:11` |
| Size | 10 | `5.4 GB` |
| Size (bytes) | **11** | `5848889344` |
| Source title ID | 24 | `01` |
| Segment count | 25 | `1` |
| Segment map | 26 | `1-17` |
| File name | **27** | `…-B1_t00.mkv` |
| — | 28 | `eng` |
| (row label) | 30 | `… - 16 chapter(s) , 5.4 GB (B1)` |
| Comment | 49 | `B1` |

Stream attributes (`SINFO`):

| meaning | attr | example |
|---|---|---|
| stream type | 1 | `Video` / `Audio` / `Subtitles` |
| language code | **3** | `eng` (absent on some discs — see finding 3) |
| language name | 4 | `English` |
| codec id | **5** | `A_AC3`, `S_VOBSUB`, `S_CC608/DVD` |
| bitrate | 13 | `448 Kb/s` |
| resolution | 19 | `720x480` |
| **flags** | **22** | `4096` = forced subtitle |
| display name | 30 | `DD Surround 5.1 English` |
| default flag | 38/39 | `d` / `Default` |

**Attribute 22 is how to detect forced subtitles** — not by string-matching
`"(forced only)"` out of attribute 30. Forced subs are the one subtitle class
worth keeping for a Plex movie: they caption foreign dialogue in an otherwise
English film.

---

## MSG codes observed

```
1005 started              3010 (progress/info)      3038 cells removed from title end
1009 profile parse error  3025 title below minimum length (carries the threshold)
2003 scsi/scramble error  3026 fake title detected — declared length 0:00:00
2010 drive opened         3027 title equal to another, skipped
3007 direct disc access   3028 title added
4004 source file corrupt  5011 operation successfully completed
5021 key expired / version too old  (exit 253)
```

**MakeMKV already detects the decoy problem.** `MSG:3026` ("assuming fake
title") and `MSG:3027` ("equal to title #26 and was skipped") mean the
obfuscation-detection work is upstream and free — read these rather than
reimplementing them.

---

## What this changes in the plan

### Phase 2 gets smaller

| ticket | change |
|---|---|
| `0021` | largely **done** — attribute table verified, 7 fixtures captured |
| `0025` main-feature heuristic | collapses to a threshold + count; no scoring engine |
| `0026` title list UI | shrinks to a confirmation row; the picker becomes the 2+ fallback and the extras opt-in |
| `0027` | multi-title selection for *finding the movie* drops; language selection stays and gets harder (see below) |
| `0028` | rip one index; **verify by duration, not filename** |
| `0029` | revisit — CC608 text subtitles are not blocked by MP4 |

### The fallbacks now carry the design

- **0 titles ≥45min** — not a movie disc, or a very short feature. Ask. This is
  also how a TV-on-DVD identifies itself (episodes run 22–45 min), which is the
  escape hatch the roadmap wanted rather than a confident wrong answer.
- **2+ titles ≥45min** — theatrical vs extended cut, or seamless branching.
  Disambiguate by TMDB runtime, then show the picker. **This case never occurred
  in 7 discs and remains untested.** A Disney disc or a director's-cut edition is
  the most likely source.

### Audio selection is the remaining hard problem

Title selection turned out easy; track selection did not. Every multi-track disc
carried duplicates that language alone cannot separate:

```
Hanna           s4, s5   both "DD Stereo English"    192 Kb/s   identical
Dragon Tattoo   s1, s3   both "DD Surround 5.1 English" 448 Kb/s
Super Troopers 2  s1, s2  English 5.1 at 448 and 384 Kb/s  — likely commentary
Spider's Web    3 English subtitle tracks, 5 Chinese
```

Deduplication by `(language, codec, bitrate, display name)` is required, and
commentary detection is genuinely unsolved — a commentary track is the same
language and often the same codec as the feature audio. Worth checking whether
attribute 22 or 38/39 distinguishes them before inventing heuristics.

---

## Capture tooling

`Tools/capture-disc.sh` — scans the disc in the drive on the rip host, saves both
`--minlength=0` and default fixtures, and prints the title table, the index-shift
diff, the stream list, and MSG code counts. One command per disc.

Host is `joe` by default (`CHANGEOVER_HOST` to override); tools resolve at
`/opt/homebrew/bin` (`CHANGEOVER_REMOTE_PATH`).

> Note: non-interactive `ssh` does not include `/opt/homebrew/bin` on `PATH`.
> Any tool detection that relies on `PATH` rather than probing absolute
> candidates will report a correctly-configured machine as broken — the exact
> readiness bug tickets `0104`/`0105` describe.

---

## Still wanted

- **A disc with two feature-length titles.** The only untested branch.
- **A Disney/Pixar disc.** The canonical structural-obfuscation case.
- **A TV season disc.** Should return 0 titles ≥45min and prove the escape hatch.
- **Anything under 45 minutes that is a movie.** Would falsify the threshold;
  animated features run ~70 min, so the margin is real but worth probing.
