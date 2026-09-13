#!/usr/bin/env zsh
#
# Run Changeover's unit tests on gordon and print a short summary.
#
#   ./test-on-gordon.sh                                  # sync, then run all of ChangeoverTests
#   ./test-on-gordon.sh ProcessRunnerTests/runReturns    # sync, then run one test
#   ./test-on-gordon.sh --no-sync ProcessRunnerTests/x   # run gordon's copy as-is (falsification)
#   ./test-on-gordon.sh --sync-only                      # restore gordon's copy from this Mac
#   ./test-on-gordon.sh --dry-run ProcessRunnerTests/x   # show the selectors, run nothing
#
# Selectors may omit the "ChangeoverTests/" prefix and the trailing "()".
# UI tests are refused. The full xcodebuild log is copied to
# build/gordon-tests/ and never printed.
#
# Exit status: 0 passed, 1 failed, 2 usage error or gordon busy, 124 timed out.
#
# Environment: GORDON_HOST (default gordon), TEST_TIMEOUT seconds (default 1500).

set -euo pipefail

HOST="${GORDON_HOST:-gordon}"
REMOTE_DIR="Developer/brennanMKE/Changeover"
TIMEOUT="${TEST_TIMEOUT:-1500}"
SCRIPT_NAME="test-on-gordon.sh"

# ---------------------------------------------------------------------------
# Remote half: runs on gordon, invoked by the local half over ssh.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--remote" ]]; then
    shift
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
REPO="${0:A:h}"
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
        -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          echo "Unknown option: $arg" >&2; exit 2 ;;
        *)
            if [[ "$arg" == *UITests* ]]; then
                echo "Refusing: UI tests never run on a physical Mac (see CLAUDE.md)." >&2
                exit 2
            fi
            sel="${arg#ChangeoverTests/}"
            sel="ChangeoverTests/$sel"
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
OUTPUT=$(ssh -n "$HOST" "zsh ~/$REMOTE_DIR/$SCRIPT_NAME --remote ${(j: :)${(q)selectors[@]}}" 2>&1)
CODE=$?
set -e

print -r -- "${OUTPUT%%$'\n'LOG=*}" | grep -v '^LOG=' || true

REMOTE_LOG=$(print -r -- "$OUTPUT" | sed -n 's/^LOG=//p' | tail -n 1)
if [[ -n "$REMOTE_LOG" ]]; then
    mkdir -p build/gordon-tests
    if scp -q "$HOST:$REMOTE_LOG" build/gordon-tests/ 2>/dev/null; then
        echo "full log: build/gordon-tests/${REMOTE_LOG:t}"
    fi
fi
exit "$CODE"
