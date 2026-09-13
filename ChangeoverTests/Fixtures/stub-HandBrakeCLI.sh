#!/bin/sh
# A stand-in for HandBrakeCLI, for tests that need to drive
# DVDPipeline/EncodeController end to end on a machine with no HandBrake
# installed and no disc in any drive (#0014 §9 — review gap G6). It prints a
# couple of progress lines to stdout, writes a small placeholder file to
# whatever path follows `--output`, and exits with ${STUB_EXIT:-0}.
#
# This is also what lets #0005, #0006 and #0015 be driven without a drive —
# not test-only scaffolding.
#
# #0015 extends this for MakeMKVFallbackTests: when a sidecar config file,
# "$0.conf", exists next to this script, it is sourced and STUB_EXIT is
# ignored. The conf file may set:
#   EXIT_DIR_INPUT  — exit code when --input names a directory (a disc)
#   EXIT_FILE_INPUT — exit code when --input names a file (a ripped .mkv)
#   ARGV_LOG        — path to append this invocation's argv to, one line
#
# #0009 extends the same sidecar mechanism, backward-compatibly, for
# ProcessRunnerTests/HandBrakeFailureClassifierTests:
#   OUTPUT_FIXTURE  — a file to `cat` (raw bytes, unmodified) after the two
#                     progress lines, for feeding a captured or synthetic
#                     transcript through the real reader/drain path
#   WRITE_OUTPUT    — 0 skips writing the placeholder `--output` file
#                     (default 1, i.e. always write it, same as before)
#   SLEEP_SECONDS   — sleep this long before exiting, for the inactivity
#                     watchdog test
#
# With no "$0.conf" present, behavior is byte for byte what it always was —
# EncodeControllerTests' STUB_EXIT keeps working unmodified, so it and
# MakeMKVFallbackTests/ProcessRunnerTests (which use their own per-test copy +
# sidecar file) can run concurrently under Swift Testing without racing a
# shared env var.

conf="$0.conf"
using_conf=0
if [ -f "$conf" ]; then
    . "$conf"
    using_conf=1
fi

if [ -n "$ARGV_LOG" ]; then
    echo "$@" >> "$ARGV_LOG"
fi

echo "Scanning title 1 of 1..."
echo "Encoding: task 1 of 1, 50.00 %"

if [ -n "$OUTPUT_FIXTURE" ] && [ -f "$OUTPUT_FIXTURE" ]; then
    cat "$OUTPUT_FIXTURE"
fi

input=""
output=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "--input" ]; then
        input="$arg"
    fi
    if [ "$prev" = "--output" ]; then
        output="$arg"
    fi
    prev="$arg"
done

if [ -n "$output" ] && [ "${WRITE_OUTPUT:-1}" != "0" ]; then
    echo "stub encoded output" > "$output"
fi

if [ -n "$SLEEP_SECONDS" ]; then
    sleep "$SLEEP_SECONDS"
fi

if [ "$using_conf" = "1" ]; then
    if [ -d "$input" ]; then
        exit "${EXIT_DIR_INPUT:-0}"
    else
        exit "${EXIT_FILE_INPUT:-0}"
    fi
fi

exit "${STUB_EXIT:-0}"
