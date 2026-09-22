# Turning a disc label into a search term

Follows the house rules in `~/Developer/brennanMKE/Batty/docs/foundation-models.md`
— protocol, factory, sanitize, settings toggle, no model in unit tests.
Deviations from that document are called out where they occur.

## The problem, stated exactly

A DVD's volume label is often the movie's title with the spaces knocked out.
`DiscNameSearchTerm.derive` already turns the easy shapes into a search term:

| Volume label | Derived | Why it works |
|---|---|---|
| `ARMY_OF_DARKNESS` | Army of Darkness | underscores are word boundaries |
| `THE_GIRL_IN_THE_SPIDER'S_WEB` | The Girl in the Spider's Web | same, plus minor-word casing |
| `OPPENHEIMER` | Oppenheimer | one word, and one word is the title |
| `FARGO_WS` | Fargo | `WS` is stripped as trailing junk |
| `MOVIE_DISC_1` | *(nil)* | generic label, correctly refused |

Every one carries its own word boundaries. The failure is the label that does
not:

| Volume label | Derived | What the user does |
|---|---|---|
| `ENEMYATTHEGATES` | Enemyatthegates | TMDB returns nothing; retypes it |
| `THEHANGOVEREXTENDEDCUT` | Thehangoverextendedcut | retypes it |

No rule list recovers word boundaries from `ENEMYATTHEGATES`. Segmenting an
unpunctuated string is genuinely ambiguous (`THERAPIST` → "the rapist" or
"therapist"), and the disambiguating knowledge is "which of these is a film" —
the kind of thing a language model has and a lookup table does not.

## The rule ladder

Shaped like Batty's `project-name-extraction.md`: an explicit priority order,
each tier with a detect, an extract and a fallback, first tier to produce a
term wins. This is the "show the deterministic result first" rule made
concrete — the model is the last tier, never a second opinion on an earlier
one.

| Tier | Detect | Extract | Fallback |
|---|---|---|---|
| 1. Separators | label contains `_`, `.`, or spaces | today's `normalize` + junk strip + title case | tier 2 |
| 2. Single word | one word, ≥ 3 chars, not generic | the word, title-cased | tier 3 |
| 3. **Menu text** | the disc's entry menu printed a title (`MenuTitleGuess`) | that text | tier 4 |
| 4. **Segmentation (new)** | tiers 1–3 gave a term that found nothing on TMDB | on-device model proposes word boundaries | nothing prefilled |

**Tier 3 moves above the model.** `MenuTitleGuess` exists and is currently
consulted only when the volume name gave nothing at all. A title the disc
itself printed on screen is evidence; a segmentation is a guess. If the menu
read already OCR'd "Enemy at the Gates" off the main menu, no inference is
needed. This reordering is worth doing on its own, before any model work.

**Tier 4 triggers on the search failing, not on the label looking odd.** The
alternative — a length threshold — has no clean cut (`OPPENHEIMER` is 11
letters and is one word; `ENEMYATTHEGATES` is 15 and is four). "TMDB returned
zero results" is the real signal and needs `MovieSearchViewModel` to report an
empty result set back to the flow.

## Shape

Per Batty's rules, and unlike Changeover's existing `MenuJudge`, which is a
bare static func:

```swift
protocol DiscNameSegmenting: Sendable {
    func segment(label: String) async -> String?   // nil = no answer
}
```

- `FoundationModelsDiscNameSegmenter.makeIfAvailable()` returns `nil` when the
  framework is absent. `AppDelegate` wires the result into the flow; `nil`
  turns the feature off for the process.
- `import FoundationModels` stays inside `#if canImport(FoundationModels)`,
  and the Foundation Models types stay confined to that one file.
- A fresh `LanguageModelSession` per request — no shared context.
- **Never throws to the caller.** `nil` for "no answer", with the reason
  logged to a `DiscNameSegmenter` log category.

**Deviation from Batty:** its OS gate exists because Batty deploys to macOS
15.6 and Foundation Models needs 26. Changeover's deployment target is already
26.2, so the `@available(macOS 26.0, *)` layer is not load-bearing here.
`SystemLanguageModel.default.availability` still has to be checked **on every
call** — that is what covers Apple Intelligence being switched off or the
model not yet downloaded, and checking per call is why turning it on takes
effect without relaunching.

## What the model is asked

One question, one sentence, no chain of reasoning:

> Insert word boundaries into this DVD volume label so it reads as a film
> title. Reply with the title only. If it is not a film title, reply with
> NONE.

Input is **only the label**. Not the runtime, not the chapter count, not the
menu OCR — those are separate evidence, and mixing them into the prompt makes
a wrong answer impossible to attribute.

Batty uses tool calling (`setSessionName`) and ignores the model's final text,
so "no answer" is simply the tool never being called. That is the better
contract and should be copied: a `setSearchTerm(title:)` tool, first call
wins, no call means no good answer. It removes the need to recognise `NONE` in
its several spellings, though `sanitize` must still handle them because a
small model will sometimes call the tool *with* "NONE".

## Validation

Two layers, and the second is specific to this feature.

**1. `sanitize`, per Batty's rule that small models return quotes, too many
words and `NONE` in its various spellings.** Strip surrounding quotes; reject
empty, `NONE` (any case), anything over ~60 characters, and anything
containing control characters.

**2. The letters must be the label's letters.** Fold both sides — lowercase,
punctuation to spaces, apostrophes dropped, whitespace collapsed — then strip
the spaces and require equality:

| Label | Model says | Verdict |
|---|---|---|
| `ENEMYATTHEGATES` | Enemy at the Gates | accepted |
| `ENEMYATTHEGATES` | Enemy at the Gate | rejected — letters differ |
| `ENEMYATTHEGATES` | Behind Enemy Lines | rejected — letters differ |

This is the whole safety argument. It makes the model's job *segmentation*,
which small models do well, and forbids *recall*, which is where they
confabulate. It is a total function of two strings, testable with no model,
and nothing that fails it reaches the user.

Note this is the **opposite** fold from `MenuArchive.fold`, which deliberately
keeps word boundaries because it is measuring whether they were recovered.
Same inputs, two questions, two folds — worth naming them distinctly
(`foldKeepingWords` / `foldToLetters`) so no one reaches for the wrong one.

## Applying the result

- It seeds the search box and nothing else. `SearchPrefill` already refuses to
  overwrite what the user has typed.
- **Only if nothing changed:** the same disc is still in the drive, the user
  has not typed in the box, and the flow has not moved past Choose Movie.
- Written to observed state only from the completion of a `Task` started by an
  event — never from view code.
- Runs off the main actor; Start never waits on it.

**Deviation from Batty:** its model results are *names*, which are cosmetic.
This one writes into a search field, which changes what the user acts on. The
letter-preservation check is what makes that acceptable — without it this
would have to be a caption, as `MenuJudge` is.

## Settings

`AppSettings.usesAppleIntelligence`, defaulting **on**, covering every
model-backed use at once. Settings ▸ Disc Recognition: "Use Apple Intelligence
to help identify discs". Implemented; it already gates `MenuJudge`.

The default has a trap worth knowing about: `UserDefaults.bool(forKey:)`
answers `false` for a key that was never written, so reading it
unconditionally would have switched the feature off for every existing
install the moment it shipped. The loader checks `object(forKey:)` first.

## Picking a search result

The next step up from prefilling the box: when the search returns several
results, choose one.

**This is a bigger claim than the others and deserves saying plainly.** The
caption decides nothing. The search term decides nothing — the user still
picks. A selected result decides the Plex folder, the file name and the
`{tmdb-ID}` the library is keyed on. It is still not an encode decision, and
the user still sees it on Confirm and still presses Start, but it is the first
model output that lands on something durable.

So: **deterministic ranking first, model only among plausible candidates.**

1. **Runtime.** `RuntimeCrossCheck` already compares the disc's feature
   runtime against TMDB's. A result more than a few minutes from the disc's
   own runtime is not this disc, whatever its title says. This alone separates
   *Bloodsport* (1988, 92m) from *Bloodsport II* (1996, 86m) without any
   inference.
2. **Exact title match** against the derived search term, folded.
3. **Year**, when the label or the menu text offered one.
4. **Only then**, if two or more candidates survive, ask the model — with the
   same closed-set discipline `MenuJudge` uses: the schema is the surviving
   results' titles plus "none of these", so an answer outside the list is
   unrepresentable.

Applying it:

- **It is a pre-selection, not a commitment.** The result is highlighted in
  the list exactly as if the user had clicked it; the list stays open and
  every other result stays one click away.
- **Never when a duplicate already exists.** If the chosen movie is already in
  the library, the duplicate check must be what the user sees, not a
  pre-selected row that walks them past it.
- **Never overwrites a selection the user made.** Same rule as
  `SearchPrefill`.
- **Never auto-advances the step.** Choosing the movie for someone is
  defensible; moving them to the next screen because of it is not.
- Recorded in `naming.json` alongside what they finally chose, so the archive
  answers "how often was the automatic pick the one they kept?"

If the runtime check alone turns out to pick correctly on the shelves here,
the model tier should not be built. That is the measurement step 3 below is
for.

## Caching

A memo keyed by label, bounded (Batty uses 256 entries, cleared when full),
**never persisted** — a better model or a better prompt should re-answer on
the next launch rather than inherit an old mistake. One call covers repeat
insertions of the same disc.

## What is collected, so this can be judged

Implemented already, ahead of the model work, because the evidence has to
accumulate before there is anything to evaluate against. Each rip writes
`<archive>/<disc>/naming.json`:

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
that is when it is made. A retry rewrites the record. Upgrade jobs skip it.

The rows worth studying are those where `derivedSearchTerm` is `null`, or
`derivedMatchesChoice` is `false`, beside a real `chosenTitle`. Those are the
discs where the user had to type.

## Testing

Per Batty: **the model is never run in unit tests**, and everything that does
not depend on it is kept separately testable.

- `DiscNameSegmentationTests`: `sanitize` (quotes, `NONE` spellings, length,
  control characters) and the letter-preservation check, as pure functions
  with no model.
- Flow tests against a fake `DiscNameSegmenting`: the term is discarded when
  the disc changed, when the user typed, and when the flow moved on.
- **Replay** — the reason collection comes first: run the segmenter over every
  `volumeName` in the archive and compare to `chosenTitle`. This is the only
  honest measure of whether the feature works, and it needs no drive.
- Real behaviour is observed through the log category, in Console.

## Sequence

1. **Collect.** (Done.) Every rip leaves a `naming.json`.
2. **Reorder tier 3 above the model.** Prefer a title the disc printed. Small,
   independent, worth doing regardless.
3. **Count.** After a dozen or two discs, read the archive: how many labels did
   the ladder miss, and how many of those are segmentation problems rather
   than labels with no title in them (`MOVIE_DISC_1` is not one). **If that
   number is small, stop here** — this is a convenience feature, and the
   honest outcome may be that the rules already cover these shelves.
4. **Build tier 4** only if step 3 justifies it.
5. **Replay** against the archive.

## Open questions

- **Sequels and editions.** `THEHANGOVEREXTENDEDCUT` segments to "The Hangover
  Extended Cut", which is not a TMDB title. Stripping a trailing edition
  phrase is a rule-list job, not a model job, and belongs in tier 1 — but that
  junk list is currently single words (`WS`, `SE`) and would need phrases.
- **Roman numerals and digits.** `BLOODSPORT2`, `ROCKYIII`: separator-free but
  not segmentation problems. A digit or numeral boundary is a rule, and rules
  get first refusal.
- **Whether to retrofit `MenuJudge`** to the protocol-and-toggle shape at the
  same time. It predates this document and follows none of it.
