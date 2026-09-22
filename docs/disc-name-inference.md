# Turning a disc label into a search term

## The problem, stated exactly

A DVD's volume label is often the movie's title with the spaces knocked out.
`DiscNameSearchTerm.derive` already turns the easy shapes into a search term:

| Volume label | Derived | Why it works |
|---|---|---|
| `ARMY_OF_DARKNESS` | Army of Darkness | underscores are word boundaries |
| `THE_GIRL_IN_THE_SPIDER'S_WEB` | The Girl in the Spider's Web | same, plus minor-word casing |
| `WEIRD_SCIENCE` | Weird Science | same |
| `OPPENHEIMER` | Oppenheimer | one word, and one word is the title |
| `MOVIE_DISC_1` | *(nil)* | generic label, correctly refused |

Every one of those carries its own word boundaries. The failure is the label
that does not:

| Volume label | Derived | What the user does |
|---|---|---|
| `ENEMYATTHEGATES` | Enemyatthegates | TMDB returns nothing; retypes it |
| `THEHANGOVEREXTENDEDCUT` | Thehangoverextendedcut | retypes it |
| `FARGO_WS` | Fargo | *works* — `WS` is stripped junk |

There is no rule list that recovers word boundaries from `ENEMYATTHEGATES`.
Segmenting an unpunctuated string into English words is genuinely ambiguous
(`THERAPIST` → "the rapist" or "therapist"), and the disambiguating knowledge
is "which of these is a film" — which is exactly the kind of thing a language
model has and a lookup table does not.

So: keep the rule ladder as the first answer, and reach for on-device
inference only where the ladder has nothing to say.

## The rule ladder

Modelled on `~/Developer/brennanMKE/Batty/docs/project-name-extraction.md`,
which resolves a project name by walking an explicit priority order and
falling back rather than guessing. The same shape applies here: each tier has
a **detect**, an **extract** and a **fallback**, and the first tier that
produces a term wins.

| Tier | Detect | Extract | Fallback |
|---|---|---|---|
| 1. Separators | label contains `_`, `.`, or spaces | today's `normalize` + junk strip + title case | tier 2 |
| 2. Single word | one word, ≥ 3 chars, not generic | the word, title-cased | tier 3 |
| 3. **Segmentation (new)** | one word, no separators, longer than ~12 chars, not in the lexicon | on-device model proposes word boundaries | tier 4 |
| 4. Menu text | the disc's entry menu printed a title (`MenuTitleGuess`) | that text | nothing prefilled |

Tier 4 already exists and already outranks nothing — today it is only offered
when the volume name gave nothing at all. **It should be consulted before the
model**: a title the disc itself printed on screen is evidence, and a model's
segmentation is a guess. `ENEMYATTHEGATES`'s disc very likely prints "Enemy at
the Gates" on its main menu, and if the menu read got it, no inference is
needed. That reordering is worth doing on its own, independently of any model
work.

## What the model is asked

One question, one sentence, no chain of reasoning:

> Insert word boundaries into this DVD volume label so it reads as a film
> title. Reply with the title only. If it is not a film title, reply with
> NONE.

Input is **only the label**. Not the runtime, not the chapter count, not the
menu OCR — those are separate evidence and mixing them into the prompt makes
a wrong answer harder to attribute.

Structured output, as `MenuJudge` already does: a `GenerationSchema` with a
single string field and greedy sampling, so the answer is a term and not
prose.

## The guardrails, which matter more than the prompt

`MenuJudge` established the pattern and it holds here, with one difference
noted below.

- **It seeds a search box. It never selects a movie.** The result goes where
  `SearchPrefill` already puts the heuristic's term, and `SearchPrefill`
  already refuses to overwrite anything the user has typed. A wrong guess
  costs one glance.
- **The letters must be the label's letters.** The single mechanical check
  worth having: fold both to lowercase alphanumerics and require them to be
  equal. `ENEMYATTHEGATES` → "Enemy at the Gates" passes; → "Enemy at the
  Gate" or "Behind Enemy Lines" is rejected without being shown. This turns
  the model's job into *segmentation*, which it is good at, and forbids
  *recall*, which is where it would confabulate. **This is the whole safety
  argument** — it is a total function of the two strings, testable with no
  model, and no output that fails it can ever reach the user.
- **Unavailable is a normal answer.** No Apple Intelligence, an older macOS,
  a guardrail refusal, a timeout: all mean "no prefill", which is exactly
  today's behaviour.
- **It never blocks anything.** Runs off the main actor after the scan; the
  Start button never waits on it.
- **Only on a label the ladder rejected.** Never to second-guess a term
  tier 1 produced.

The difference from `MenuJudge`: that one produces a *caption* and can change
nothing. This one produces a *search term*, which changes what the user sees
in a text field. The letter-preservation check is what makes that acceptable —
without it, this would need to be a caption too.

## What is collected, so this can be judged

Implemented already, ahead of the model work, because the evidence has to
accumulate before there is anything to evaluate against.

Each rip writes `<archive>/<disc>/naming.json`:

```json
{
  "format": "changeover-disc-naming/1",
  "recordedAt": "2026-09-22T20:31:00Z",
  "volumeName": "ENEMYATTHEGATES",
  "discID": "8a2b1c…",
  "derivedSearchTerm": null,
  "derivedMatchesChoice": false,
  "chosenTitle": "Enemy at the Gates",
  "chosenYear": "2001",
  "tmdbID": "621"
}
```

Written when the rip starts, because the user's choice is the ground truth and
that is when it is made. A retry rewrites the record rather than losing it.
Upgrade jobs skip it — they re-read a disc whose movie was settled long ago.

`derivedMatchesChoice` folds both sides to lowercase alphanumerics before
comparing, so it answers "did the heuristic recover the words" and not "did it
get the spacing right".

The rows worth studying are the ones where `derivedSearchTerm` is `null` or
`derivedMatchesChoice` is `false` beside a real `chosenTitle`. Those are the
discs where the user had to type.

## Sequence

1. **Collect.** (Done.) Every rip from here on leaves a `naming.json`.
2. **Reorder tier 4 above the model.** Prefer a title the disc printed over
   any inference. Small, independent, worth doing regardless.
3. **Count.** After a dozen or two discs, read the archive: how many labels
   did the ladder miss, and how many of those are segmentation problems
   rather than labels with no title in them at all (`MOVIE_DISC_1` is not a
   segmentation problem). **If that number is small, stop here** — this is a
   convenience feature, and the honest outcome may be that the rules already
   cover the discs on these shelves.
4. **Build tier 3** only if step 3 justifies it: `DiscNameInference`, shaped
   like `MenuJudge` — a pure `Question`/`Answer` pair, the letter-preservation
   check as a pure function tested with no model, and the model call behind
   `#if canImport(FoundationModels)`.
5. **Replay.** The archive's labels become the test corpus: run the inference
   over every collected `volumeName` and compare to `chosenTitle`. This is why
   the collection comes first.

## Open questions

- **The length threshold for tier 3.** `OPPENHEIMER` is 11 letters and is one
  word; `ENEMYATTHEGATES` is 15 and is four. There is no clean cut, so the
  cheaper rule may be "tier 2 produced a term, but TMDB returned zero
  results" — i.e. trigger on the search failing rather than on the label
  looking odd. That is a better signal and needs `MovieSearchViewModel` to
  report an empty result set back to the flow.
- **Sequels and editions.** `THEHANGOVEREXTENDEDCUT` segments to "The Hangover
  Extended Cut", which is not a TMDB title. Stripping a trailing edition
  phrase is a rule-list job, not a model job, and belongs in tier 1's junk
  list — but the junk list is currently single words (`WS`, `SE`), so it would
  need to learn phrases.
- **Roman numerals and digits.** `BLOODSPORT2` and `ROCKYIII` are separator-
  free but are not segmentation problems; a digit or numeral boundary is a
  rule, and rules should have first refusal.
