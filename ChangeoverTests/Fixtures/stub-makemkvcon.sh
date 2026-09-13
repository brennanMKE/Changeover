#!/bin/sh
# A stand-in for makemkvcon, for #0015's fallback tests — drives
# MakeMKVRipper/DVDPipeline end to end with no MakeMKV installed and no disc
# in any drive.
#
# Controlled by a sidecar config file, "$0.conf" — deliberately NOT
# environment variables. stub-HandBrakeCLI.sh's existing
# STUB_EXIT (EncodeControllerTests) is process-wide and Swift Testing runs
# suites concurrently; an env-driven stub here would race it. Each test
# copies this script into its own temp directory and writes the ".conf" file
# beside it, so concurrent test runs never share state.
#
# Recognizes the command word among its arguments:
#   info <source>               — prints $INFO_FIXTURE's contents (if set
#                                  and readable), exits ${INFO_EXIT:-0}
#   mkv <source> <index> <dir>  — writes $MKV_FILES .mkv file(s) (default 1,
#                                  first named $MKV_NAME, default
#                                  "title.mkv") into <dir>, exits
#                                  ${MKV_EXIT:-0}
#
# Every invocation's argv is appended as one line to $ARGV_LOG, if set.

conf="$0.conf"
if [ -f "$conf" ]; then
    . "$conf"
fi

if [ -n "$ARGV_LOG" ]; then
    echo "$@" >> "$ARGV_LOG"
fi

command=""
last=""
for arg in "$@"; do
    case "$arg" in
        info|mkv) command="$arg" ;;
    esac
    last="$arg"
done

if [ "$command" = "info" ]; then
    if [ -n "$INFO_FIXTURE" ] && [ -f "$INFO_FIXTURE" ]; then
        cat "$INFO_FIXTURE"
    fi
    exit "${INFO_EXIT:-0}"
fi

if [ "$command" = "mkv" ]; then
    outdir="$last"
    count="${MKV_FILES:-1}"
    name="${MKV_NAME:-title.mkv}"
    mkdir -p "$outdir" 2>/dev/null
    i=0
    while [ "$i" -lt "$count" ]; do
        if [ "$i" -eq 0 ]; then
            fname="$name"
        else
            fname="extra${i}-${name}"
        fi
        echo "stub ripped output" > "$outdir/$fname"
        i=$((i + 1))
    done
    exit "${MKV_EXIT:-0}"
fi

# Unrecognized command word — never seen in practice (info/mkv only), fail
# loudly rather than silently succeeding.
exit 1
