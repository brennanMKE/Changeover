#!/usr/bin/env zsh
# capture-disc.sh — capture a HandBrakeCLI scan of the disc currently in the
# drive on the rip host (joe), save it as a #0055 corpus fixture, and print a
# summary. This is how every real disc that goes through the app should be
# preserved before it leaves the drive.
#
# Usage:
#   Tools/capture-disc.sh [slug]
#   CHANGEOVER_HOST=joe Tools/capture-disc.sh dragon-tattoo
#
# slug defaults to a kebab-cased form of the mounted volume name.
#
# Produces, under ChangeoverTests/Fixtures/discs/<slug>/:
#   scan.json         stdout of `HandBrakeCLI --scan --title 0 --min-duration 1 --json`
#   scan.stderr.txt   stderr of the same run, on a SEPARATE stream — #0039
#                     found that a merged stdout+stderr capture can splice
#                     HandBrake's chatty log text into the middle of the JSON
#                     and silently corrupt it. Never merge these two files.
#   disc.json         metadata plus the expectations DiscCorpusTests asserts.
#                     `reviewed: false` until a human confirms it; see below.
#   lsdvd.json        lsdvd -x -Oj output — kept now, not discarded (§8.2)
#   ifo/*.IFO         byte-exact copies of the disc's IFO tables. Never
#                     scrambled, tiny, and what menu intelligence reads.
#   menus/structure.json  Tools/menudump's output: menu PGCs, button
#                     rectangles and their raw 8-byte VM commands (§8.3)
#   menus/stills/*.jpg    one still per menu PGC
#   menus/ocr.json    Vision's observations on every still, with boxes
#   menus/derived.json    tiers 1-2 resolved: play button, chapter names,
#                     language lists, tv signal, title text
#
# VERSION 2 (docs/menu-intelligence.md §8.5). `disc.json` now carries
# `formatVersion: 2`; a manifest with no `formatVersion` is a version-1
# capture and DiscCorpusTests decodes it exactly as before. A format change
# is a re-capture, never a migration script — the discs are permanent, so an
# old capture is refreshed the next time that disc is in the drive.
#
# Everything under `menus/` is optional as a set. The menu half of this
# script is enrichment: if the helper will not build, if the disc has no
# menus, if `ffmpeg` or `libdvdread` is not on the host, the capture still
# writes scan.json and disc.json and says in the summary what it could not
# get. Nothing here can fail a capture, and nothing here is on the rip path.
#
# What this script fills in automatically: title count, HandBrake's own
# MainFeature index, and the feature title's raw duration/chapter count. What
# it deliberately leaves for a human: whether the disc is a Play All (TV
# season) disc, and the audio-track/subtitle-group counts — those come from
# AudioTrackOptions.options(for:) and SubtitleGrouping.groups(for:), real app
# dedup logic this script does not reimplement. Fill those in by hand, then
# flip `reviewed` to true; DiscCorpusTests refuses an unreviewed manifest, so
# a wrong guess here can't silently pin a wrong behaviour.

set -euo pipefail

HOST="${CHANGEOVER_HOST:-joe}"
HANDBRAKE_PATH="${CHANGEOVER_HANDBRAKE_PATH:-/opt/homebrew/bin/HandBrakeCLI}"
# Absolute, for the same reason HANDBRAKE_PATH is: a non-interactive ssh shell
# does not have Homebrew on its PATH, and a bare `lsdvd` silently recorded a
# null disc id on every capture (found on bloodsport, 2026-09-18).
LSDVD_PATH="${CHANGEOVER_LSDVD_PATH:-/opt/homebrew/bin/lsdvd}"
FFMPEG_PATH="${CHANGEOVER_FFMPEG_PATH:-/opt/homebrew/bin/ffmpeg}"
REPO_ROOT="${0:A:h}/.."
FIXTURES="$REPO_ROOT/ChangeoverTests/Fixtures/discs"
BUILD_DIR="$REPO_ROOT/build/capture"
# Menu capture is opt-out rather than opt-in: a disc that passes through the
# drive without its menus is a disc that has to come back off the shelf.
CAPTURE_MENUS="${CHANGEOVER_CAPTURE_MENUS:-1}"

ssh_host() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

# --- identify the disc -------------------------------------------------------
# Prefer a volume that actually looks like a DVD (has VIDEO_TS), the same
# signal DVDMonitor uses; fall back to "the one volume that isn't a known
# system mount" for a disc shaped some other way. Plain POSIX glob/`ls` —
# unlike the rest of this repo's tooling, this runs through whatever shell
# ssh hands the command to on the remote account, so it should not assume
# zsh.
VOLUME="$(ssh_host '
  for v in /Volumes/*/VIDEO_TS; do
    [ -d "$v" ] && { basename "$(dirname "$v")"; exit 0; }
  done
  ls /Volumes 2>/dev/null | grep -vxE "Macintosh HD|Media|Batty|makemkv_v[0-9.]+" | head -1
' 2>/dev/null)"
if [[ -z "$VOLUME" ]]; then
  echo "No disc volume mounted on $HOST." >&2
  exit 1
fi

SLUG="${1:-$(echo "$VOLUME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')}"
DEST="$FIXTURES/$SLUG"
REMOTE_DIR="changeover-fixtures/$SLUG"
echo "host:   $HOST"
echo "disc:   $VOLUME"
echo "slug:   $SLUG"
mkdir -p "$DEST"

MANIFEST_EXISTS=0
[[ -f "$DEST/disc.json" ]] && MANIFEST_EXISTS=1
(( MANIFEST_EXISTS )) && echo "note:   disc.json already exists for $SLUG — scan files will be" \
  "refreshed, disc.json will NOT be touched. Delete it first for a clean re-capture."

# --- scan, stdout and stderr on separate files (#0039) -----------------------
# Every remote step is its own ssh_host call, each with a trivial command
# line — no nested quoting, no remote `$(...)` embedded in a locally
# double-quoted string to get wrong. Line counts and exit status are read
# back locally instead, off the files scp brings home right after.
ssh_host "mkdir -p ~/$REMOTE_DIR"

SCAN_STATUS=0
ssh_host "cd ~/$REMOTE_DIR && '$HANDBRAKE_PATH' -i \"/Volumes/$VOLUME\" --scan --title 0 --min-duration 1 --json >scan.json 2>scan.stderr.txt" \
  || SCAN_STATUS=$?

# Best-effort enrichment, each optional and never fatal to the capture.
# HandBrake's own version comes from scan.json's `Version:` block (parsed
# below alongside the title data) rather than a separate `--version` call —
# `HandBrakeCLI --version`'s first line on some builds is a hardening-flags
# banner, not the version, and the JSON block is what
# `HandBrakeScanParser.parseVersionBlock` already trusts.
ssh_host "$LSDVD_PATH -x -Oj \"/Volumes/$VOLUME\" >~/$REMOTE_DIR/lsdvd.json 2>~/$REMOTE_DIR/lsdvd.stderr.txt" || true
ssh_host "diskutil info \"/Volumes/$VOLUME\" >~/$REMOTE_DIR/diskutil-info.txt 2>/dev/null" || true

scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/scan.json"       "$DEST/scan.json"
scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/scan.stderr.txt" "$DEST/scan.stderr.txt"
echo "scan exit=$SCAN_STATUS stdout-lines=$(wc -l <"$DEST/scan.json") stderr-lines=$(wc -l <"$DEST/scan.stderr.txt")"

ENRICH="$(mktemp -d)"
trap 'rm -rf "$ENRICH"' EXIT
scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/lsdvd.json"        "$ENRICH/" 2>/dev/null || true
scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/lsdvd.stderr.txt"  "$ENRICH/" 2>/dev/null || true
scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/diskutil-info.txt" "$ENRICH/" 2>/dev/null || true

# discId is optional enrichment (CLAUDE.md), but a bare null with no
# explanation is indistinguishable from "nobody looked" — when lsdvd can't
# supply one, say why in DISC_ID_NOTE instead of leaving it silent.
# The field is called **`dvddiscid`**, not `discid`. That is the whole bug:
# the old `grep -o '"discid" *: *"…"'` does match — as a substring of
# `"dvddiscid"` — but the `sed` that follows takes the last quoted string on
# the line, and depending on the spacing lsdvd emits, the result was empty.
# Bloodsport's output carries `"dvddiscid" : "1e0979a4cd2d0409401a628e644e8b63"`
# and the capture recorded `null`. (CLAUDE.md already names `dvddiscid` as
# the disc identity DVDMonitor debounces on; the capture script was the only
# place still guessing.) Parse it as JSON, try both spellings, and fall back
# to a whitespace-tolerant regex only when the document will not parse at all
# — lsdvd does emit trailing-comma JSON on some discs.
DISC_ID=""
DISC_ID_NOTE=""
if [[ -s "$ENRICH/lsdvd.json" ]]; then
  DISC_ID="$(python3 - "$ENRICH/lsdvd.json" <<'PY' || true
import json, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
value = None
try:
    document = json.loads(text)
    value = document.get("dvddiscid") or document.get("discid")
except Exception:
    match = re.search(r'"(?:dvddiscid|discid)"\s*:\s*"([^"]+)"', text)
    if match:
        value = match.group(1)
print(value or "")
PY
)"
fi
# lsdvd.json is part of the corpus now (§8.2) — it carries the disc id, the
# cell table and the stream languages, and throwing it away meant every
# question about it needed the disc back.
[[ -s "$ENRICH/lsdvd.json" ]] && cp "$ENRICH/lsdvd.json" "$DEST/lsdvd.json"
if [[ -z "$DISC_ID" ]]; then
  if [[ -s "$ENRICH/lsdvd.stderr.txt" ]]; then
    DISC_ID_NOTE=" lsdvd could not read a disc id for this disc ($(head -1 "$ENRICH/lsdvd.stderr.txt"))."
  elif [[ -s "$ENRICH/lsdvd.json" ]]; then
    DISC_ID_NOTE=" lsdvd ran but its output had no discid field for this disc."
  else
    DISC_ID_NOTE=" lsdvd produced no output at all on $HOST (not installed, or failed silently)."
  fi
fi

DRIVE_MODEL=""
if [[ -f "$ENRICH/diskutil-info.txt" ]]; then
  # `diskutil`'s media name for the optical volume — the cheapest identity
  # signal available remotely, not a USB/IOKit hardware vendor string. Good
  # enough for "which drive produced this", not a spec sheet.
  DRIVE_MODEL="$(awk -F': *' '/Device \/ Media Name/{print $2; exit}' "$ENRICH/diskutil-info.txt")"
fi

CAPTURED_DATE="$(date +%Y-%m-%d)"

# --- title count / MainFeature / feature duration+chapters+version, via python3
# Deliberately shallow: raw scan facts only, no dedup/grouping logic (see the
# header comment). python3 ships with macOS; parsing runs locally, not on the
# host, so the remote side stays "run HandBrakeCLI (and lsdvd/diskutil) and
# nothing else." A `MainFeature` of `null`, zero, or negative (HandBrake's
# "no main feature" signal — confirmed on a real disc, Hornets' Nest,
# 2026-09-16) never resolves a feature title: `featureDuration`/`Chapters`
# stay `null` rather than looking up a nonexistent index.
read -r TITLE_COUNT MAIN_FEATURE FEATURE_DURATION FEATURE_CHAPTERS HANDBRAKE_VERSION <<<"$(python3 - "$DEST/scan.json" <<'PY'
import json, sys

def brace_block(text, after):
    start = text.find("{", after)
    if start == -1:
        return None
    depth = 0
    for j in range(start, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    return None

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()

version = "null"
vi = text.find("Version:")
if vi != -1:
    block = brace_block(text, vi)
    if block:
        try:
            vs = json.loads(block).get("VersionString")
            if vs:
                version = vs
        except Exception:
            pass

def bail():
    print(0, "null", "null", "null", version)
    raise SystemExit

i = text.find("JSON Title Set:")
if i == -1:
    bail()
block = brace_block(text, i)
if block is None:
    bail()
try:
    doc = json.loads(block)
except Exception:
    bail()

titles = doc.get("TitleList", [])
main_feature = doc.get("MainFeature")
feature = None
if isinstance(main_feature, int) and main_feature > 0:
    feature = next((t for t in titles if t.get("Index") == main_feature), None)
if feature is not None:
    d = feature.get("Duration", {})
    dur = d.get("Hours", 0) * 3600 + d.get("Minutes", 0) * 60 + d.get("Seconds", 0)
    chapters = len(feature.get("ChapterList", []))
else:
    dur, chapters = "null", "null"
print(len(titles), main_feature if main_feature is not None else "null", dur, chapters, version)
PY
)"

# --- menus (§8.5 steps 3-7) --------------------------------------------------
# Every step below is best-effort and each records why it produced nothing.
# The helper runs AFTER the scan, never beside it: HandBrake's scan is ~60 s
# of seeking on a USB 2.0 drive and two readers would slow both.
MENUS_CAPTURED=false
MENUS_CSS="unknown"
MENU_COUNT=0
STILL_COUNT=0
IFO_COUNT=0
OCR_RUN=false
MENU_NOTE=""
MENUDUMP_MISSING=""

if (( CAPTURE_MENUS )); then
  mkdir -p "$DEST/ifo" "$DEST/menus/stills" "$BUILD_DIR"

  # 3. The IFO tables — plain file copies, nothing decrypts.
  ssh_host "mkdir -p ~/$REMOTE_DIR/ifo && cp /Volumes/\"$VOLUME\"/VIDEO_TS/*.IFO ~/$REMOTE_DIR/ifo/ 2>/dev/null" || true
  scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/ifo/*.IFO" "$DEST/ifo/" 2>/dev/null || true
  IFO_COUNT="$(ls -1 "$DEST/ifo/" 2>/dev/null | grep -c '\.IFO$' || true)"

  # 4. The helper. It links nothing, so building it on the host is one `cc`
  #    with no flags and no headers — which is the point: a host missing
  #    libdvdread still produces a complete structure.json, just no cells.
  scp -q -o BatchMode=yes "$REPO_ROOT/Tools/menudump/menudump.c" "$HOST:$REMOTE_DIR/menudump.c" 2>/dev/null || true
  MENUDUMP_STATUS=0
  ssh_host "cd ~/$REMOTE_DIR && cc -std=c11 -O2 -o changeover-menudump menudump.c 2>menudump.build.txt" || MENUDUMP_STATUS=$?
  if (( MENUDUMP_STATUS == 0 )); then
    ssh_host "cd ~/$REMOTE_DIR && ./changeover-menudump --disc /Volumes/\"$VOLUME\" --out menus --max-bytes 67108864 2>menudump.stderr.txt" \
      || MENUDUMP_STATUS=$?
    scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/menus/structure.json" "$DEST/menus/structure.json" 2>/dev/null || true
    scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/menudump.stderr.txt" "$ENRICH/menudump.stderr.txt" 2>/dev/null || true
  fi

  if [[ -s "$DEST/menus/structure.json" ]]; then
    MENUS_CAPTURED=true
    read -r MENU_COUNT MENUS_CSS MENUDUMP_MISSING <<<"$(python3 - "$DEST/menus/structure.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(0, "unknown", ""); raise SystemExit
helper = d.get("helper") or {}
print(len(d.get("menus") or []), helper.get("css") or "unknown", ",".join(helper.get("missing") or []) or "-")
PY
)"

    # 5. One still per menu PGC, rendered on the host where ffmpeg lives.
    #    The cells are already decrypted by the helper, so this is a plain
    #    MPEG-2 decode with no key involved.
    ssh_host "mkdir -p ~/$REMOTE_DIR/menus/stills && for v in ~/$REMOTE_DIR/menus/cells/*.vob; do [ -f \"\$v\" ] || continue; b=\$(basename \"\$v\" .vob); '$FFMPEG_PATH' -y -loglevel error -i \"\$v\" -vf 'select=eq(pict_type\\,I)' -fps_mode vfr -frames:v 1 ~/$REMOTE_DIR/menus/stills/\$b.png </dev/null; done" || true
    scp -q -o BatchMode=yes "$HOST:$REMOTE_DIR/menus/stills/*.png" "$ENRICH/" 2>/dev/null || true
    # (N) is zsh's null glob: no stills is a normal outcome here, not an error.
    for png in "$ENRICH"/*.png(N); do
      [[ -f "$png" ]] || continue
      sips -s format jpeg -s formatOptions 80 "$png" --out "$DEST/menus/stills/$(basename "${png%.png}").jpg" >/dev/null 2>&1 || true
    done
    STILL_COUNT="$(ls -1 "$DEST/menus/stills/" 2>/dev/null | grep -c '\.jpg$' || true)"
  else
    MENU_NOTE=" changeover-menudump produced no structure.json (exit $MENUDUMP_STATUS)."
  fi

  # 6-7. OCR and resolution, locally: Vision is on this Mac and this keeps
  #      the host idle. Both tools link the app's own sources, so what the
  #      archive records is what the app computes.
  if (( STILL_COUNT > 0 )); then
    swiftc -O -o "$BUILD_DIR/menu-ocr" \
      "$REPO_ROOT/Changeover/MenuStructure.swift" "$REPO_ROOT/Changeover/VMCommand.swift" \
      "$REPO_ROOT/Changeover/MenuLexicon.swift" "$REPO_ROOT/Changeover/MenuOCR.swift" \
      "$REPO_ROOT/Tools/menu-ocr/main.swift" 2>/dev/null \
      && "$BUILD_DIR/menu-ocr" "$DEST/menus/ocr.json" "$DEST/menus/stills"/*.jpg >/dev/null 2>&1 \
      && OCR_RUN=true || true
  fi

  if [[ -s "$DEST/menus/structure.json" || -s "$DEST/menus/ocr.json" ]]; then
    swiftc -O -o "$BUILD_DIR/menu-derive" \
      "$REPO_ROOT/Changeover/MenuStructure.swift" "$REPO_ROOT/Changeover/VMCommand.swift" \
      "$REPO_ROOT/Changeover/MenuLexicon.swift" "$REPO_ROOT/Changeover/MenuOCR.swift" \
      "$REPO_ROOT/Changeover/ChapterNames.swift" "$REPO_ROOT/Changeover/LanguageHints.swift" \
      "$REPO_ROOT/Changeover/MenuTitleGuess.swift" "$REPO_ROOT/Changeover/PlayButtonResolver.swift" \
      "$REPO_ROOT/Changeover/MenuDerived.swift" "$REPO_ROOT/Changeover/DiscNameSearchTerm.swift" \
      "$REPO_ROOT/Tools/menu-derive/main.swift" 2>/dev/null \
      && "$BUILD_DIR/menu-derive" --out "$DEST/menus/derived.json" \
           --structure "$DEST/menus/structure.json" --ocr "$DEST/menus/ocr.json" \
           --chapter-count "${FEATURE_CHAPTERS/null/0}" --volume-name "$VOLUME" > "$ENRICH/derive.txt" 2>&1 || true
  fi
fi

# --- write disc.json (only when one doesn't already exist) -------------------
if (( ! MANIFEST_EXISTS )); then
  # HandBrake's own "no main feature" signal (absent, zero, or negative —
  # confirmed on Hornets' Nest, MainFeature -1) never guesses `single`.
  OUTCOME="single"
  OUTCOME_INDEX="$MAIN_FEATURE"
  if [[ "$MAIN_FEATURE" == "null" ]]; then
    OUTCOME="none"; OUTCOME_INDEX="null"
  elif (( MAIN_FEATURE <= 0 )); then
    OUTCOME="none"; OUTCOME_INDEX="null"
  fi

  DISC_ID_JSON="null";       [[ -n "$DISC_ID" ]]          && DISC_ID_JSON="\"$DISC_ID\""
  DRIVE_MODEL_JSON="null";   [[ -n "$DRIVE_MODEL" ]]       && DRIVE_MODEL_JSON="\"$DRIVE_MODEL\""
  HANDBRAKE_VERSION_JSON="null"; [[ "$HANDBRAKE_VERSION" != "null" ]] && HANDBRAKE_VERSION_JSON="\"HandBrake $HANDBRAKE_VERSION\""

  IFO_COUNT="${IFO_COUNT:-0}"; STILL_COUNT="${STILL_COUNT:-0}"; MENU_COUNT="${MENU_COUNT:-0}"
  MENUS_MISSING_JSON="[]"
  if [[ -n "$MENUDUMP_MISSING" && "$MENUDUMP_MISSING" != "-" ]]; then
    MENUS_MISSING_JSON="[$(echo "$MENUDUMP_MISSING" | sed -E 's/([^,]+)/"\1"/g')]"
  fi

  # `expect.menu` is proposed from derived.json and then reviewed by a human
  # against the stills, exactly like the rest of `expect`. A disc with no
  # menus/ gets `null` and DiscCorpusTests skips the menu assertions by name
  # rather than passing vacuously.
  MENU_EXPECT_JSON="null"
  if [[ -s "$DEST/menus/derived.json" ]]; then
    MENU_EXPECT_JSON="$(python3 - "$DEST/menus/derived.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
play = d.get("playButton") or {}
chapters = d.get("chapterMenu") or {}
languages = d.get("languages") or {}
title_text = d.get("titleText") or {}
unresolved = sorted({b["target"].split(":", 1)[1]
                     for b in d.get("buttons", [])
                     if b.get("target", "").startswith("unresolved:")})
out = {
    "playButtonTitle": play.get("title"),
    "playButtonLabel": play.get("label"),
    "playButtonResolvedBy": play.get("resolvedBy"),
    "chapterMenuButtons": chapters.get("buttons"),
    "chapterNamesEmitted": chapters.get("csvRows"),
    "chapterPages": chapters.get("pages") or [],
    "chapterNames": [c["name"] for c in sorted(chapters.get("names", []), key=lambda c: c["chapter"])],
    "spokenLanguages": languages.get("spoken") or [],
    "subtitleLanguages": languages.get("subtitles") or [],
    "languageShape": languages.get("shape"),
    "tvSignal": (d.get("tvSignal") or {}).get("value"),
    "titleTextCandidate": title_text.get("text"),
    "unresolvedMnemonics": unresolved,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
)"
  fi

  cat > "$DEST/disc.json" <<JSON
{
  "formatVersion": 2,
  "slug": "$SLUG",
  "volumeName": "$VOLUME",
  "driveName": "$HOST",
  "discId": $DISC_ID_JSON,
  "driveModel": $DRIVE_MODEL_JSON,
  "handbrakeVersion": $HANDBRAKE_VERSION_JSON,
  "capturedDate": "$CAPTURED_DATE",
  "reviewed": false,
  "capture": {
    "tool": "Tools/capture-disc.sh",
    "toolVersion": 2,
    "ifoFiles": $IFO_COUNT,
    "rawArchive": "$HOST:~/$REMOTE_DIR"
  },
  "menus": {
    "captured": $MENUS_CAPTURED,
    "css": "$MENUS_CSS",
    "menuCount": $MENU_COUNT,
    "stillCount": $STILL_COUNT,
    "ocrRun": $OCR_RUN,
    "judgeRun": false,
    "missing": $MENUS_MISSING_JSON
  },
  "notes": "Auto-captured by Tools/capture-disc.sh (v2).${DISC_ID_NOTE}${MENU_NOTE} REVIEW REQUIRED before DiscCorpusTests will accept this disc: confirm outcome (single/playAll/none/noTitles — this script only ever guesses single or none), outcomeEpisodes for a playAll disc, audioTrackCount (AudioTrackOptions.options(for:).count on the feature title) and subtitleGroupCount (SubtitleGrouping.groups(for:).count) — then set reviewed to true.",
  "expect": {
    "titleCount": $TITLE_COUNT,
    "mainFeatureIndex": $MAIN_FEATURE,
    "outcome": "$OUTCOME",
    "outcomeIndex": $OUTCOME_INDEX,
    "outcomeEpisodes": null,
    "featureDurationSeconds": $FEATURE_DURATION,
    "featureChapterCount": $FEATURE_CHAPTERS,
    "audioTrackCount": null,
    "subtitleGroupCount": null,
    "menu": $MENU_EXPECT_JSON
  }
}
JSON
  echo "wrote:  $DEST/disc.json (reviewed: false — fill in the REVIEW fields by hand)"
else
  echo "kept:   $DEST/disc.json (not overwritten)"
fi

echo
echo "=== summary ==="
echo "titles:            $TITLE_COUNT"
echo "MainFeature:       $MAIN_FEATURE"
if [[ "$FEATURE_DURATION" == "null" ]]; then
  echo "feature duration:  n/a (no MainFeature title resolved)"
else
  echo "feature duration:  ${FEATURE_DURATION}s"
  echo "feature chapters:  $FEATURE_CHAPTERS"
fi
echo "HandBrake version: ${HANDBRAKE_VERSION:-unknown}"
echo "disc id (lsdvd):   ${DISC_ID:-none}${DISC_ID_NOTE}"
echo "IFO files:         ${IFO_COUNT:-0}"
echo "menu PGCs:         ${MENU_COUNT:-0}  stills: ${STILL_COUNT:-0}  css: ${MENUS_CSS:-unknown}"
if [[ -n "${MENUDUMP_MISSING:-}" && "${MENUDUMP_MISSING:-}" != "-" ]]; then
  echo "menu deps missing: $MENUDUMP_MISSING  (brew install ${MENUDUMP_MISSING//,/ })"
fi
# The derive summary is the first thing the human review should read: the
# play button line, the chapter-name count against the chapter count, the
# language lists and every command mnemonic the decoder could not name.
[[ -s "$ENRICH/derive.txt" ]] && cat "$ENRICH/derive.txt" || true
echo
echo "fixtures: $DEST/{scan.json,scan.stderr.txt,disc.json}"
echo "Next:"
echo "  1. Review $DEST/disc.json and flip reviewed to true."
echo "  2. New slug? Xcode's synchronized groups flatten Copy Bundle Resources,"
echo "     so a same-named scan.json/disc.json across discs collides at build"
echo "     time. Add this disc's files to the ChangeoverTests membership"
echo "     exceptions in Changeover.xcodeproj/project.pbxproj (search for"
echo "     PBXFileSystemSynchronizedBuildFileExceptionSet) — same as every"
echo "     disc already there."
echo "  3. ./run-remote-tests.sh gordon DiscCorpusTests"
