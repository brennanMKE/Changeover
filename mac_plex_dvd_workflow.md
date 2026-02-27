# macOS → Plex DVD Ripping Workflow (Repeatable Guide)

This document describes a **repeatable, Mac‑friendly workflow** for converting physical DVD media into a Plex‑ready digital library using **MakeMKV**, **HandBrake**, and **FileBot**.

This guide reflects a *working, tested process* and avoids tools or steps that are unreliable on macOS.

---

## 1. Tool Installation (via Homebrew)

The essential tools are installed using Homebrew:

```bash
brew install --cask makemkv
brew install --cask handbrake
brew install --cask filebot
```

Each command installs a corresponding macOS application:

- **MakeMKV.app**
- **HandBrake.app**
- **FileBot.app**

These applications are installed into:

```
/Applications
```

### Gatekeeper Notes
- macOS Gatekeeper may block these apps on first launch.
- You may need to:
  - Right‑click → **Open**, or
  - Approve them in **System Settings → Privacy & Security**
- FileBot requires a **paid license** for renaming/matching to work.

---

## 2. Media Folder Structure

All media lives on an external SSD.

Recommended structure:

```
MediaSSD/
  Plex Media/
    Movies/
    TV Shows/
    Unsorted Rips/
```

Purpose:
- **Unsorted Rips**: temporary working area
- **Movies / TV Shows**: final Plex library folders

Plex should only be pointed at **Movies** and **TV Shows**.

---

## 3. Ripping a DVD with MakeMKV

### 3.1 Insert DVD
Insert a DVD into the optical drive.

macOS DVD Player should be disabled so it does not auto‑launch.

---

### 3.2 Open Disc in MakeMKV
1. Launch **MakeMKV**
2. Choose:
   - **File → Open Disc**
3. MakeMKV scans the disc and displays available titles.

---

### 3.3 Select the Correct Title

- Select the **largest title** (this is almost always the main movie)
- This title usually:
  - Has the most chapters
  - Is ~4–6 GB on DVD

For that title:
- ✅ Keep **English** and **Spanish** audio tracks
- ❌ Uncheck:
  - Alternate angles
  - Bonus features
  - Short clips (special features)

---

### 3.4 Set Output Folder

Set MakeMKV output directory to:

```
MediaSSD/Plex Media/Unsorted Rips
```

---

### 3.5 Create MKV
Click **Make MKV**.

Result:
- One `.mkv` file containing the full movie
- Example:
  ```
  C1_t00.mkv
  ```

---

## 4. Convert MKV → MP4 with HandBrake

HandBrake is used to **compress and convert** the MKV into a Plex‑friendly MP4.

---

### 4.1 Open MKV in HandBrake
1. Launch **HandBrake**
2. Click **Open Source**
3. Select the `.mkv` file from:
   ```
   MediaSSD/Plex Media/Unsorted Rips
   ```

---

### 4.2 Choose Preset

For DVDs, use:

- **General → HQ 480p30**

This:
- Preserves DVD quality
- Reduces file size significantly
- Direct Plays on Apple TV via Plex

---

### 4.3 Set Output

Output file:
- Format: **MP4**
- Location:
  ```
  MediaSSD/Plex Media/Unsorted Rips
  ```

---

### 4.4 Encode
Click **Start Encode**.

After completion:
- Verify playback of the MP4
- Confirm it is the **entire movie**
- Confirm audio tracks are correct

Only continue after verification.

---

## 5. Rename & Move with FileBot

FileBot is used **only for renaming and organizing**, not ripping or metadata storage.

---

### 5.1 Open FileBot
Launch **FileBot** and open the **Rename** panel.

---

### 5.2 Add MP4 File
Drag the verified `.mp4` file into FileBot.

---

### 5.3 Match as Movie
1. Click **Match**
2. Select **Movies**
3. Enter the movie title **with year**:
   ```
   Movie Title (YYYY)
   ```
   Example:
   ```
   The Grand Budapest Hotel (2014)
   ```

4. FileBot queries **The Movie Database (TMDB)**

---

### 5.4 Apply Movie Preset

- Use the built‑in **Movie / Plex** format
- FileBot may include the TMDB ID in the folder name

This is acceptable and optional; Plex does not require it.

---

### 5.5 Rename & Move

FileBot creates:

```
MediaSSD/Plex Media/Movies/
  Movie Title (Year)/
    Movie Title (Year).mp4
```

Example:

```
MediaSSD/Plex Media/Movies/
  The Grand Budapest Hotel (2014)/
    The Grand Budapest Hotel (2014).mp4
```

---

## 6. Plex Library Update

### 6.1 Plex Folder Configuration
Plex libraries should point to:

- Movies → `MediaSSD/Plex Media/Movies`
- TV Shows → `MediaSSD/Plex Media/TV Shows`

Do **not** include `Unsorted Rips`.

---

### 6.2 Scan Library
In Plex Web:

- Library → **Movies**
- Click **⋯ → Scan Library Files**

Plex will:
- Detect the new movie
- Download posters, artwork, and metadata
- Make it available on Apple TV

---

## 7. Repeatable Workflow Summary

For each DVD:

1. Rip with **MakeMKV** → `.mkv`
2. Convert with **HandBrake** → `.mp4`
3. Verify playback
4. Rename & move with **FileBot**
5. Scan Plex library

---

## 8. Notes & Recommendations

- Movies are easy to manage manually; FileBot is most valuable for **TV shows**
- Keep original MKVs only if you want archival copies
- Avoid overwriting files Plex is currently using
- This workflow favors **reliability over automation** on macOS

---

## 9. Future Expansion

This document can be extended to cover:
- TV show DVDs (episode mapping)
- Blu‑ray discs
- Storage planning
- Plex optimization & maintenance
