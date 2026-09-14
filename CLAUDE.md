# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Changeover is a native macOS menu bar app (no Dock icon) that automates the DVD-to-Plex workflow: detect an inserted DVD → search TMDB for the movie → encode straight from the disc with HandBrake → drop the file into a Plex-ready folder structure. There is no package manager — it is a plain Xcode project whose one required external runtime dependency is the Homebrew `HandBrakeCLI` binary. MakeMKV is no longer on the pipeline's path; it is kept only as a planned optional fallback (#0015).

## Build, run, test

```bash
# Open in Xcode 26.2 (target macOS 26.2), select the Changeover scheme, build/run.
open Changeover.xcodeproj

# Command-line build
xcodebuild -project Changeover.xcodeproj -scheme Changeover -configuration Debug build

# Run unit tests — THE ONLY ROUTINE TEST COMMAND
xcodebuild -project Changeover.xcodeproj -scheme Changeover -destination 'platform=macOS' test -only-testing:ChangeoverTests

# Run a single Swift Testing test by name — note the trailing () and the quotes
xcodebuild -project Changeover.xcodeproj -scheme Changeover -destination 'platform=macOS' test '-only-testing:ChangeoverTests/ChangeoverTests/example()'
```

### Running tests on another Mac: use `./run-remote-tests.sh <host>`

Unit tests run on a separate Mac over SSH (currently `gordon`), never on the development Mac. Don't hand-type `rsync` and `ssh … xcodebuild`; the script does both. It syncs the repo to the same path under `$HOME` on the host.

It prints only a short summary: the result, test counts, up to 30 failure lines and any continuation-leak warnings. The full log is copied to `build/remote-tests/<host>/`. Read it only when the summary isn't enough, and then with `grep`, not whole.

```bash
./run-remote-tests.sh gordon                                 # sync, run all of ChangeoverTests
./run-remote-tests.sh gordon ProcessRunnerTests/someTest     # sync, run one test ("ChangeoverTests/" and "()" added)
./run-remote-tests.sh gordon --no-sync ProcessRunnerTests/x  # falsification: run the host's edited copy as-is
./run-remote-tests.sh gordon --sync-only                     # restore the host's copy afterwards (never git checkout there)
```

Built-in safeguards:
- refuses UI test selectors;
- refuses to start while another `xcodebuild` is running on the host;
- stops runs after `TEST_TIMEOUT` seconds (default 1500, exit 124);
- reports a 0-test run as a failure.

> ⚠️ **Swift Testing selectors need the trailing `()`.** `-only-testing:ChangeoverTests/<Suite>/<test>` without it matches nothing, runs **0 tests**, and still prints `** TEST SUCCEEDED **` (verified 2026-09-12). Quote the argument, or the shell rejects the parentheses. Before trusting a targeted run, check the output names the test and reports a non-zero count, e.g. `✔ Test run with 1 test`.

Unit tests in `ChangeoverTests/` use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`) — not XCTest. UI tests in `ChangeoverUITests/` use XCTest.

### ⚠️ UI tests: never on the development Mac

**Never run `ChangeoverUITests`, and never run a bare `xcodebuild ... test` on the `Changeover` scheme** — the scheme includes the UI tests, so a bare `test` starts XCUITest. On 2026-09-12 that crashed the user's terminal app (Batty) and killed every live session they had open: `testmanagerd` injects `XCTAutomationSupport` into *other* running GUI apps, and it segfaulted inside the terminal. See [`docs/ui-test-crash-prevention.md`](docs/ui-test-crash-prevention.md).

- **Hard stop in place:** the shared `Changeover` scheme's Test action contains only `ChangeoverTests`, so even a bare `test` on it cannot start XCUITest. The UI tests live in a separate `Changeover UI Tests` scheme, which must only be used for an approved run. Do not add `ChangeoverUITests` back to the `Changeover` scheme.
- Always pass `-only-testing:ChangeoverTests` anyway. That is the verification command for every change.
- Don't write new UI tests to verify behaviour. Put logic behind a plain-value seam and unit-test it in the app-hosted `ChangeoverTests` bundle, the way `JobController.Runner`, the #0013 disc classifier and #0014's `arguments()` do. The three existing UI tests are unmodified Xcode template boilerplate that assert nothing.
- **UI test runs happen only inside a disposable macOS VM** (Tart) on cameron, and only via `./run-ui-tests-vm.sh` at the repo root: it clones the `changeover-uitest-golden` image, runs the `Changeover UI Tests` scheme inside the guest, pulls results into `build/ui-tests/`, and deletes the clone. The path was validated 2026-09-14 (4/4 template tests passed in ~90 s end to end); setup, the golden-image record and the incident log live in the user's Homelab doc `cameron/tart-ui-test-vm.md`. When the host is short of memory, the script requests it through the generic `memory-signal` protocol (a filesystem spool under `MEMORY_COORDINATION_DIR`) and waits for the machine's observer to free memory and signal ready; how this machine frees it is machine wiring, never project content. Running UI tests directly on a physical Mac, whether cameron or gordon, remains forbidden (2026-09-12: XCUITest crashed Batty and killed ~38 terminal sessions).
- Subagents must never run UI tests. If UI verification seems needed, record it as unverified and report back to the main session.
- Never run UI tests on a physical Mac's own desktop: not the development Mac, not gordon, and not the Plex host. Inside the VM guest — via the script — is the only place.
- Every implementer and reviewer subagent prompt must carry this rule.

### Setup required before building

1. Copy `Changeover/Secrets.xcconfig.example` → `Changeover/Secrets.xcconfig` (gitignored) and set `TMDB_API_KEY`. The xcconfig is wired as the project's `baseConfigurationReference`; the key flows in via `INFOPLIST_KEY_TMDB_API_KEY = $(TMDB_API_KEY)`.
2. Install the CLI tool the app shells out to: `brew install handbrake` (default path `/opt/homebrew/bin/HandBrakeCLI` on Apple Silicon, user-editable in Settings). `makemkvcon` (`brew install --cask makemkv`) is optional and not currently invoked; its Settings path is kept for the #0015 fallback. `lsdvd` (`brew install lsdvd`) is optional and only strengthens disc identity.

## Architecture

The pipeline is a linear async flow orchestrated by `DVDPipeline.run()`: **encode → move**. There is no rip stage and no intermediate `.mkv` — HandBrakeCLI reads the disc's mount root directly (#0014). Each stage reports a typed `JobOutcome` / `JobFailure` (#0007), and a single `log` callback is threaded through so progress streams to the UI.

- `AppDelegate.swift` — owns the menu bar `NSStatusItem`, the popover, all `NSWindow` management, the `AppSettings` instance, and wires up `DVDMonitor`. Injects `settings` via `.environment(_:)` into SwiftUI content. Opens Settings automatically on first launch when `!settings.isConfigured`.
- `JobController.swift` — `@Observable`, owned by `AppDelegate` so a running job outlives its window (#0002). Holds bounded `logLines`, `isRunning`, `lastOutcome` and `insertedDisc`; `start(metadata:settings:)` refuses re-entry and refuses when no disc is mounted. Its `Runner` typealias is the seam for driving jobs in tests without a disc or HandBrakeCLI.
- `DVDMonitor.swift` — a `DiskArbitration` session on a private dispatch queue (#0013). Accepts only genuine optical media (not disk images or network volumes) that contain `VIDEO_TS`, debounces by disc identity (lsdvd's `dvddiscid` when available), reports insertion and removal, and hops to MainActor to notify. The classification logic in `DiscInsertion.swift` is a pure, unit-testable seam.
- `DVDPipeline.swift` — orchestrates encode → move for one disc (`disc: URL`). **Plain `struct` (MainActor), not an `actor`** — captures path strings off `settings` while on MainActor, then passes them as plain parameters into the nonisolated controllers.
- `EncodeController.swift` — `nonisolated static` functions that shell out to `HandBrakeCLI` via `Process`, streaming output line-by-line. `arguments(source:title:output:)` is pure so the argument vector is unit-testable; `TitleSelection` (`.mainFeature` / `.index(n)`) makes `--main-feature` and `--title` mutually exclusive. Encoder settings come from `Config`. `RipController` was deleted in #0014 — do not restore it; its `largestMKV` *was* #0003's bug.
- `PlexOrganizer.swift` — `nonisolated static func move(...) throws(JobFailure) -> URL`; creates `Movies/<folderName>/` and stages the encoded file onto the destination volume before replacing, so a failed re-rip never destroys the existing library copy and cross-volume moves still work (#0012).
- `AppSettings.swift` — `@Observable`, `UserDefaults`-backed. Single source of truth is `plexMediaRoot`; all working/library paths (`plexMoviesPath`, `workingRipPath`, `workingEncodePath`, …) and the two CLI binary paths are derived/stored here. `isConfigured` gates the rest of the app.
- `Config.swift` — only encoding constants remain: `videoEncoder` (x265), `videoQuality` (RF 23), `encoderPreset` (`slow`), `audioEncoder`. All path config moved to `AppSettings`.
- `MovieMetadata.swift` — built from a selected `TMDBMovie`; produces `folderName` and `fileName`. `tmdbID` is **non-optional**. The title is path-sanitized before it becomes a path component (`/` and `:` become `-`, etc.; #0010).
- `TMDB/` — `TMDBClient` (search + poster URLs), `TMDBModels`, and `MovieSearchViewModel` (`@Observable`, drives `MetadataEntryView`).

### Plex naming convention (strict — no exceptions)

```
Movies/Title (Year) {tmdb-ID}/Title (Year).mp4
```

- **Folder** = `Title (Year) {tmdb-ID}` — the `{tmdb-ID}` tag is required and is what lets Plex disambiguate remakes/identical titles.
- **File** = `Title (Year).mp4` — no TMDB tag.

`Movies.txt` is a reference dump of the existing library used to validate this format (ignore its stray `Movies.txt` line-13 entry).

## Concurrency: MainActor-by-default

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so **every type and function is `@MainActor` unless it explicitly opts out**. Rules that follow from this:

- SwiftUI views, view models, `AppDelegate`, and `DVDPipeline` need no annotation — they're MainActor for free. Do **not** use the `actor` keyword for a type that has no reason to leave MainActor.
- The CLI controllers (`EncodeController`, `PlexOrganizer`) and `Config`'s static constants must be **explicitly `nonisolated`** so the long rip/encode work runs off the main actor. Anything they touch (e.g. `Config` statics) must also be `nonisolated`.
- `DVDMonitor`'s DiskArbitration callbacks are `nonisolated` because they arrive on its private dispatch queue; they classify off the main actor and hop back with `Task { @MainActor in … }`.
- Inside a background `Process` `readabilityHandler`/`terminationHandler`, dispatch log lines back with `Task { @MainActor in log(line) }` so callers can use a plain `(String) -> Void` that mutates `@State` directly.

## Conventions

- **Observation:** use the `@Observable` macro (`import Observation`) everywhere. Never `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject`. Views own their view model with `@State`.
- The app **cannot be sandboxed** (`ENABLE_APP_SANDBOX = NO`) because it runs arbitrary CLI tools and writes to user-chosen volumes — so it is not Mac App Store distributable. After copying to `/Applications`, run `xattr -cr /Applications/Changeover.app` and launch once to register the `SMAppService` login item.
- `Plan.md` is the phased implementation checklist with decisions recorded inline; the `*.md` reference docs (`MacApp.md`, `tmdb_swift_mac_app_guide.md`, the two workflow docs) are background research, not specs to re-derive from.
