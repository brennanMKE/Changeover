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

## Batty side

Batty should also survive an external automation session, since no app should
die because another project's tests started. That fix is tracked as an issue in
the Batty repo (`/Users/brennan/Developer/brennanMKE/Batty/issues/`). The rules
above don't depend on it. Until Batty is fixed, and after, Changeover must not
start UI tests on the user's working Mac without asking.
