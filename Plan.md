# Changeover — Implementation Plan

**App name:** Changeover
**Goal:** Native macOS menu bar app that detects DVD insertion, searches TMDB for the movie (with poster art), then automatically rips → encodes → places the file into a Plex-ready folder structure.

Reference docs: `MacApp.md`, `Automated_DVD_to_Plex_Workflow.md`, `mac_plex_dvd_workflow.md`, `tmdb_swift_mac_app_guide.md`, `Movies.txt`

---

## Swift conventions

- **Observable state:** Use `@Observable` macro (`import Observation`) — never `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject`. In views, own the view model with `@State`.

- **Deployment target:** macOS 26.2 — all modern APIs available.

### MainActor default isolation

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set on this project. **Every type and function is `@MainActor` unless it explicitly opts out.** Consequences and rules:

| Code | Isolation | Notes |
|---|---|---|
| SwiftUI views, view models, AppDelegate | `@MainActor` | default — no annotation needed |
| `DVDPipeline` | `@MainActor` | plain `struct`, not `actor` — no custom executor needed |
| `RipController`, `EncodeController` | `nonisolated` | must be explicit; runs on cooperative thread pool so MainActor stays free during long processes |
| `PlexOrganizer` | `nonisolated` | synchronous file move; called from MainActor context |
| `DVDMonitor.volumeMounted` | `nonisolated` | `@objc` selector called by NSWorkspace on an arbitrary thread |
| `Config` static constants | `nonisolated` | constants accessed from `nonisolated` functions must be marked explicitly |

**Do not use the `actor` keyword for types that have no reason to leave MainActor.** A plain struct or class gets `@MainActor` for free.

**Log callbacks from background Process handlers** must be dispatched back to MainActor:
```swift
// Inside readabilityHandler / terminationHandler (background thread):
Task { @MainActor in log(line) }
```
This lets the caller use a simple `(String) -> Void` closure that directly mutates `@State` without an inner `Task { @MainActor in ... }` at the call site.

---

## How to use this document

- Check off `[x]` items as work is completed.
- Each phase can be done independently across sessions.
- Notes under items capture decisions made during implementation.

---

## Plex Naming Convention

`Movies.txt` captures the folder names of the existing library. Every entry follows this exact format — **no exceptions**:

```
Movie Title (Year) {tmdb-ID}
```

Real examples from the library:

| Folder name | File inside |
|---|---|
| `Blade Runner (1982) {tmdb-78}` | `Blade Runner (1982).mp4` |
| `Pulp Fiction (1994) {tmdb-680}` | `Pulp Fiction (1994).mp4` |
| `The Grand Budapest Hotel (2014) {tmdb-120467}` | `The Grand Budapest Hotel (2014).mp4` |
| `Planes, Trains and Automobiles (1987) {tmdb-2609}` | `Planes, Trains and Automobiles (1987).mp4` |

Rules:
- **Folder name** = `Title (Year) {tmdb-ID}` — always includes the TMDB tag
- **File name** = `Title (Year).mp4` — no TMDB tag, just title and year
- TMDB ID is **required** — every movie in the library has one; `MovieMetadata.tmdbID` is non-optional
- Plex uses the `{tmdb-ID}` tag in the folder name to unambiguously match metadata, avoiding mismatches on remakes or films with identical titles

> **Note:** `Movies.txt` contains a stray `Movies.txt` entry on line 13 — ignore it, it is an artifact of how the list was generated.

---

## UX Flow (overview)

```
DVD inserted
  └─▶ Metadata window appears
       └─▶ User types movie title → clicks Search (or presses Return)
            └─▶ TMDB results list: poster | title | year | TMDB ID
                 └─▶ User clicks correct result (row highlights)
                      └─▶ "Start Ripping" button enables
                           └─▶ makemkvcon rips → HandBrakeCLI encodes → file moved to Plex
                                └─▶ Notification: "Done — scan Plex"
```

No manual entry of year or TMDB ID — all populated from the selected TMDB result.

---

## Phase 1 — Project Foundation

Convert the blank SwiftUI starter into a menu bar app with no Dock icon.

- [x] **1.1** `LSUIElement = YES` added via `INFOPLIST_KEY_LSUIElement` in project.pbxproj (auto-generated plist; no separate plist file in this Xcode 26.2 project)
- [x] **1.2** Not required — `LSUIElement` alone is sufficient; `LSBackgroundOnly` omitted
- [x] **1.3** `ENABLE_APP_SANDBOX = NO` set in project.pbxproj for both Debug and Release; `ENABLE_USER_SELECTED_FILES` and `REGISTER_APP_GROUPS` removed
- [x] **1.4** `ChangeoverApp.swift` rewritten — `Settings { EmptyView() }` + `@NSApplicationDelegateAdaptor`
- [x] **1.5** `AppDelegate.swift` created

---

## Phase 2 — Configuration

Centralize all paths, encoding settings, and API key access.

- [x] **2.1** `Config.swift` created — Plex paths, CLI paths, RF quality 21, audio encoder, TMDB key (Info.plist first, env var fallback)
- [x] **2.2** `Secrets.xcconfig` created and populated with API key; added to `.gitignore`. `INFOPLIST_KEY_TMDB_API_KEY = $(TMDB_API_KEY)` in target build settings. `baseConfigurationReference` wired to both project-level Debug and Release configs in project.pbxproj — no manual Xcode step needed.

> **Note:** `TMDB_API_KEY` is already exported in `~/.zshrc`. For Xcode scheme runs, the xcconfig approach is more reliable than environment variables. Copy the key from your shell (`echo $TMDB_API_KEY`) into `Secrets.xcconfig`.

> **Note:** Run `which makemkvcon` and `which HandBrakeCLI` on the target Mac to confirm paths. Homebrew installs to `/opt/homebrew/bin/` on Apple Silicon.

---

## Phase 3 — Disc Detection

Watch for DVD mounts using `NSWorkspace` notifications.

- [x] **3.1** `DVDMonitor.swift` created — `NSWorkspace.didMountNotification`, `VIDEO_TS` check, dispatches to `@MainActor` via `Task { @MainActor in }`

---

## Phase 4 — TMDB Client

Networking layer for movie search and poster art. No UI yet — just the data layer.

- [x] **4.1** `TMDB/TMDBModels.swift` created — `TMDBSearchResponse`, `TMDBMovie` (with `yearText`), `TMDBError`
- [x] **4.2** `TMDB/TMDBClient.swift` created — `searchMovies()`, `posterURL()`
- [x] **4.3** `TMDB/MovieSearchViewModel.swift` created — `@MainActor @Observable` class (not `ObservableObject`) with query, results, isLoading, errorMessage, selectedMovie. Use `@Observable` macro from the `Observation` framework throughout this project — never `ObservableObject`/`@Published`/`@StateObject`/`@ObservedObject`.

---

## Phase 5 — Movie Search UI

The metadata window: search field, poster results list, and rip trigger.

- [x] **5.1** `MovieMetadata.swift` created — `init(from: TMDBMovie)`, `folderName`, `fileName`, `destinationPath`
- [x] **5.2** `MetadataEntryView.swift` created — search bar, spinner/error row, `List` with `selection:` binding, folder name preview, scrolling log area, Start Ripping button
- [x] **5.3** `PosterThumb` implemented inline in `MetadataEntryView` as `MovieRow`'s `posterThumb` computed view
- [x] **5.4** `AppDelegate.showMetadataEntry()` wired — creates `NSWindow` (480×580) hosting `MetadataEntryView`; reuses existing window if already open

---

## Phase 6 — Ripping

Shell out to `makemkvcon` to rip the disc.

- [x] **6.1** `RipController.swift` created — `nonisolated static func rip(log:)`, `makemkvcon mkv disc:0 all`, streams output line-by-line, returns largest `.mkv` on success

---

## Phase 7 — Encoding

Shell out to `HandBrakeCLI` to encode the MKV to MP4.

- [x] **7.1** `EncodeController.swift` created — `nonisolated static func encode(input:output:log:)`, HandBrakeCLI with av_mp4/RF21/copy:aac,copy:ac3/scan subtitles/chapter markers

---

## Phase 8 — Plex Organization

Move the encoded file into the correct Plex folder structure.

- [x] **8.1** `PlexOrganizer.swift` created — `nonisolated static func move(encodedFile:metadata:log:)`, creates `Movies/<folderName>/`, moves file, overwrites if exists

---

## Phase 9 — Pipeline

Tie rip → encode → organize into a single async flow.

- [x] **9.1** `DVDPipeline.swift` created — Swift `actor`, rip → encode → move sequence with per-stage error handling
- [x] **9.2** `MetadataEntryView.startRipping()` constructs `MovieMetadata(from: selectedMovie)`, runs pipeline, streams log lines via `Task { @MainActor in logLines.append(line) }`
- [x] **9.3** `PlexOrganizer.move()` logs `✓ Moved to: <full path>` on success

---

## Phase 10 — Status Menu

Give the menu bar icon something useful to show.

- [x] **10.1** `StatusMenuView.swift` updated — shows configured/unconfigured status, Open… (disabled until configured), Settings…, Quit

---

## Phase 12 — Settings

User-configurable paths; no hardcoded assumptions about folder locations.

- [x] **12.1** `AppSettings.swift` created — `@Observable`, UserDefaults-backed; single `plexMediaRoot` input; all working and library paths derived; `isConfigured` computed from non-empty root
- [x] **12.2** `SettingsView.swift` created — `NSOpenPanel` folder picker for Plex root; text fields + Detect buttons for CLI paths; derived path preview; Save button calls `settings.persist()`
- [x] **12.3** `Config.swift` stripped — removed all path constants (moved to `AppSettings`); retained `videoQuality`, `audioEncoder`, `tmdbAPIKey`
- [x] **12.4** `AppDelegate.swift` updated — owns `let settings = AppSettings()`; injects via `.environment(settings)` into popover and windows; calls `showSettings()` on first launch if `!settings.isConfigured`
- [x] **12.5** `DVDPipeline.swift` updated — accepts `settings: AppSettings`; captures paths on MainActor then passes as parameters to `nonisolated` controllers
- [x] **12.6** `RipController`, `EncodeController`, `PlexOrganizer` updated — all `Config` path references replaced with explicit parameters

---

## Phase 11 — Enhancements (Future)

Nice-to-haves after the core workflow is solid.

- [ ] **11.1** Debounced type-to-search — cancel previous search `Task` after a short delay as the user types (removes the need to press Search manually)
- [ ] **11.2** TV show support — add a Movie / TV Show toggle; TV path adds Season and Episode fields and places files under `TV Shows/<Show>/Season XX/`
- [ ] **11.3** Plex API scan — after organizing, hit the Plex local HTTP API to trigger a library scan automatically
- [ ] **11.4** Auto-eject — run `drutil eject` after ripping completes
- [ ] **11.5** macOS notification — send a `UNUserNotificationCenter` notification when encoding and move are complete
- [ ] **11.6** Working folder cleanup — delete the intermediate `.mkv` from the ripping folder after a successful encode
- [ ] **11.7** Result sorting — sort TMDB results: exact title match first, then by year descending

---

## File Structure (target)

```
Changeover/
  ChangeoverApp.swift         # Entry point — menu bar scene, AppDelegate adaptor
  AppDelegate.swift           # NSStatusItem, popover, DVDMonitor wiring, Login Item
  DVDMonitor.swift            # NSWorkspace disc detection
  Config.swift                # Paths, encoding settings, TMDB API key access
  Secrets.xcconfig            # TMDB_API_KEY — not committed to git
  TMDB/
    TMDBModels.swift          # Codable structs — TMDBMovie, TMDBSearchResponse, TMDBError
    TMDBClient.swift          # Networking — searchMovies(), posterURL()
    MovieSearchViewModel.swift # ObservableObject — query, results, selectedMovie
  MovieMetadata.swift         # Plain struct — folderName, fileName (from TMDBMovie)
  MetadataEntryView.swift     # Search UI — poster list, selection, log area
  StatusMenuView.swift        # Popover content — status + Quit
  DVDPipeline.swift           # Actor orchestrating rip → encode → move
  RipController.swift         # makemkvcon shell-out
  EncodeController.swift      # HandBrakeCLI shell-out
  PlexOrganizer.swift         # File move into Plex structure
```

---

## Existing Library (Movies.txt — 33 films)

The Plex library already has 33 movies organized in the correct format. Every new rip must match this convention exactly or Plex will not pick it up correctly.

```
A Night at the Roxbury (1998) {tmdb-9429}
BlacKkKlansman (2018) {tmdb-487558}
Blade Runner (1982) {tmdb-78}
Blades of Glory (2007) {tmdb-9955}
Dream a Little Dream (1989) {tmdb-15142}
Fargo (1996) {tmdb-275}
Fast Times at Ridgemont High (1982) {tmdb-13342}
Father of the Bride (1991) {tmdb-11846}
Groove (2000) {tmdb-23655}
Grosse Pointe Blank (1997) {tmdb-9434}
High Fidelity (2000) {tmdb-243}
Knowing (2009) {tmdb-13811}
Nobody (2021) {tmdb-615457}
Old School (2003) {tmdb-11635}
Particle Fever (2013) {tmdb-202141}
Planes, Trains and Automobiles (1987) {tmdb-2609}
Pulp Fiction (1994) {tmdb-680}
Scott Pilgrim vs. the World (2010) {tmdb-22538}
Starship Troopers (1997) {tmdb-563}
The Adjustment Bureau (2011) {tmdb-38050}
The Big Lebowski (1998) {tmdb-115}
The Fifth Element (1997) {tmdb-18}
The Grand Budapest Hotel (2014) {tmdb-120467}
The Great Outdoors (1988) {tmdb-2617}
The Iron Giant (1999) {tmdb-10386}
The Lost Boys (1987) {tmdb-1547}
The Saint (1997) {tmdb-10003}
The Unbearable Weight of Massive Talent (2022) {tmdb-648579}
The Wizard (1989) {tmdb-183}
Tombstone (1993) {tmdb-11969}
Uncle Buck (1989) {tmdb-2616}
Weird Science (1985) {tmdb-11814}
Zoolander (2001) {tmdb-9398}
```

---

## Prerequisites (verify on target Mac before first build)

```bash
# Install CLI tools
brew install --cask makemkv
brew install handbrake          # formula, not cask — gives HandBrakeCLI

# Confirm binary paths
which makemkvcon
which HandBrakeCLI

# Create SSD folder structure
mkdir -p "/Volumes/MediaSSD/Plex Media/Movies"
mkdir -p "/Volumes/MediaSSD/Plex Media/TV Shows"
mkdir -p "/Volumes/MediaSSD/Plex Media/Working/ripping"
mkdir -p "/Volumes/MediaSSD/Plex Media/Working/encoding"
```

---

## Deployment notes

- The app **cannot** be on the Mac App Store (sandbox is disabled).
- After building and copying to `/Applications`, run:
  ```bash
  xattr -cr /Applications/Changeover.app
  ```
- Launch once manually to trigger Login Item registration via `SMAppService`.
- Verify under **System Settings → General → Login Items & Extensions**.
