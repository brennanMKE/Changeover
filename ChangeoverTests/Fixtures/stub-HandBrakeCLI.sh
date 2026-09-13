#!/bin/sh
# A stand-in for HandBrakeCLI, for tests that need to drive
# DVDPipeline/EncodeController end to end on a machine with no HandBrake
# installed and no disc in any drive (#0014 §9 — review gap G6). It prints a
# couple of progress lines to stdout, writes a small placeholder file to
# whatever path follows `--output`, and exits with ${STUB_EXIT:-0}.
#
# This is also what lets #0005, #0006 and #0015 be driven without a drive —
# not test-only scaffolding.

echo "Scanning title 1 of 1..."
echo "Encoding: task 1 of 1, 50.00 %"

output=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "--output" ]; then
        output="$arg"
    fi
    prev="$arg"
done

if [ -n "$output" ]; then
    echo "stub encoded output" > "$output"
fi

exit "${STUB_EXIT:-0}"
