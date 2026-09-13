# TOP PRIORITY: UI tests crashed the user's Batty terminal

> **This is the top-priority rule for every session and subagent working on Changeover.**
> Do not run `ChangeoverUITests`, or any command that runs them, without explicit
> go-ahead from the user for that specific run. A plain
> `xcodebuild -scheme Changeover test` counts, because it runs the UI tests too.
> Running them killed every live terminal session the user had open.

## What happened

On 2026-09-12 a Changeover implementation subagent working on issue #0014 ran:

```bash
xcodebuild -project Changeover.xcodeproj -scheme Changeover -destination 'platform=macOS' test
```

The `Changeover` scheme includes `ChangeoverUITests`, so this started a full XCUITest
run on the user's working Mac.

| Time (PDT) | Event |
|---|---|
| 17:04:13 | Changeover test run starts (first `.xcresult`) |
| 17:04:15 | `testmanagerd` (XCTest automation daemon) launches |
| 17:05:36 | Subagent runs `xcodebuild ... test` again (second `.xcresult`) |
| 17:06:06 | **Batty (Prod 1.1.0, `/Applications/Batty.app`) crashes.** Every terminal session the user had open is lost, including other Claude sessions running inside it. |

Crash report: `~/Library/Logs/DiagnosticReports/Batty-2026-09-12-170611.ips`

- `EXC_BAD_ACCESS (SIGSEGV)`, `KERN_INVALID_ADDRESS at 0x20`
- Faulting thread top frame:
  `XCTAutomationSupport -[XCTAutomationSession initWithAccessibilityFramework:dataSource:]_block_invoke`
- No Batty frames on the faulting thread. Batty does not link XCTest.
  `XCTAutomationSupport` was loaded from `/System/Library/PrivateFrameworks` by the system.

## Second UI test run after the crash

The crash killed the orchestrating Claude session, which was running inside
Batty, and stopped its two background subagents mid-task: the #0014
implementer and a #0013 reviewer. After the session was restarted, both were
resumed. Their resume messages restated their original briefs. At that point
the cause of the crash was not yet known, so neither message forbade UI tests.

| Time (PDT) | Event |
|---|---|
| 17:10:40 | The resumed #0014 implementer runs the same bare `xcodebuild ... test` as its baseline check. The run holds 61 tests: the 58 `ChangeoverTests` plus the 3 `ChangeoverUITests`, so XCUITest starts a second time. It completes without crashing anything, and no new crash reports are written. |
| before 17:17 | The orchestrator sends both running subagents a stop message restricting them to `-only-testing:ChangeoverTests`. |
| 17:17:11 | `CLAUDE.md` rule committed (`af8f426`), together with this doc. |
| 17:19:45 | Hard stop committed (`1d9ebe6`): the `Changeover` scheme's Test action now contains only `ChangeoverTests`. |

Every test run from 17:16 onward was unit-only. The #0014 implementer's final
report confirmed its baseline check had been the bare `test`.

### Contributing causes

- `CLAUDE.md` listed the bare command as the way to run all tests (rule 4 below).
- The orchestrator had normalised UI test runs earlier the same day. Its #0002
  brief told the implementer that UI tests "CAN run on this machine" and to run
  them at least once. The #0011 brief said they "also run here if you want
  them". The Phase 1 review brief listed `-only-testing:ChangeoverUITests` as a
  command to use. The #0002 implementer's and reviewer's UI test runs completed
  without incident, so subagents were following a precedent the orchestrator had
  set.
- A resumed agent carries on with its original brief. A safety rule learned
  while an agent is stopped must go into the resume message itself.

## Why a Changeover test can kill a different app

XCUITest doesn't stay inside the app under test. When a UI test session starts,
`testmanagerd` sets up automation through the macOS Accessibility layer, and
`XCTAutomationSupport` gets loaded into **other running GUI apps** as well. If
that code crashes inside another process, that process dies. Here it was the
terminal holding all of the user's work.

So running UI tests on the user's working Mac isn't contained. It can take
down any app they have open.

## Prevention rules for Changeover

1. **Default to unit tests only.** The routine verification command is:

   ```bash
   xcodebuild -project Changeover.xcodeproj -scheme Changeover -destination 'platform=macOS' \
       test -only-testing:ChangeoverTests
   ```

   Never run bare `xcodebuild ... test` on the `Changeover` scheme as a
   "did I break anything?" check.

2. **UI tests need explicit user approval each time.** Before running
   `ChangeoverUITests`, ask the user and say that it can crash other apps,
   including their terminal. Approval for one run doesn't cover the next.
   Subagents must never run UI tests on their own. They report back and let
   the main session ask.

3. **Prefer a separate machine for UI tests.** If the user approves a UI test
   run, suggest running it on a Mac that isn't holding live terminal sessions.

4. **Put the rule where agents read it.** `CLAUDE.md` currently lists
   `xcodebuild -project Changeover.xcodeproj -scheme Changeover test` as
   "Run all unit tests (Swift Testing) + UI tests (XCTest)". That is the
   command the subagent copied. Update the `Build, run, test` section so the
   default is `-only-testing:ChangeoverTests`, mark the full run as
   approval-gated, and link this doc. Pass the same rule into every
   implementer and reviewer subagent prompt.

5. **Optional hard stop.** Remove `ChangeoverUITests` from the `Changeover`
   scheme's Test action, or move it to a separate `Changeover UI Tests`
   scheme. Then a bare `test` physically can't start XCUITest.

## Status of the prevention rules

As of 2026-09-12:

- **Rule 1:** applied. Every subagent brief since the stop message restricts the test command to `-only-testing:ChangeoverTests`.
- **Rule 2:** applied. Recorded in `CLAUDE.md` and in the orchestrator's persistent memory, so later sessions carry it too.
- **Rule 3:** gordon, an idle Mac mini, is the candidate for any approved run. It isn't set up yet: Automation Mode on gordon needs the user's authentication, and the repo isn't checked out there.
- **Rule 4:** done in `af8f426`.
- **Rule 5:** done in `1d9ebe6`. The UI tests moved to a separate `Changeover UI Tests` scheme. A `build-for-testing` run, which executes no tests, confirmed that the `Changeover` scheme's `.xctestrun` lists only `ChangeoverTests`.

The three `ChangeoverUITests` are unmodified Xcode template tests that assert
nothing, so every one of these runs carried all of the risk and none of the
verification value.

## Batty side

Batty should also survive an external automation session, since no app should
die because another project's tests started. That fix is tracked as an issue in
the Batty repo (`/Users/brennan/Developer/brennanMKE/Batty/issues/`). The rules
above don't depend on it. Until Batty is fixed, and after, Changeover must not
start UI tests on the user's working Mac without asking.
