# Changeover — Implementation Plan

**App name:** Changeover
**Goal:** Native macOS menu bar app that detects DVD insertion, searches TMDB for the movie (with poster art), then automatically rips → encodes → places the file into a Plex-ready folder structure.

Reference docs: `MacApp.md`, `Automated_DVD_to_Plex_Workflow.md`, `mac_plex_dvd_workflow.md`, `tmdb_swift_mac_app_guide.md`, `Movies.txt`

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

- [ ] **1.1** Update `Info.plist` — add `LSUIElement = true` (menu bar only, no Dock icon)
- [ ] **1.2** Update `Info.plist` — add `LSBackgroundOnly = false` (allow windows to appear)
- [ ] **1.3** Disable the app sandbox in `Changeover.entitlements` (`com.apple.security.app-sandbox = false`) — required to shell out to `makemkvcon` and `HandBrakeCLI` and write to arbitrary SSD paths
- [ ] **1.4** Rewrite `ChangeoverApp.swift` — replace `WindowGroup` with `Settings { EmptyView() }` and wire in `AppDelegate` via `@NSApplicationDelegateAdaptor`
- [ ] **1.5** Create `AppDelegate.swift` — `NSApplicationDelegate` that sets up the menu bar `NSStatusItem` (disc icon), attaches an `NSPopover` for status, starts `DVDMonitor`, and registers the app as a Login Item via `SMAppService`

---

## Phase 2 — Configuration

Centralize all paths, encoding settings, and API key access.

- [ ] **2.1** Create `Config.swift` — defines:
  - Plex Movies path (`/Volumes/MediaSSD/Plex Media/Movies`)
  - Plex TV Shows path
  - Working/ripping path
  - Working/encoding path
  - `makemkvcon` binary path (comment both Intel and Apple Silicon variants)
  - `HandBrakeCLI` binary path
  - RF quality value (default `21`)
  - Audio encoder string
  - TMDB API key — read from `Bundle.main.infoDictionary["TMDB_API_KEY"]` (populated via xcconfig)

- [ ] **2.2** Create `Secrets.xcconfig` (not committed to git) — single line:
  ```
  TMDB_API_KEY = your_key_here
  ```
  Set the project's build configuration to use this file (Project → Info → Configurations). Add a corresponding entry in `Info.plist`:
  ```xml
  <key>TMDB_API_KEY</key>
  <string>$(TMDB_API_KEY)</string>
  ```
  Add `Secrets.xcconfig` to `.gitignore`.

> **Note:** `TMDB_API_KEY` is already exported in `~/.zshrc`. For Xcode scheme runs, the xcconfig approach is more reliable than environment variables. Copy the key from your shell (`echo $TMDB_API_KEY`) into `Secrets.xcconfig`.

> **Note:** Run `which makemkvcon` and `which HandBrakeCLI` on the target Mac. Apple Silicon uses `/opt/homebrew/bin/`, Intel uses `/usr/local/bin/`.

---

## Phase 3 — Disc Detection

Watch for DVD mounts using `NSWorkspace` notifications.

- [ ] **3.1** Create `DVDMonitor.swift` — subscribes to `NSWorkspace.didMountNotification`, checks for a `VIDEO_TS` folder on the mounted volume to confirm it is a DVD (not a USB drive or disk image), then calls a callback on the main thread

---

## Phase 4 — TMDB Client

Networking layer for movie search and poster art. No UI yet — just the data layer.

- [ ] **4.1** Create `TMDBModels.swift` — `Codable` structs:
  - `TMDBSearchResponse` (page, results, total_pages, total_results)
  - `TMDBMovie: Identifiable` (id, title, release_date → `yearText`, poster_path)
  - `TMDBError: LocalizedError` (invalidURL, badResponse, decodingFailed, emptyQuery)

- [ ] **4.2** Create `TMDBClient.swift` — `final class` with:
  - `init(apiKey: String)`
  - `func searchMovies(query: String) async throws -> [TMDBMovie]` — calls `GET /3/search/movie`
  - `func posterURL(path: String?, size: String) -> URL?` — builds `https://image.tmdb.org/t/p/<size><path>`

- [ ] **4.3** Create `MovieSearchViewModel.swift` — `@MainActor ObservableObject`:
  - `@Published var query: String`
  - `@Published var results: [TMDBMovie]`
  - `@Published var isLoading: Bool`
  - `@Published var errorMessage: String?`
  - `@Published var selectedMovie: TMDBMovie?`
  - `func search() async`
  - `func posterURL(for:) -> URL?`

---

## Phase 5 — Movie Search UI

The metadata window: search field, poster results list, and rip trigger.

- [ ] **5.1** Create `MovieMetadata.swift` — plain struct constructed from a selected `TMDBMovie`:
  - `title: String`, `year: String`, `tmdbID: String` (all required — non-optional)
  - Computed `folderName: String` → `"Title (Year) {tmdb-ID}"`, e.g. `"Blade Runner (1982) {tmdb-78}"`
  - Computed `fileName: String` → `"Title (Year).mp4"`, e.g. `"Blade Runner (1982).mp4"`
  - These values drive the exact path: `Movies/<folderName>/<fileName>`

- [ ] **5.2** Create `MetadataEntryView.swift` — SwiftUI view:
  - Search bar (TextField + Search button / `.onSubmit`)
  - `ProgressView` spinner while loading
  - Error message label (red, shown on failure)
  - Results `List` — each row: `PosterThumb` (44×66 pt via `AsyncImage`) + title + year + TMDB ID; row shows the full Plex folder name that will be created (e.g. `Blade Runner (1982) {tmdb-78}`)
  - Selected row highlighted; tapping a row sets `selectedMovie`
  - **Start Ripping** button — disabled until a row is selected and no rip is in progress
  - Scrolling monospace log area — appears once ripping starts

- [ ] **5.3** Create `PosterThumb.swift` (or inline in MetadataEntryView) — `AsyncImage` wrapper showing a spinner while loading, poster on success, SF Symbol placeholder on failure

- [ ] **5.4** Wire `AppDelegate.showMetadataEntry()` — open `MetadataEntryView` in a plain `NSWindow` (420×560 pt) when `DVDMonitor` fires; bring window to front

---

## Phase 6 — Ripping

Shell out to `makemkvcon` to rip the disc.

- [ ] **6.1** Create `RipController.swift` — runs `makemkvcon mkv disc:0 all <workingRipPath>` as a `Process`, streams stdout/stderr line-by-line to the log callback, and on success returns the path of the **largest `.mkv`** file found in the working rip directory

---

## Phase 7 — Encoding

Shell out to `HandBrakeCLI` to encode the MKV to MP4.

- [ ] **7.1** Create `EncodeController.swift` — runs `HandBrakeCLI` with settings from `Config.swift` (`--format av_mp4`, `--quality`, `--aencoder`, `--subtitle scan`, `--markers`), streams output to the log callback, returns `Bool` success

---

## Phase 8 — Plex Organization

Move the encoded file into the correct Plex folder structure.

- [ ] **8.1** Create `PlexOrganizer.swift` — creates `Movies/<folderName>/` on the SSD, moves the encoded `.mp4` there, logs result; overwrites any existing file at that path

---

## Phase 9 — Pipeline

Tie rip → encode → organize into a single async flow.

- [ ] **9.1** Create `DVDPipeline.swift` — Swift `actor` that calls `RipController`, `EncodeController`, and `PlexOrganizer` in sequence; logs each stage; handles errors at each step without crashing
- [ ] **9.2** Connect `MetadataEntryView` — on **Start Ripping** tap, construct `MovieMetadata` from `selectedMovie` (title from TMDB, year from `release_date`, tmdbID from `id`), run `DVDPipeline`, stream log lines into the view's log area
- [ ] **9.3** Final output path logged on completion — e.g. `✓ Moved to: /Volumes/MediaSSD/Plex Media/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4`

---

## Phase 10 — Status Menu

Give the menu bar icon something useful to show.

- [ ] **10.1** Create `StatusMenuView.swift` — SwiftUI view shown in the popover when the user clicks the menu bar disc icon; shows current status (Idle / Ripping / Encoding) and a **Quit** button

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
