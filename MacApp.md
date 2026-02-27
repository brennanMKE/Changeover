# PlexDVD Mac App — Build & Deployment Guide

**Goal:** A native macOS menu bar app that automatically activates when a DVD is
inserted, prompts for movie metadata, then rips and encodes the disc to your Plex
library — hands-free after the first form.

---

## Overview

```
DVD inserted
    └─▶ App activates / window appears
         └─▶ User enters: Movie Title, Year, TMDB ID (optional)
              └─▶ makemkvcon rips largest title → .mkv
                   └─▶ HandBrakeCLI encodes → .mp4
                        └─▶ File moved to Plex folder structure
                             └─▶ Notification: "Done — scan Plex"
```

The app runs as a **menu bar app** (no Dock icon) and starts automatically on
login. It watches for disc mounts using `NSWorkspace` notifications. When a DVD
is detected, a metadata entry sheet appears. All processing runs in the
background with a live progress view.

---

## 1. Prerequisites

### 1.1 On Your MacBook (build machine)

- Xcode 15 or later
- macOS 14 Sonoma or later (deployment target: macOS 13+)

### 1.2 On the Target Mac (where DVDs are ripped)

Install CLI tools via Homebrew:

```bash
# MakeMKV (provides makemkvcon)
brew install --cask makemkv

# HandBrakeCLI
brew install handbrake

# Verify both are reachable
makemkvcon --version
HandBrakeCLI --version
```

> **Note:** `brew install handbrake` (formula) gives `HandBrakeCLI`.
> `brew install --cask handbrake` gives HandBrake.app only. Use the formula.

### 1.3 External SSD

Mount your SSD and create the Plex folder structure:

```bash
mkdir -p "/Volumes/MediaSSD/Plex Media/Movies"
mkdir -p "/Volumes/MediaSSD/Plex Media/TV Shows"
mkdir -p "/Volumes/MediaSSD/Plex Media/Working/ripping"
mkdir -p "/Volumes/MediaSSD/Plex Media/Working/encoding"
```

---

## 2. Xcode Project Setup

### 2.1 Create the Project

1. Open Xcode → **File → New → Project**
2. Choose **macOS → App**
3. Settings:
   - **Product Name:** `PlexDVD`
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Bundle ID:** `com.yourname.plexdvd`
4. Save the project on your MacBook

### 2.2 App Target Settings

In the project target → **General**:

| Setting | Value |
|---|---|
| Deployment Target | macOS 13.0 |
| App Category | Utilities |

### 2.3 Info.plist Keys

Add these keys to `Info.plist`:

```xml
<!-- Run as menu bar app — no Dock icon -->
<key>LSUIElement</key>
<true/>

<!-- Allow app to be a Login Item -->
<key>LSBackgroundOnly</key>
<false/>
```

### 2.4 Entitlements

In `PlexDVD.entitlements`:

```xml
<!-- Required to shell out to makemkvcon and HandBrakeCLI -->
<key>com.apple.security.app-sandbox</key>
<false/>
```

> Disabling the sandbox is necessary so the app can run arbitrary CLI tools and
> write to arbitrary paths on the external SSD. This means the app cannot be
> distributed on the Mac App Store — it is a private tool.

---

## 3. Project File Structure

```
PlexDVD/
  PlexDVDApp.swift          # App entry point, menu bar setup
  AppDelegate.swift         # NSApplicationDelegate, login item registration
  DVDMonitor.swift          # NSWorkspace disc detection
  MetadataEntryView.swift   # SwiftUI form: title, year, TMDB ID
  ProgressView.swift        # Live log output and progress bar
  RipController.swift       # Shells out to makemkvcon
  EncodeController.swift    # Shells out to HandBrakeCLI
  PlexOrganizer.swift       # Moves encoded file to Plex folder
  Config.swift              # Paths, encoding settings
```

---

## 4. Core Implementation

### 4.1 `Config.swift` — Paths and Settings

```swift
import Foundation

enum Config {
    // Update these to match your SSD mount point
    static let plexMoviesPath    = "/Volumes/MediaSSD/Plex Media/Movies"
    static let plexTVPath        = "/Volumes/MediaSSD/Plex Media/TV Shows"
    static let workingRipPath    = "/Volumes/MediaSSD/Plex Media/Working/ripping"
    static let workingEncodePath = "/Volumes/MediaSSD/Plex Media/Working/encoding"

    // CLI tool paths (installed via Homebrew)
    static let makemkvconPath    = "/usr/local/bin/makemkvcon"   // Intel
    // static let makemkvconPath = "/opt/homebrew/bin/makemkvcon" // Apple Silicon
    static let handbrakePath     = "/usr/local/bin/HandBrakeCLI"
    // static let handbrakePath  = "/opt/homebrew/bin/HandBrakeCLI"

    // HandBrakeCLI encoding settings
    static let videoQuality      = "21"   // RF 21 — balanced; lower = better quality
    static let audioEncoder      = "copy:aac,copy:ac3"
}
```

> **Important:** Homebrew installs to `/opt/homebrew/bin` on Apple Silicon Macs
> and `/usr/local/bin` on Intel Macs. Update `Config.swift` to match the
> target Mac's architecture.
>
> Run `which makemkvcon` and `which HandBrakeCLI` on the target Mac to confirm.

---

### 4.2 `PlexDVDApp.swift` — App Entry Point

```swift
import SwiftUI

@main
struct PlexDVDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — menu bar only
        Settings { EmptyView() }
    }
}
```

---

### 4.3 `AppDelegate.swift` — Menu Bar Setup

```swift
import AppKit
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var dvdMonitor: DVDMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: "PlexDVD")
            button.action = #selector(togglePopover)
        }

        // Popover for status / manual trigger
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: StatusMenuView())
        popover.behavior = .transient
        self.popover = popover

        // Start monitoring for disc insertion
        dvdMonitor = DVDMonitor()
        dvdMonitor?.onDVDInserted = { [weak self] in
            self?.showMetadataEntry()
        }

        // Register as Login Item so app starts on boot
        registerLoginItem()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func showMetadataEntry() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DVD Inserted — Enter Movie Info"
        window.center()
        window.contentView = NSHostingView(rootView: MetadataEntryView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func registerLoginItem() {
        // Registers this app to launch at login (macOS 13+)
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }
}
```

---

### 4.4 `DVDMonitor.swift` — Disc Detection

```swift
import AppKit

class DVDMonitor {
    var onDVDInserted: (() -> Void)?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeMounted(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    @objc func volumeMounted(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let url = info[NSWorkspace.volumeURLUserInfoKey] as? URL
        else { return }

        // Check if the mounted volume is a DVD (VIDEO_TS folder present)
        let videoTS = url.appendingPathComponent("VIDEO_TS")
        if FileManager.default.fileExists(atPath: videoTS.path) {
            DispatchQueue.main.async {
                self.onDVDInserted?()
            }
        }
    }
}
```

---

### 4.5 `MetadataEntryView.swift` — Metadata Form

```swift
import SwiftUI

struct MetadataEntryView: View {
    @State private var title  = ""
    @State private var year   = ""
    @State private var tmdbID = ""
    @State private var isProcessing = false
    @State private var logOutput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Movie Information")
                .font(.headline)

            LabeledContent("Title") {
                TextField("e.g. The Grand Budapest Hotel", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Year") {
                TextField("e.g. 2014", text: $year)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            LabeledContent("TMDB ID") {
                TextField("Optional — e.g. 120467", text: $tmdbID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            if isProcessing {
                ScrollView {
                    Text(logOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
                .background(Color(.textBackgroundColor))
                .cornerRadius(6)
            }

            HStack {
                Spacer()
                Button("Start Ripping") {
                    startPipeline()
                }
                .disabled(title.isEmpty || year.isEmpty || isProcessing)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    func startPipeline() {
        isProcessing = true
        let metadata = MovieMetadata(
            title: title,
            year: year,
            tmdbID: tmdbID.isEmpty ? nil : tmdbID
        )

        Task {
            let pipeline = DVDPipeline(metadata: metadata) { log in
                DispatchQueue.main.async { logOutput += log + "\n" }
            }
            await pipeline.run()
        }
    }
}

struct MovieMetadata {
    let title:  String
    let year:   String
    let tmdbID: String?

    /// e.g. "The Grand Budapest Hotel (2014)" or "The Grand Budapest Hotel (2014) {tmdb-120467}"
    var folderName: String {
        if let id = tmdbID, !id.isEmpty {
            return "\(title) (\(year)) {tmdb-\(id)}"
        }
        return "\(title) (\(year))"
    }

    /// e.g. "The Grand Budapest Hotel (2014).mp4"
    var fileName: String {
        return "\(title) (\(year)).mp4"
    }
}
```

---

### 4.6 `DVDPipeline.swift` — Orchestrates Rip → Encode → Move

```swift
import Foundation

actor DVDPipeline {
    let metadata: MovieMetadata
    let log: (String) -> Void

    init(metadata: MovieMetadata, log: @escaping (String) -> Void) {
        self.metadata = metadata
        self.log      = log
    }

    func run() async {
        log("Starting pipeline for: \(metadata.folderName)")

        // Step 1: Rip
        let mkv = await RipController.rip(log: log)
        guard let mkvPath = mkv else {
            log("ERROR: Ripping failed. Check MakeMKV.")
            return
        }

        // Step 2: Encode
        let mp4Path = Config.workingEncodePath + "/" + metadata.fileName
        let success = await EncodeController.encode(input: mkvPath, output: mp4Path, log: log)
        guard success else {
            log("ERROR: Encoding failed. Check HandBrakeCLI.")
            return
        }

        // Step 3: Organize into Plex folder
        PlexOrganizer.move(encodedFile: mp4Path, metadata: metadata, log: log)

        log("Done! Scan your Plex Movies library to pick up the new title.")
    }
}
```

---

### 4.7 `RipController.swift` — Runs makemkvcon

```swift
import Foundation

enum RipController {
    /// Rips the first DVD found to the working rip directory.
    /// Returns the path of the resulting .mkv file, or nil on failure.
    static func rip(log: @escaping (String) -> Void) async -> String? {
        return await withCheckedContinuation { continuation in
            log("Ripping disc with makemkvcon...")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: Config.makemkvconPath)
            process.arguments = [
                "mkv",
                "disc:0",          // First optical drive
                "all",             // All titles (we'll pick the largest)
                Config.workingRipPath
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                    log(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    // Find the largest .mkv produced
                    let largest = largestMKV(in: Config.workingRipPath)
                    continuation.resume(returning: largest)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
            } catch {
                log("Failed to launch makemkvcon: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    private static func largestMKV(in directory: String) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        return files
            .filter { $0.hasSuffix(".mkv") }
            .map    { (directory as NSString).appendingPathComponent($0) }
            .max    { a, b in
                let sizeA = (try? fm.attributesOfItem(atPath: a)[.size] as? Int) ?? 0
                let sizeB = (try? fm.attributesOfItem(atPath: b)[.size] as? Int) ?? 0
                return sizeA < sizeB
            }
    }
}
```

---

### 4.8 `EncodeController.swift` — Runs HandBrakeCLI

```swift
import Foundation

enum EncodeController {
    static func encode(input: String, output: String, log: @escaping (String) -> Void) async -> Bool {
        return await withCheckedContinuation { continuation in
            log("Encoding with HandBrakeCLI...")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: Config.handbrakePath)
            process.arguments = [
                "--input",   input,
                "--output",  output,
                "--format",  "av_mp4",
                "--quality", Config.videoQuality,
                "--aencoder", Config.audioEncoder,
                "--subtitle", "scan",    // Add forced subtitles
                "--markers"              // Chapter markers
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                    log(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                log("Failed to launch HandBrakeCLI: \(error)")
                continuation.resume(returning: false)
            }
        }
    }
}
```

---

### 4.9 `PlexOrganizer.swift` — Move to Plex Folder

```swift
import Foundation

enum PlexOrganizer {
    static func move(encodedFile: String, metadata: MovieMetadata, log: @escaping (String) -> Void) {
        let fm = FileManager.default

        // Build destination:  Movies/Movie Title (Year)/Movie Title (Year).mp4
        let folderPath = (Config.plexMoviesPath as NSString)
            .appendingPathComponent(metadata.folderName)
        let destPath   = (folderPath as NSString)
            .appendingPathComponent(metadata.fileName)

        do {
            try fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destPath) {
                try fm.removeItem(atPath: destPath)
            }
            try fm.moveItem(atPath: encodedFile, toPath: destPath)
            log("Moved to: \(destPath)")
        } catch {
            log("ERROR moving file: \(error)")
        }
    }
}
```

---

## 5. Building the App

### 5.1 Confirm Correct Architecture

On your MacBook, check whether the **target Mac** is Intel or Apple Silicon:

```bash
# Run this on the target Mac
uname -m
# arm64  = Apple Silicon (M1/M2/M3)
# x86_64 = Intel
```

Update `Config.swift` tool paths accordingly before building.

### 5.2 Build in Xcode

1. Open `PlexDVD.xcodeproj` in Xcode
2. Set the scheme destination to **My Mac**
3. **Product → Archive**
4. In the Organizer → **Distribute App → Copy App**
5. Save the exported `PlexDVD.app` somewhere accessible (Desktop, USB drive, etc.)

---

## 6. Installing on the Target Mac

### 6.1 Copy the App

Copy `PlexDVD.app` to `/Applications` on the target Mac.

### 6.2 Clear Gatekeeper Quarantine

Since the app is not notarized, remove the quarantine flag:

```bash
xattr -cr /Applications/PlexDVD.app
```

### 6.3 Launch the App Once Manually

```bash
open /Applications/PlexDVD.app
```

The menu bar disc icon should appear. Grant any permissions macOS prompts for.

### 6.4 Add to Login Items

The app auto-registers via `SMAppService` on first launch. Verify in:

**System Settings → General → Login Items & Extensions**

`PlexDVD` should appear under "Open at Login."

If it does not appear automatically, add it manually by clicking **+** and
selecting `/Applications/PlexDVD.app`.

---

## 7. Verifying the Full Workflow

1. Insert a DVD
2. The metadata window should appear within a few seconds
3. Enter the movie title and year; optionally add the TMDB ID
4. Click **Start Ripping**
5. Watch the log output in the progress area
6. When complete, verify the file exists at:

```
/Volumes/MediaSSD/Plex Media/Movies/
  Movie Title (Year)/
    Movie Title (Year).mp4
```

7. In Plex Web: **Movies library → ⋯ → Scan Library Files**

---

## 8. Encoding Settings Reference

The app uses these HandBrakeCLI defaults (configured in `Config.swift`):

| Setting | Value | Notes |
|---|---|---|
| Encoder | x264 | Good compatibility |
| RF Quality | 21 | Balanced; 19 = higher quality, 23 = smaller file |
| Container | MP4 | Direct Play on Apple TV |
| Audio | AAC + AC3 passthrough | Stereo + surround |
| Subtitles | Forced scan | Adds forced subtitles only |
| Chapters | Yes | Enables chapter navigation |

---

## 9. Plex Folder Structure

```
/Volumes/MediaSSD/Plex Media/
  Movies/
    The Grand Budapest Hotel (2014)/
      The Grand Budapest Hotel (2014).mp4

    The Grand Budapest Hotel (2014) {tmdb-120467}/   ← with TMDB ID
      The Grand Budapest Hotel (2014).mp4

  Working/
    ripping/     ← makemkvcon writes here
    encoding/    ← HandBrakeCLI writes here (cleaned up after move)
```

---

## 10. Troubleshooting

| Problem | Solution |
|---|---|
| Menu bar icon doesn't appear | `xattr -cr /Applications/PlexDVD.app`, relaunch |
| DVD inserted but no window appears | Open Console.app, filter by `PlexDVD`, look for errors |
| `makemkvcon` not found | Run `which makemkvcon` on target Mac; update `Config.swift` path |
| `HandBrakeCLI` not found | Run `which HandBrakeCLI`; confirm `brew install handbrake` (formula, not cask) |
| Rip produces empty folder | MakeMKV beta key may have expired — open MakeMKV.app and renew key |
| Encoding fails | Test HandBrakeCLI manually: `HandBrakeCLI --input file.mkv --output test.mp4 --preset "HQ 480p30 Surround"` |
| File not in Plex after scan | Verify folder/filename match Plex naming exactly, including parentheses |

---

## 11. Future Enhancements

- **TMDB auto-lookup:** Query TMDB API by title + year and pre-fill the ID field
- **TV show support:** Add a "Type" toggle (Movie / TV Show) with season/episode fields
- **Plex API scan:** Trigger a Plex library scan automatically via Plex API after move
- **Ejection:** Eject disc automatically after ripping completes (`drutil eject`)
- **Notifications:** Send a macOS notification when encoding finishes
- **Working folder cleanup:** Auto-delete `.mkv` from working folder after successful encode
