#!/bin/zsh
# run-ui-tests-vm.sh — run Changeover's UI tests inside a disposable Tart VM.
#
# UI tests never run on cameron's host (see docs/ui-test-crash-prevention.md);
# they run in a per-run APFS clone of `changeover-uitest-golden` that is
# deleted afterwards. The golden image is only ever cloned, never run.
#
# Per run:
#   1. Preflight: Tart present, golden image present, disk free, memory
#      requested through the generic memory-signal protocol when the host is
#      short (the machine's observer frees what it can), stale
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
LEASE_ID=""

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  trap - EXIT
  log "Cleaning up (exit $rc)"
  # Give the Tart slot back before the slower teardown, so a waiting session
  # starts sooner. Losing this is not fatal: leases are pid-stamped and the
  # next acquire prunes ours. See Homelab protocols/tart-lease/PROTOCOL.md
  if [[ -n "$LEASE_ID" ]]; then
    tart-lease release --id "$LEASE_ID" 2>/dev/null || true
  fi
  # memory-signal release: tell the observer this run is done with any
  # memory it freed. Best effort — never affects the exit code.
  if [[ -n "${MEMORY_REQUEST_ID:-}" ]]; then
    /usr/bin/python3 - "${MEMORY_COORD_DIR:-}" "$MEMORY_REQUEST_ID" <<'PY' 2>/dev/null || true
import json, os, sys, datetime
dir, rid = sys.argv[1:3]
if not dir:
    raise SystemExit(0)
os.makedirs(os.path.join(dir, "release"), exist_ok=True)
doc = {"id": rid, "released": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
with open(os.path.join(dir, "release", rid + ".json"), "w") as f:
    json.dump(doc, f, indent=2)
PY
  fi
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

# --- Memory (generic memory-signal protocol) -------------------------------
# The guest needs its RAM plus host build headroom. This script states the
# need through the memory-signal protocol and waits for this machine's
# observer to free memory; what the observer does (unload cached AI models,
# drop caches, ask the user) is configured on the machine, never here.
# See PROTOCOL.md in the protocol's home for the wire format.

# Keep in sync with the golden image's memory (`tart set --memory`).
typeset -g GUEST_MEM_MB=12288

memory_available_bytes() {
  local page free inactive purgeable
  page=$(sysctl -n vm.pagesize)
  free=$(vm_stat | awk '/Pages free/ {gsub("\\.","",$3); print $3}')
  inactive=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  purgeable=$(vm_stat | awk '/Pages purgeable/ {gsub("\\.","",$3); print $3}')
  print -r -- $(( (free + inactive + purgeable) * page ))
}

# 0 = a live observer owns the spool (heartbeat fresh), 1 = none.
memory_observer_live() {
  local dir hb now mtime
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  hb="$dir/heartbeat"
  [[ -f "$hb" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$hb" 2>/dev/null) || return 1
  (( now - mtime <= 15 ))
}

# Emits a request and polls for ready/failed. 0 ready, 3 failed, 4 timeout
# or no observer. Sets MEMORY_REQUEST_ID for the release in cleanup.
memory_request_and_wait() {
  local need_bytes=$1 reason=$2 timeout=${3:-120}
  local dir id req deadline
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  id="run-ui-tests-vm-$$-$(date +%s)"
  req="$dir/requests/$id.json"
  MEMORY_REQUEST_ID="$id"
  MEMORY_COORD_DIR="$dir"

  memory_observer_live || { MEMORY_REQUEST_ID=""; return 4; }

  mkdir -p "$dir/requests" "$dir/ready" "$dir/failed" "$dir/release"
  /usr/bin/python3 - "$req" "$id" "$need_bytes" "$reason" "$$" <<'PY'
import json, os, sys, datetime
path, rid, need, reason, pid = sys.argv[1:6]
doc = {
    "id": rid,
    "resource": "memory",
    "bytes": int(need),
    "requester": "run-ui-tests-vm",
    "reason": reason,
    "pid": int(pid),
    "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

  deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    [[ -f "$dir/ready/$id.json" ]] && return 0
    if [[ -f "$dir/failed/$id.json" ]]; then
      /usr/bin/python3 -c 'import json,sys; print("memory-signal failed:", json.load(open(sys.argv[1])).get("reason","?"))' "$dir/failed/$id.json" >&2
      return 3
    fi
    sleep 2
  done
  return 4
}

need_bytes=$(( (GUEST_MEM_MB + 4096) * 1024 * 1024 ))
avail_bytes=$(memory_available_bytes)
if (( avail_bytes < need_bytes )); then
  log "Host memory short ($(( avail_bytes / 1073741824 )) GiB of $(( need_bytes / 1073741824 )) GiB) — requesting via the memory-signal protocol"
  set +e
  memory_request_and_wait "$need_bytes" "Tart VM UI-test run needs guest RAM plus build headroom" 120
  mem_rc=$?
  set -e
  (( mem_rc == 0 )) || fail "Memory request not fulfilled (rc=$mem_rc). Free memory, or set up a memory-signal observer (MEMORY_COORDINATION_DIR=${MEMORY_COORDINATION_DIR:-$HOME/.local/state/memory-coordination})"
  avail_bytes=$(memory_available_bytes)
  (( avail_bytes >= need_bytes )) || fail "Observer signaled ready but memory is still short ($(( avail_bytes / 1073741824 )) GiB of $(( need_bytes / 1073741824 )) GiB)"
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

# --- Wait for a Tart slot --------------------------------------------------
# One host, several repos and sessions. `tart-lease` admits at most two guests
# and only grants the second when memory allows; it blocks until our turn.
# Acquired after the memory-signal work above so it sees any memory the
# observer just freed.

if command -v tart-lease >/dev/null; then
  LEASE_ID=$(tart-lease acquire --label changeover --pid $$)
else
  log "WARNING: tart-lease not on PATH — running without admission control"
fi

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
