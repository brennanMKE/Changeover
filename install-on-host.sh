#!/bin/zsh
# install-on-host.sh — install a built Changeover.dmg onto another Mac, refusing
# while that Mac has work in flight.
#
# Written after an install destroyed a user's import. On 2026-10-04 the host was
# checked with `pgrep -c HandBrakeCLI`, which returned 0, and the DMG was
# installed — and a job was running. The import of *Next* (2007) died at 10%
# with no `job.finished` event and no record in `report`: the user lost it
# without a trace.
#
# Two things were wrong with that check, and both are fixed here.
#
#   1. **It asked the wrong process.** A job is not always inside HandBrake. It
#      scans, it moves files into Plex, it waits on a disc; `pgrep HandBrakeCLI`
#      reads 0 through all of it. The app knows whether a job is running and
#      says so — `changeoverctl status` has `job.running` — so ask the app.
#
#   2. **It was a point-in-time sample followed by a separate command.** The
#      check and the quit were two SSH round trips with a build in between, and
#      a job can start in the gap — which is what happened; an agent began one.
#      Here the check is re-run on the host immediately before the quit, in the
#      same shell, so the window is milliseconds rather than minutes.
#
# The guard is deliberately conservative: anything it cannot determine is
# treated as "busy". An install is never urgent, and a wrongly refused install
# costs a rerun while a wrongly permitted one costs forty minutes of someone
# else's encode.
#
# Usage:
#   ./install-on-host.sh joe dist/Changeover-0.1.3-pre1.dmg
#   FORCE=1 ./install-on-host.sh joe <dmg>   # only with the user's explicit say-so
set -euo pipefail

HOST="${1:?usage: install-on-host.sh <host> <dmg>}"
DMG="${2:?usage: install-on-host.sh <host> <dmg>}"
CTL="/usr/local/bin/changeoverctl"
FORCE="${FORCE:-0}"

[[ -f "$DMG" ]] || { print -u2 "no such DMG: $DMG"; exit 1; }

print "== checking $HOST is idle"

# `|| true` so a non-zero exit (app not running, exit 3) does not abort under
# `set -e` — "not running" is a perfectly good state to install into.
STATUS="$(ssh "$HOST" "$CTL status --json --no-launch 2>/dev/null" || true)"

if [[ -n "$STATUS" ]]; then
    BUSY="$(print -r -- "$STATUS" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["status"]
except Exception:
    # Unparseable means unknown, and unknown means busy.
    print("status could not be read"); raise SystemExit
job = d.get("job") or {}
disc = d.get("disc") or {}
scan = d.get("scan") or {}
reasons = []
if job.get("running"):
    jid = job.get("id") or "?"
    phase = job.get("phase") or "?"
    reasons.append("job " + str(jid) + " is running (" + str(phase) + ")")
if scan.get("state") == "scanning":
    reasons.append("a disc scan is in flight")
if disc.get("isEjecting"):
    reasons.append("a disc is being ejected")
print("; ".join(reasons))
' || print "status could not be read")"

    if [[ -n "$BUSY" ]]; then
        print -u2 "REFUSING: $HOST is busy — $BUSY"
        print -u2 "Quitting the app now would destroy that work with no record of it."
        [[ "$FORCE" == "1" ]] || exit 2
        print -u2 "FORCE=1 given; continuing anyway."
    fi
    # Say what is attached, so a watcher losing its session is never a surprise.
    print -r -- "$STATUS" | python3 -c '
import json, sys
d = json.load(sys.stdin)["status"]
a = d.get("automation") or {}
held = a.get("heldBySessions", 0)
openq = (d.get("app") or {}).get("sessions", 0)
print("   agents attached: " + str(held) + " (open sessions " + str(openq) + ") — these end at the quit")
' || true
else
    print "   Changeover is not running on $HOST"
fi

print "== copying $DMG"
scp -q "$DMG" "$HOST:/tmp/Changeover.dmg"

print "== installing"
# The whole install is one remote shell so the final busy re-check and the quit
# are adjacent. FORCE is passed through rather than re-derived.
ssh "$HOST" "FORCE='$FORCE' CTL='$CTL' zsh -s" <<'REMOTE'
set -euo pipefail

# The second look, immediately before the quit. This is the one that matters:
# the first check was minutes and one file copy ago.
LATE="$($CTL status --json --no-launch 2>/dev/null || true)"
if [[ -n "$LATE" ]]; then
    RUNNING="$(print -r -- "$LATE" | python3 -c '
import json, sys
try:
    j = (json.load(sys.stdin)["status"].get("job") or {})
except Exception:
    print("unknown"); raise SystemExit
print(j.get("id", "yes") if j.get("running") else "")
' || print unknown)"
    if [[ -n "$RUNNING" ]]; then
        if [[ "$FORCE" != "1" ]]; then
            print -u2 "REFUSING at the last moment: a job started ($RUNNING). Nothing was changed."
            exit 2
        fi
        print -u2 "FORCE=1: quitting with $RUNNING still running."
    fi
fi

MP="$(hdiutil attach -nobrowse -readonly /tmp/Changeover.dmg 2>/dev/null | grep -o '/Volumes/.*' | head -1)"
[[ -n "$MP" ]] || { print -u2 "could not mount the DMG"; exit 1; }
trap 'hdiutil detach "$MP" -quiet 2>/dev/null || true' EXIT

osascript -e 'quit app "Changeover"' 2>/dev/null || true
for _ in {1..10}; do pgrep -x Changeover >/dev/null || break; sleep 1; done
pgrep -x Changeover >/dev/null && pkill -x Changeover || true
sleep 1

rm -rf /Applications/Changeover.app
cp -R "$MP/Changeover.app" /Applications/Changeover.app
xattr -cr /Applications/Changeover.app
open -a /Applications/Changeover.app
sleep 9

$CTL status --json --no-launch | python3 -c '
import json, sys
d = json.load(sys.stdin)["status"]
print("   installed build:", d["app"]["build"], d["app"]["version"])
'
REMOTE

print "== done"
