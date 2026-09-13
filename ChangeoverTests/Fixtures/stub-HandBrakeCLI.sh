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
# With no "$0.conf" present, behavior is byte for byte what it always was —
# EncodeControllerTests' STUB_EXIT keeps working unmodified, so it and
# MakeMKVFallbackTests (which uses its own per-test copy + sidecar file) can
# run concurrently under Swift Testing without racing a shared env var.

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

if [ -n "$output" ]; then
    echo "stub encoded output" > "$output"
fi

if [ "$using_conf" = "1" ]; then
    if [ -d "$input" ]; then
        exit "${EXIT_DIR_INPUT:-0}"
    else
        exit "${EXIT_FILE_INPUT:-0}"
    fi
fi

exit "${STUB_EXIT:-0}"
