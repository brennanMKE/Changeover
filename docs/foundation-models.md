# Apple Foundation Models in Changeover

Changeover uses Apple's on-device Foundation Models framework (Apple
Intelligence) to read a DVD's own words when the disc's *structure* is
ambiguous. Everything here is inference about language the disc printed —
never about what to encode.

| Use | What it produces | Where it shows | Status |
|---|---|---|---|
| Play-button judge (`MenuJudge`) | a caption naming which menu button reads as "play the movie" | Confirm step | shipped |
| Disc-name segmentation | a search term from a label with no word boundaries | Choose Movie search box | planned — [`disc-name-inference.md`](disc-name-inference.md) |
| Result picking | a pre-selected row among several TMDB results | Choose Movie list | planned — same document |

All inference runs on the device. Nothing is sent over the network. Every use
is optional: with the model unavailable, switched off, failing, or answering
badly, Changeover behaves exactly as it does today.

Companion document: `~/Developer/brennanMKE/Batty/docs/foundation-models.md`,
whose rules this follows. Where Changeover differs, this says so and why.

## The rule that comes before all the others

**The model never decides what gets encoded.**

`DiscTitleHeuristic`, HandBrake's `MainFeature` answer, the 45-minute
fallback, the Play All guard, the TMDB runtime cross-check and the user
pressing Start are the only things that choose a title, a track or a file
name. A model answer is a *caption* or a *prefilled text field*: something the
user is already looking at and can override without noticing they did.

This is not a promise about prompt quality. It is where the code is: the
judge's answer reaches `MenuIntelligence.judgeCaption`, a string, and nothing
reads it but a label.

## Availability

Changeover's deployment target is macOS 26.2, so — unlike Batty, which
deploys to 15.6 and needs an OS-version gate — the framework is always
present at runtime.

Two layers remain, and both matter:

1. **Compile time:** `#if canImport(FoundationModels)`. The framework import
   and every Foundation Models type stay inside it, so the project still
   builds against an SDK without the framework, and so `Tools/menu-derive`
   and `Tools/menu-agreement` can compile the pure menu sources on their own.
2. **Model state, on every call:** `SystemLanguageModel.default.availability`
   must be `.available`. That covers Apple Intelligence being switched off and
   the model not yet being downloaded. Checking per call, not once at launch,
   is what lets a user turn Apple Intelligence on and have it take effect
   without relaunching Changeover.

## Code map

| File | Role |
|---|---|
| `Changeover/MenuJudge.swift` | `Question`, `Answer`, `caption`, the schema, and the one `LanguageModelSession` call |
| `Changeover/MenuIntelligence.swift` | `judgeQuestion` (when to ask) and `judgeCaption` (what came back) |
| `Changeover/JobController.swift` | `judgeRunner` — the injection seam — and `askTheModel(forDisc:generation:)` |
| `Changeover/MenuLexicon.swift` | the known-label list that decides whether asking is warranted at all |
| `ChangeoverTests/MenuJudgeTests.swift` | 15 tests, none of which run the model |

## How a question gets asked

`MenuJudge` is tier 3 of the menu ladder. Tiers 1 and 2 are structure and a
lexicon of labels real discs print; the model is consulted **only where they
left a genuine question**:

1. Two or more of the disc's own title-jumping buttons survived the lexicon.
   One candidate is answered by the structure. Zero is answered by silence.
2. The question carries the *labels of those buttons only* — OCR text
   attached to a real button whose command resolves to a real title. Never
   free text off the still, which is the filmography trap: a cast page's
   "PLAY" is not a play button.
3. The output schema is a **closed set**: the disc's own labels plus "none of
   these". Guided generation cannot emit a string outside it, and
   `interpret(pick:question:)` maps the answer back by exact match. A label
   that was never offered is not a failure mode this design can have.
4. The chosen label's button must resolve to a title the scan actually found.
   That check is tier 1's, not the model's, and it runs after every answer.

Unavailable, a refusal, a guardrail trip, an unsupported locale, any thrown
error, and "none of these" all produce the same thing: no caption, no retry.

Greedy sampling, one call, a few tokens, off the main actor. Nothing waits on
it — the scan, the Start button and the encode are all independent of whether
it ever answers.

## Rules for a new use

Adopted from Batty, with the Changeover-specific reasons.

- **Put it behind a protocol with a `makeIfAvailable()` factory**, and keep
  `import FoundationModels` inside `#if canImport`. The Foundation Models
  types stay confined to one file so the pure decision sources keep compiling
  for the `Tools/` binaries.
- **Never throw to the caller.** Return "no answer" and log the reason.
- **Ask only where the deterministic path left a real question.** Not as a
  second opinion on an answer the structure already gave — that is how a
  correct answer gets overturned by a plausible one.
- **Constrain the output to a closed set wherever one exists.** A schema built
  from the disc's own strings is worth more than any amount of prompt
  wording, because it makes a whole class of wrong answer unrepresentable.
- **Where no closed set exists, check the answer against its input.** The
  disc-name plan's letter-preservation check is the pattern: fold the label
  and the answer to their letters and require equality. That makes the task
  segmentation, which small models do well, and forbids recall, which is
  where they confabulate.
- **Sanitize every result** before it reaches state the UI reads. Small models
  return quotes, extra words, and `NONE` in several spellings.
- **Apply a result only if nothing changed** since the request started — the
  same disc, the same scan generation, the user has not typed or moved on.
  `askTheModel` already guards on `generation == scanGeneration` and
  `insertedDisc == disc`, so a caption can never cross discs.
- **A new `LanguageModelSession` per request.** No shared context between
  uses, and none between discs.
- **Gate it with `AppSettings.usesAppleIntelligence`**, read on every call so
  switching it takes effect without relaunching. One switch covers every use:
  a user turning this off is turning off "the app guesses things for me", not
  auditing a feature list.
- **Write to observed state only from the completion of a `Task` started by an
  event**, never from view code.
- **Record the answer in the archive.** `MenuDerived.judge` keeps what the
  model said, so a change in behaviour after an OS update is visible rather
  than anecdotal. `null` there means "never asked", not "asked and got
  nothing" — keep those distinguishable.

## Testing

**The model is never run in unit tests.** Everything that does not depend on
it is kept separately testable, which is most of it:

- `MenuJudge.Question` / `caption` / `interpret` are pure — the schema's
  closed set, the "none of these" answer, a label that maps to a title the
  scan never found, and the prompt's own text are all asserted with no model.
- `JobController.judgeRunner` is the injection seam, so controller-level tests
  drive the whole path with a fake that answers instantly.
- Real behaviour is observed on a real disc, and recorded in the archive's
  `derived.json` rather than in someone's memory.

The same shape is required of any new use: a pure `Question`/`Answer` pair, a
protocol for the call, and a fake in the tests.

## Known gaps

Honest list, so nobody infers these were decided rather than deferred.

- **The toggle is read per disc, not per call.** `askTheModel` runs from a
  task with no `AppSettings` in hand, so `JobController` mirrors the flag when
  a disc's menus are read. Switching it off mid-scan still lets that disc's
  question through. Threading settings into every menu callback to read one
  Bool would be the worse trade, but this is a deviation from the rule above
  and should be named as one.
- **`MenuJudge` is not behind a protocol.** It is a `nonisolated enum` with a
  static `answer(for:)`. The `judgeRunner` seam on `JobController` gives tests
  what they need, so this is a consistency gap rather than a testability one —
  but a second use is the moment to introduce the protocol and retrofit.
- **No caching.** Each disc asks once, which is cheap, but repeat insertions of
  the same disc ask again. A bounded, never-persisted memo keyed by disc
  identity would fix it; a persisted one would be wrong, since a better model
  should re-answer rather than inherit an old mistake.
- **No log category.** Batty watches its model calls in Console with per-request
  result and elapsed time. Changeover logs the caption into the job log and
  nothing else, so a slow or silently-unavailable model is invisible.
