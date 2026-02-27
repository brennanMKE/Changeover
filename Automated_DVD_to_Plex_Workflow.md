# Automated DVD → MP4 → Plex Workflow (macOS)

**Generated:** 2026-02-27 06:59

This guide walks you step‑by‑step through building a semi‑automated DVD
ripping and encoding system on macOS using:

-   MakeMKV (CLI mode)
-   HandBrakeCLI
-   launchd automation
-   JSON job metadata
-   Automatic Plex folder placement

This workflow allows you to:

1.  Insert DVD
2.  Enter metadata once
3.  Automatically rip to MKV
4.  Automatically encode to MP4
5.  Automatically place into Plex folder structure

------------------------------------------------------------------------

# 1. Install Required Tools

## 1.1 Install Homebrew (if needed)

``` bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## 1.2 Install MakeMKV

``` bash
brew install --cask makemkv
```

Confirm:

``` bash
makemkvcon --version
```

## 1.3 Install HandBrakeCLI

IMPORTANT: Use the formula (not the cask):

``` bash
brew install handbrake
```

Verify:

``` bash
HandBrakeCLI --version
```

------------------------------------------------------------------------

# 2. Create Folder Structure

Assume your external SSD is mounted at:

    /Volumes/MediaSSD

Create:

``` bash
mkdir -p "/Volumes/MediaSSD/Plex Media/Movies"
mkdir -p "/Volumes/MediaSSD/Plex Media/TV Shows"
mkdir -p "/Volumes/MediaSSD/Plex Media/Jobs/incoming"
mkdir -p "/Volumes/MediaSSD/Plex Media/Jobs/ripping"
mkdir -p "/Volumes/MediaSSD/Plex Media/Jobs/encoding"
mkdir -p "/Volumes/MediaSSD/Plex Media/Jobs/done"
mkdir -p "/Volumes/MediaSSD/Plex Media/Jobs/failed"
```

------------------------------------------------------------------------

# 3. Script Directory

``` bash
mkdir -p ~/plexdvd/bin
chmod +x ~/plexdvd/bin/*.sh
```

------------------------------------------------------------------------

# 4. LaunchAgent: Disc Detection

Create:

    ~/Library/LaunchAgents/com.yourname.plexdvd.discwatch.plist

Paste:

``` xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.yourname.plexdvd.discwatch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>~/plexdvd/bin/dvd_on_insert.sh</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>/Volumes</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

Load:

``` bash
launchctl load ~/Library/LaunchAgents/com.yourname.plexdvd.discwatch.plist
```

------------------------------------------------------------------------

# 5. LaunchAgent: Encoder Worker

Create:

    ~/Library/LaunchAgents/com.yourname.plexdvd.encoder.plist

Paste:

``` xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.yourname.plexdvd.encoder</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>~/plexdvd/bin/encode_worker.sh</string>
  </array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

Load:

``` bash
launchctl load ~/Library/LaunchAgents/com.yourname.plexdvd.encoder.plist
```

------------------------------------------------------------------------

# 6. Final Plex Folder Structure

Movies:

    Movies/
      Movie Title (Year) {tmdb-12345}/
        Movie Title (Year).mp4

TV:

    TV Shows/
      Show Name {tmdb-12345}/
        Season 01/
          Show Name - S01E01.mp4

------------------------------------------------------------------------

# 7. HandBrake Encoding Settings

Current script uses:

-   x264 RF 21
-   MP4 container
-   AAC + AC3 audio
-   Chapter markers
-   All subtitles

Adjust RF:

-   19 → higher quality
-   21 → balanced
-   22--23 → smaller file

------------------------------------------------------------------------

# 8. Job Lifecycle

Monitor:

    /Volumes/MediaSSD/Plex Media/Jobs/

Folders move:

incoming → ripping → encoding → done

------------------------------------------------------------------------

# 9. Future Enhancements

Possible improvements:

-   TMDB API auto‑lookup
-   Plex API auto library scan
-   Larger-title auto detection logic
-   Desktop GUI wrapper app
-   Completion notifications

------------------------------------------------------------------------

# 10. Summary

Insert disc → enter metadata → swap discs → walk away.

You now have a queue-based, automated DVD → MP4 → Plex workflow.
