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
#                     watchdog test. Uses `exec sleep`, which replaces this
#                     script's process image rather than forking a child: a
#                     forked child would inherit this process's end of the
#                     output pipe, and killing only the parent would leave
#                     the pipe open (no EOF) until the orphaned child's sleep
#                     finished on its own — precisely the "inherited pipe
#                     end" risk #0009 §9 calls out. `exec` means there is
#                     only ever one process, so a signal to it ends the sleep
#                     immediately and closes the pipe right away.
#
# #0008 extends the same sidecar mechanism for `PreflightTests` and every
# stub-driven pipeline test: when invoked as `--help` (Preflight's P2
# capability check), this script never falls through to any of the above —
# it answers immediately, before the ARGV_LOG append, so preflight's own
# invocation never shows up in a test's argv log (`hbLines.count == 2`-style
# assertions in MakeMKVFallbackTests must keep counting only the real encode
# calls). It also always exits 0, ignoring STUB_EXIT/EXIT_DIR_INPUT/
# EXIT_FILE_INPUT, because a `.conf` written to make the *encode* invocation
# fail must never also make the `--help` probe fail:
#   HELP_FIXTURE    — a file to `cat` verbatim as the --help transcript.
#
# When HELP_FIXTURE is unset, this looks for the real capture
# (`handbrake/help-hb1.11.2-exit0.txt`, alongside this script) relative to
# *this script's own location* (`$0`) — which resolves correctly when tests
# run this file straight from `ChangeoverTests/Fixtures/`, but not for
# `MakeMKVFallbackTests`' `copyStub`, which copies only this one `.sh` file
# into a fresh per-test temp directory with no `handbrake/` sibling. Falls
# back to the embedded SYNTHETIC transcript below for exactly that case —
# never adjusted to match the real capture; kept only so a copied stub with
# no `.conf` at all still produces a `.compatible`-parseable transcript.
#
# With no "$0.conf" present, behavior is byte for byte what it always was
# except for the new --help branch — EncodeControllerTests' STUB_EXIT keeps
# working unmodified, so it and MakeMKVFallbackTests/ProcessRunnerTests
# (which use their own per-test copy + sidecar file) can run concurrently
# under Swift Testing without racing a shared env var.

conf="$0.conf"
using_conf=0
if [ -f "$conf" ]; then
    . "$conf"
    using_conf=1
fi

if [ "$1" = "--help" ]; then
    real_capture="$(dirname "$0")/handbrake/help-hb1.11.2-exit0.txt"
    if [ -n "$HELP_FIXTURE" ] && [ -f "$HELP_FIXTURE" ]; then
        cat "$HELP_FIXTURE"
    elif [ -f "$real_capture" ]; then
        # The real thing: HandBrakeCLI 1.11.2 on joe, `--help 2>&1`, captured
        # verbatim (issues/0008.md's `## Fix`). Confirmed by
        # PreflightTests.capabilityIsCompatibleAgainstTheRealCaptureH1 to
        # parse as `.compatible`.
        cat "$real_capture"
    else
        # SYNTHETIC help, not a capture. Kept in sync with
        # Preflight.requiredHelpTokens() by PreflightTests' stub-sync test —
        # every long flag EncodeController.arguments() passes appears here as
        # its own whitespace-separated token, Config.videoEncoder ("x265")
        # appears as a standalone token under --encoder, and the block has
        # well over 20 distinct "--"-prefixed tokens so it clears the
        # recognition gate.
        cat <<'HELP_EOF'
Usage: HandBrakeCLI [options] -i <device> -o <file>

General options ---------------------------------------------------------
   -h, --help              Print help
       --version           Print version
   -v, --verbose <string>  Be verbose

Source options -----------------------------------------------------------
   -i, --input <string>    Set input device
   -t, --title <number>    Select a title to encode
       --main-feature      Detect and select the main feature title
   -c, --chapters <string> Select chapters (e.g. "1-3")
       --min-duration <number>  Set the minimum title duration (seconds)
       --scan              Scan only

Output options ------------------------------------------------------------
   -o, --output <string>   Set output file name
   -f, --format <string>   Set output format: av_mp4, av_mkv
   -m, --markers           Add chapter markers
       --optimize          Optimize mp4 files for HTTP streaming

Video options --------------------------------------------------------------
   -e, --encoder <string>  Select video encoder: x265 (default), x264, mpeg4
       --encoder-preset <string>  Encoder preset: ultrafast..placebo, slow default
       --encoder-profile <string>  Encoder profile
       --encoder-level <string>  Encoder level
   -q, --quality <number>  Set video quality
   -b, --vb <number>       Set video bitrate
   -2, --two-pass          Use two-pass encoding
   -r, --rate <number>     Set video framerate

Audio options --------------------------------------------------------------
   -E, --aencoder <string> Audio encoder(s): copy, av_aac, copy:aac
   -B, --ab <number>       Set audio bitrate(s)
   -6, --mixdown <string>  Format(s) for audio down/up-mix
   -R, --arate <number>    Set audio track(s) sample rate(s)

Picture settings ------------------------------------------------------------
       --width <number>    Set picture width
       --height <number>   Set picture height
       --crop <T:B:L:R>    Set cropping values
       --loose-crop        Always crop to a multiple of the modulus
       --deinterlace       Deinterlace video with FFmpeg yadif filter
       --decomb            Deinterlace video with decomb, only if needed
       --detelecine        Detelecine video with FFmpeg
       --rotate            Rotate the video
       --grayscale         Grayscale encoding
HELP_EOF
    fi
    exit 0
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
    # `exec` replaces this process rather than forking — see the comment
    # above. This never returns, so it must be the last thing the script
    # does; a caller relying on `SLEEP_SECONDS` expects to kill the process
    # during the sleep, not to see the exit-code logic below run afterward.
    exec sleep "$SLEEP_SECONDS"
fi

if [ "$using_conf" = "1" ]; then
    if [ -d "$input" ]; then
        exit "${EXIT_DIR_INPUT:-0}"
    else
        exit "${EXIT_FILE_INPUT:-0}"
    fi
fi

exit "${STUB_EXIT:-0}"
