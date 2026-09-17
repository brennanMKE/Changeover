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
REPO_ROOT="${0:A:h}/.."
FIXTURES="$REPO_ROOT/ChangeoverTests/Fixtures/discs"

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
ssh_host "lsdvd -x -Oj \"/Volumes/$VOLUME\" >~/$REMOTE_DIR/lsdvd.json 2>~/$REMOTE_DIR/lsdvd.stderr.txt" || true
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
DISC_ID=""
DISC_ID_NOTE=""
if [[ -s "$ENRICH/lsdvd.json" ]]; then
  DISC_ID="$(grep -o '"discid" *: *"[^"]*"' "$ENRICH/lsdvd.json" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/' || true)"
fi
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

  cat > "$DEST/disc.json" <<JSON
{
  "slug": "$SLUG",
  "volumeName": "$VOLUME",
  "driveName": "$HOST",
  "discId": $DISC_ID_JSON,
  "driveModel": $DRIVE_MODEL_JSON,
  "handbrakeVersion": $HANDBRAKE_VERSION_JSON,
  "capturedDate": "$CAPTURED_DATE",
  "reviewed": false,
  "notes": "Auto-captured by Tools/capture-disc.sh.${DISC_ID_NOTE} REVIEW REQUIRED before DiscCorpusTests will accept this disc: confirm outcome (single/playAll/none/noTitles — this script only ever guesses single or none), outcomeEpisodes for a playAll disc, audioTrackCount (AudioTrackOptions.options(for:).count on the feature title) and subtitleGroupCount (SubtitleGrouping.groups(for:).count) — then set reviewed to true.",
  "expect": {
    "titleCount": $TITLE_COUNT,
    "mainFeatureIndex": $MAIN_FEATURE,
    "outcome": "$OUTCOME",
    "outcomeIndex": $OUTCOME_INDEX,
    "outcomeEpisodes": null,
    "featureDurationSeconds": $FEATURE_DURATION,
    "featureChapterCount": $FEATURE_CHAPTERS,
    "audioTrackCount": null,
    "subtitleGroupCount": null
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
