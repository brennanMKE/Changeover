# Changeover

> The name comes from the movie theater practice of switching between projectors as one reel ends and the next begins — keeping the show running without interruption.

A native macOS menu bar app that automates the DVD-to-Plex workflow.

Insert a DVD, search for the movie via TMDB, and Changeover rips it with MakeMKV, encodes it with HandBrake, and drops the finished file directly into your Plex Movies library — named and organized exactly the way Plex expects.

## Features

- Menu bar app with no Dock icon
- Automatic DVD detection via `NSWorkspace` volume mount notifications
- TMDB movie search with poster art and year
- Plex-compatible folder and file naming: `Title (Year) {tmdb-ID}` / `Title (Year).mp4`
- Streams rip and encode progress in real time
- Launches at login via `SMAppService`

## Requirements

- macOS 26.2 or later
- [MakeMKV](https://www.makemkv.com) — provides `makemkvcon`
- [HandBrake CLI](https://handbrake.fr) — provides `HandBrakeCLI`
- A TMDB API key

Install the CLI tools via Homebrew:

```bash
brew install --cask makemkv
brew install handbrake
```

Verify the binary paths:

```bash
which makemkvcon      # /opt/homebrew/bin/makemkvcon
which HandBrakeCLI    # /opt/homebrew/bin/HandBrakeCLI
```

## First Launch

On first launch, Changeover opens the Settings window automatically. Set your **Plex Media Root** — the folder that contains your `Movies` and `TV Shows` folders (e.g. `/Volumes/MediaSSD/Plex Media`). All working and library paths are derived from this single location:

| Path | Purpose |
|---|---|
| `<root>/Movies` | Finished Plex Movies library |
| `<root>/TV Shows` | Finished Plex TV Shows library |
| `<root>/Working/ripping` | Temporary MKV output from MakeMKV |
| `<root>/Working/encoding` | Temporary MP4 output from HandBrake |

Create the folder structure before first use:

```bash
mkdir -p "/Volumes/MediaSSD/Plex Media/Movies"
mkdir -p "/Volumes/MediaSSD/Plex Media/TV Shows"
mkdir -p "/Volumes/MediaSSD/Plex Media/Working/ripping"
mkdir -p "/Volumes/MediaSSD/Plex Media/Working/encoding"
```

## Building

### TMDB API Key

1. Get a free API key from [themoviedb.org](https://www.themoviedb.org/settings/api).
2. Copy `Secrets.xcconfig.example` to `Secrets.xcconfig` (gitignored) and add your key:

```
TMDB_API_KEY = your_key_here
```

### Xcode

Open `Changeover.xcodeproj` in Xcode 26.2, select the **Changeover** scheme, and build.

### Deployment

The app cannot be distributed via the Mac App Store (sandbox is disabled). After copying to `/Applications`:

```bash
xattr -cr /Applications/Changeover.app
```

Launch once manually to register the Login Item. Verify under **System Settings → General → Login Items & Extensions**.

## Plex Naming Convention

Every movie is placed in a folder matching the format Plex uses for metadata matching:

```
Movies/
  Blade Runner (1982) {tmdb-78}/
    Blade Runner (1982).mp4
  Pulp Fiction (1994) {tmdb-680}/
    Pulp Fiction (1994).mp4
```

The TMDB ID in the folder name lets Plex unambiguously match metadata even for remakes or films with identical titles.

## Architecture

| File | Role |
|---|---|
| `AppDelegate.swift` | Menu bar icon, popover, window management, DVD monitor wiring |
| `AppSettings.swift` | `@Observable` settings backed by `UserDefaults` |
| `DVDMonitor.swift` | `NSWorkspace` disc detection |
| `DVDPipeline.swift` | Orchestrates rip → encode → move |
| `RipController.swift` | Shells out to `makemkvcon` |
| `EncodeController.swift` | Shells out to `HandBrakeCLI` |
| `PlexOrganizer.swift` | Moves encoded file into Plex folder structure |
| `TMDB/` | TMDB networking, models, and search view model |

The project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all types are `@MainActor` by default. The CLI controllers are `nonisolated static` so they run on the cooperative thread pool without blocking the main actor during long rip and encode operations.

## License

MIT — see [LICENSE](LICENSE).
