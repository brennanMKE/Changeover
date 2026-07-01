# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Changeover is a native macOS menu bar app (no Dock icon) that automates the DVD-to-Plex workflow: detect an inserted DVD → search TMDB for the movie → rip with MakeMKV → encode with HandBrake → drop the file into a Plex-ready folder structure. There is no package manager — it is a plain Xcode project with one external runtime dependency on two Homebrew CLI binaries.

## Build, run, test

```bash
# Open in Xcode 26.2 (target macOS 26.2), select the Changeover scheme, build/run.
open Changeover.xcodeproj

# Command-line build
xcodebuild -project Changeover.xcodeproj -scheme Changeover -configuration Debug build

# Run all unit tests (Swift Testing) + UI tests (XCTest)
xcodebuild -project Changeover.xcodeproj -scheme Changeover test

# Run a single Swift Testing test by name
xcodebuild -project Changeover.xcodeproj -scheme Changeover test -only-testing:ChangeoverTests/ChangeoverTests/example
```

Unit tests in `ChangeoverTests/` use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`) — not XCTest. UI tests in `ChangeoverUITests/` use XCTest.

### Setup required before building

1. Copy `Changeover/Secrets.xcconfig.example` → `Changeover/Secrets.xcconfig` (gitignored) and set `TMDB_API_KEY`. The xcconfig is wired as the project's `baseConfigurationReference`; the key flows in via `INFOPLIST_KEY_TMDB_API_KEY = $(TMDB_API_KEY)`.
2. Install the CLI tools the app shells out to: `brew install --cask makemkv && brew install handbrake`. Default paths are `/opt/homebrew/bin/makemkvcon` and `/opt/homebrew/bin/HandBrakeCLI` (Apple Silicon); these are user-editable in Settings.

## Architecture

The pipeline is a linear async flow orchestrated by `DVDPipeline.run()`: **rip → encode → move**, with per-stage guard/abort and a single `log` callback threaded through all stages so progress streams to the UI.

- `AppDelegate.swift` — owns the menu bar `NSStatusItem`, the popover, all `NSWindow` management, the `AppSettings` instance, and wires up `DVDMonitor`. Injects `settings` via `.environment(_:)` into SwiftUI content. Opens Settings automatically on first launch when `!settings.isConfigured`.
- `DVDMonitor.swift` — listens for `NSWorkspace.didMountNotification`, checks for a `VIDEO_TS` folder, dispatches to MainActor.
- `DVDPipeline.swift` — orchestrates the three controllers. **Plain `struct` (MainActor), not an `actor`** — captures path strings off `settings` while on MainActor, then passes them as plain parameters into the nonisolated controllers.
- `RipController.swift` / `EncodeController.swift` — `nonisolated static` functions that shell out to `makemkvcon` and `HandBrakeCLI` via `Process`, streaming stdout line-by-line.
- `PlexOrganizer.swift` — `nonisolated static func move(...)`; creates `Movies/<folderName>/` and moves the encoded file in.
- `AppSettings.swift` — `@Observable`, `UserDefaults`-backed. Single source of truth is `plexMediaRoot`; all working/library paths (`plexMoviesPath`, `workingRipPath`, `workingEncodePath`, …) and the two CLI binary paths are derived/stored here. `isConfigured` gates the rest of the app.
- `Config.swift` — only encoding constants remain (`videoQuality` RF21, `audioEncoder`). All path config moved to `AppSettings`.
- `MovieMetadata.swift` — built from a selected `TMDBMovie`; produces `folderName`, `fileName`, `destinationPath`. `tmdbID` is **non-optional**.
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
- The CLI controllers (`RipController`, `EncodeController`, `PlexOrganizer`) and `Config`'s static constants must be **explicitly `nonisolated`** so the long rip/encode work runs off the main actor. Anything they touch (e.g. `Config` statics) must also be `nonisolated`.
- `DVDMonitor.volumeMounted` is `nonisolated` because `NSWorkspace` calls the `@objc` selector on an arbitrary thread.
- Inside a background `Process` `readabilityHandler`/`terminationHandler`, dispatch log lines back with `Task { @MainActor in log(line) }` so callers can use a plain `(String) -> Void` that mutates `@State` directly.

## Conventions

- **Observation:** use the `@Observable` macro (`import Observation`) everywhere. Never `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject`. Views own their view model with `@State`.
- The app **cannot be sandboxed** (`ENABLE_APP_SANDBOX = NO`) because it runs arbitrary CLI tools and writes to user-chosen volumes — so it is not Mac App Store distributable. After copying to `/Applications`, run `xattr -cr /Applications/Changeover.app` and launch once to register the `SMAppService` login item.
- `Plan.md` is the phased implementation checklist with decisions recorded inline; the `*.md` reference docs (`MacApp.md`, `tmdb_swift_mac_app_guide.md`, the two workflow docs) are background research, not specs to re-derive from.
