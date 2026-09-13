#!/usr/bin/env zsh
#
# Run Changeover's unit tests on another Mac over SSH and print a short summary.
#
#   ./run-remote-tests.sh gordon                                # sync, then run all of ChangeoverTests
#   ./run-remote-tests.sh gordon ProcessRunnerTests/someTest    # sync, then run one test
#   ./run-remote-tests.sh gordon --no-sync ProcessRunnerTests/x # run the host's copy as-is (falsification)
#   ./run-remote-tests.sh gordon --sync-only                    # restore the host's copy from this Mac
#   ./run-remote-tests.sh gordon --dry-run ProcessRunnerTests/x # show what would run, run nothing
#
# The first argument is the SSH host. The repo is synced to the same path
# relative to $HOME on that host. Selectors may omit the "ChangeoverTests/"
# prefix and the trailing "()". UI tests are refused. The full xcodebuild
# log is copied to build/remote-tests/<host>/ and never printed.
#
# Exit status: 0 passed, 1 failed, 2 usage error or host busy, 124 timed out.
#
# Environment: TEST_TIMEOUT seconds (default 1500).

set -euo pipefail

TIMEOUT="${TEST_TIMEOUT:-1500}"
SCRIPT_NAME="${0:t}"

# ---------------------------------------------------------------------------
# Remote half: runs on the test host, invoked by the local half over ssh.
#   run-remote-tests.sh --remote <repo dir relative to $HOME> [selectors...]
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--remote" ]]; then
    REMOTE_DIR="$2"
    shift 2
    cd ~/"$REMOTE_DIR"

    LOCK=/tmp/changeover-tests.lock
    if pgrep -x xcodebuild >/dev/null || ! mkdir "$LOCK" 2>/dev/null; then
        echo "BUSY: another xcodebuild run is active on $(hostname -s) (or stale lock $LOCK)."
        exit 2
    fi
    trap 'rm -rf "$LOCK"' EXIT

    STAMP=$(date +%Y%m%d-%H%M%S)
    RESULTS=~/Library/Caches/ChangeoverTests
    mkdir -p "$RESULTS"
    LOG="$RESULTS/$STAMP.log"
    BUNDLE="$RESULTS/$STAMP.xcresult"
    # Keep the five most recent runs.
    old_bundles=("$RESULTS"/*.xcresult(N/om)); rm -rf -- "${(@)old_bundles[6,-1]}"
    old_logs=("$RESULTS"/*.log(N.om));          rm -f  -- "${(@)old_logs[6,-1]}" "${(@)^old_logs[6,-1]}.timedout"

    only=()
    if (( $# == 0 )); then
        only=("-only-testing:ChangeoverTests")
    else
        for sel in "$@"; do only+=("-only-testing:$sel"); done
    fi

    START=$SECONDS
    xcodebuild -project Changeover.xcodeproj -scheme Changeover \
        -destination platform=macOS -resultBundlePath "$BUNDLE" \
        test "${only[@]}" >"$LOG" 2>&1 &
    XCB=$!

    (
        sleep "$TIMEOUT"
        if kill -0 "$XCB" 2>/dev/null; then
            touch "$LOG.timedout"
            kill -TERM "$XCB" 2>/dev/null
            sleep 10
            kill -KILL "$XCB" 2>/dev/null
            pkill -x Changeover 2>/dev/null
        fi
    ) &
    WATCHER=$!

    set +e
    wait "$XCB"
    STATUS=$?
    set -e
    pkill -P "$WATCHER" 2>/dev/null || true
    kill "$WATCHER" 2>/dev/null || true
    ELAPSED=$(( SECONDS - START ))

    cut_line() { cut -c1-300; }

    if [[ -e "$LOG.timedout" ]]; then
        RESULT="TIMED OUT after ${TIMEOUT}s"
        CODE=124
    elif (( STATUS == 0 )); then
        RESULT="PASSED"
        CODE=0
    else
        RESULT="FAILED (xcodebuild exit $STATUS)"
        CODE=1
    fi

    # A Swift Testing selector that matches nothing still "succeeds" with 0 tests.
    COUNTS=$(grep -aE 'Test run with [0-9]+ test|Executed [0-9]+ test' "$LOG" | tail -n 3 | cut_line || true)
    if (( CODE == 0 )) && { [[ -z "$COUNTS" ]] || echo "$COUNTS" | grep -qE 'with 0 tests|Executed 0 tests'; }; then
        RESULT="FAILED (0 tests ran: check the selector)"
        CODE=1
    fi

    echo "== $RESULT in ${ELAPSED}s on $(hostname -s)"
    [[ -n "$COUNTS" ]] && echo "$COUNTS"

    FAILURES=$(grep -aE '✘|error:|Expectation failed|Fatal error|crashed' "$LOG" \
        | grep -av 'Test run with' | cut_line | awk '!seen[$0]++' | head -n 30 || true)
    if [[ -n "$FAILURES" ]]; then
        echo "-- failures (first 30):"
        echo "$FAILURES"
    fi

    LEAKS=$( { grep -a 'CONTINUATION MISUSE' "$LOG"; grep -rah 'CONTINUATION MISUSE' "$BUNDLE" 2>/dev/null; } \
        | cut_line | awk '!seen[$0]++' || true)
    if [[ -n "$LEAKS" ]]; then
        echo "-- continuation leak warnings:"
        echo "$LEAKS"
    fi

    grep -aE '^\*\* TEST (SUCCEEDED|FAILED|INTERRUPTED)' "$LOG" | tail -n 1 || true
    echo "LOG=$LOG"
    exit "$CODE"
fi

# ---------------------------------------------------------------------------
# Local half: runs on the development Mac.
# ---------------------------------------------------------------------------
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ -z "${1:-}" || "$1" == -* ]]; then
    echo "Usage: $SCRIPT_NAME <ssh-host> [--no-sync|--sync-only|--dry-run] [Suite/test ...]" >&2
    exit 2
fi
HOST="$1"
shift

REPO="${0:A:h}"
if [[ "$REPO" != "$HOME"/* ]]; then
    echo "The repo must live under \$HOME so it maps to the same path on $HOST." >&2
    exit 2
fi
REMOTE_DIR="${REPO#$HOME/}"
cd "$REPO"

SYNC=1
RUN=1
DRY=0
selectors=()
for arg in "$@"; do
    case "$arg" in
        --no-sync)   SYNC=0 ;;
        --sync-only) RUN=0 ;;
        --dry-run)   DRY=1 ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "Unknown option: $arg" >&2; exit 2 ;;
        *)
            if [[ "$arg" == *UITests* ]]; then
                echo "Refusing: UI tests never run on a physical Mac (see CLAUDE.md)." >&2
                exit 2
            fi
            sel="ChangeoverTests/${arg#ChangeoverTests/}"
            # Suite/test selectors need the trailing () for Swift Testing.
            if [[ "$sel" == */*/* && "$sel" != *\) ]]; then
                sel="$sel()"
            fi
            selectors+=("$sel")
            ;;
    esac
done

if (( DRY )); then
    print -r -- "host:      $HOST:~/$REMOTE_DIR"
    print -r -- "sync:      $([[ $SYNC == 1 ]] && echo yes || echo no)"
    print -r -- "run:       $([[ $RUN == 1 ]] && echo yes || echo no)"
    if (( ${#selectors} )); then
        for sel in "${selectors[@]}"; do print -r -- "selector:  -only-testing:$sel"; done
    else
        print -r -- "selector:  -only-testing:ChangeoverTests"
    fi
    exit 0
fi

if (( SYNC )); then
    rsync -a --delete --exclude 'build/' --exclude '.DS_Store' --exclude 'xcuserdata/' \
        "$REPO/" "$HOST:$REMOTE_DIR/"
    echo "== synced to $HOST"
fi
(( RUN )) || exit 0

set +e
OUTPUT=$(ssh -n "$HOST" "zsh ~/${(q)REMOTE_DIR}/$SCRIPT_NAME --remote ${(q)REMOTE_DIR} ${(j: :)${(q)selectors[@]}}" 2>&1)
CODE=$?
set -e

print -r -- "$OUTPUT" | grep -v '^LOG=' || true

REMOTE_LOG=$(print -r -- "$OUTPUT" | sed -n 's/^LOG=//p' | tail -n 1)
if [[ -n "$REMOTE_LOG" ]]; then
    mkdir -p "build/remote-tests/$HOST"
    if scp -q "$HOST:$REMOTE_LOG" "build/remote-tests/$HOST/" 2>/dev/null; then
        echo "full log: build/remote-tests/$HOST/${REMOTE_LOG:t}"
    fi
fi
exit "$CODE"
