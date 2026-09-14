#!/bin/zsh
# run-ui-tests-vm.sh — run Changeover's UI tests inside a disposable Tart VM.
#
# UI tests never run on cameron's host (see docs/ui-test-crash-prevention.md);
# they run in a per-run APFS clone of `changeover-uitest-golden` that is
# deleted afterwards. The golden image is only ever cloned, never run.
#
# Per run:
#   1. Preflight: Tart present, golden image present, disk free, LM Studio
#      models unloaded (its loaded models got a clone OOM-killed once), stale
#      `changeover-uitest-*` clones swept.
#   2. Export a clean snapshot: `git archive HEAD` — never the live working
#      copy — plus the gitignored `Changeover/Secrets.xcconfig`.
#   3. Clone, boot headless with the export mounted read-only.
#   4. In the guest: copy the source in, run
#      `xcodebuild -scheme 'Changeover UI Tests' test` (XCUITest), teeing the
#      log, with the result bundle captured.
#   5. Stream the results back to `build/ui-tests/<timestamp>/`.
#   6. Cleanup on EXIT (trap): stop and delete the clone, remove the export
#      (it holds the TMDB key, so it must not outlive the run).
#
# The export share is read-only on purpose; results come back via `tart exec
# … tar`, not through the share. Run this script in the foreground of a
# shell: a dropped session costs a clone, not a work session.

set -euo pipefail

GOLDEN="changeover-uitest-golden"
REPO="$(cd "$(dirname "$0")" && pwd)"
GUEST_USER="admin"
GUEST_SRC="/Users/$GUEST_USER/src"
GUEST_RESULTS="/Users/$GUEST_USER/results"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CLONE="changeover-uitest-$RUN_ID"
EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/changeover-uitest-export.XXXXXX")"
RESULTS_DIR="$REPO/build/ui-tests/$RUN_ID"
BOOT_TIMEOUT_SECS=120

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  trap - EXIT
  log "Cleaning up (exit $rc)"
  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  rm -rf "$EXPORT"
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------

command -v tart >/dev/null || fail "Tart is not installed (brew install cirruslabs/cli/tart)"
tart list | grep -q "$GOLDEN" || fail "Golden image '$GOLDEN' not found"

[[ -f "$REPO/Changeover/Secrets.xcconfig" ]] \
  || fail "Changeover/Secrets.xcconfig is missing — the guest build needs the TMDB key"

free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 20 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / — need at least 20 GiB"

# LM Studio's loaded models do not show in process RSS but got a clone
# OOM-killed once (tart-ui-test-vm.md, Known limits). Refuse to run with
# models loaded unless overridden.
if [[ -x "$HOME/.lmstudio/bin/lms" ]]; then
  if lms_ps="$("$HOME/.lmstudio/bin/lms" ps 2>/dev/null)"; then
    if print -r -- "$lms_ps" | grep -qE 'IDLE|LOADED|PROCESSING'; then
      print -r -- "$lms_ps" | tail -n +2
      fail "LM Studio has models loaded (~24 GB, invisible to RSS). Unload them first: ~/.lmstudio/bin/lms unload --all — and record the unload in ~/Developer/Homelab/cameron/lm-studio-memory.md (the coordination ledger)"
    fi
  fi
fi

# A SIGKILL (e.g. the OOM above) skips this script's trap, so sweep any
# clones left behind by earlier runs. Only names shaped
# `changeover-uitest-<YYYYMMDD>-<HHMMSS>-<pid>` — this script's own run-id
# shape — are swept, which structurally excludes the golden image; the
# explicit golden check inside the loop is belt and braces after the
# 2026-09-13 incident where a plain name-prefix match deleted the golden.
stale=$(tart list | awk '$2 ~ /^changeover-uitest-[0-9]{8}-[0-9]{6}-[0-9]+$/ { print $2 }' | grep -v -- "$CLONE" || true)
foreign=$(tart list | awk '$2 ~ /^changeover-uitest-/ && $2 !~ /^changeover-uitest-[0-9]{8}-[0-9]{6}-[0-9]+$/ && $2 != "changeover-uitest-golden" { print $2 }' || true)
for old in ${=stale}; do
  if [[ "$old" == "$GOLDEN" ]]; then
    print -r -- "!! refusing to sweep the golden image — this is a script bug" >&2
    continue
  fi
  log "Sweeping stale clone: $old"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done
for other in ${=foreign}; do
  log "Leaving non-run clone alone: $other"
done
for old in ${=stale}; do
  log "Sweeping stale clone: $old"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done

# --- Export a clean snapshot ----------------------------------------------

mkdir -p "$EXPORT/src"
log "Exporting HEAD to $EXPORT/src"
git -C "$REPO" archive HEAD | tar -x -C "$EXPORT/src"
cp "$REPO/Changeover/Secrets.xcconfig" "$EXPORT/src/Changeover/Secrets.xcconfig"

# --- Clone and boot --------------------------------------------------------

log "Cloning $GOLDEN → $CLONE"
tart clone "$GOLDEN" "$CLONE"

log "Booting $CLONE (headless, export mounted read-only)"
tart run "$CLONE" --no-graphics --dir=run:"$EXPORT":ro >"$EXPORT/tart-run.log" 2>&1 &
boot_deadline=$(( SECONDS + BOOT_TIMEOUT_SECS ))
until tart exec "$CLONE" true >/dev/null 2>&1; do
  (( SECONDS < boot_deadline )) || fail "Guest did not become reachable within ${BOOT_TIMEOUT_SECS}s (see $EXPORT/tart-run.log — kept until cleanup)"
  sleep 5
done
log "Guest reachable in $SECONDS s"

# --- In the guest ----------------------------------------------------------

tart exec "$CLONE" /bin/zsh -lc "rm -rf $GUEST_SRC $GUEST_RESULTS && mkdir -p $GUEST_RESULTS"
log "Copying source into guest"
tart exec "$CLONE" /bin/zsh -lc "cp -R '/Volumes/My Shared Files/run/src' $GUEST_SRC"

log "Running UI tests in the guest (this runs XCUITest inside the VM only)"
set +e
tart exec "$CLONE" /bin/zsh -lc \
  "cd $GUEST_SRC && xcodebuild -project Changeover.xcodeproj -scheme 'Changeover UI Tests' \
     -destination 'platform=macOS' -resultBundlePath $GUEST_RESULTS/UITests.xcresult test 2>&1 | tee $GUEST_RESULTS/xcodebuild.log"
test_rc=$?
set -e

# --- Results back ----------------------------------------------------------

mkdir -p "$RESULTS_DIR"
log "Pulling results into $RESULTS_DIR"
tart exec "$CLONE" /bin/zsh -lc "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$RESULTS_DIR"

print ""
if (( test_rc == 0 )); then
  log "RESULT: TEST SUCCEEDED (exit 0)"
else
  log "RESULT: TEST FAILED (exit $test_rc)"
fi
grep -E 'Test run with|Test Suite .* (passed|failed)|TEST (SUCCEEDED|FAILED)' \
  "$RESULTS_DIR/xcodebuild.log" | tail -10 || true
print ""
log "Result bundle: $RESULTS_DIR/UITests.xcresult"
log "Full log:      $RESULTS_DIR/xcodebuild.log"

exit "$test_rc"
