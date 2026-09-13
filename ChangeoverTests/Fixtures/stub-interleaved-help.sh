#!/bin/sh
# #0008 review fix 4: a HandBrakeCLI-shaped --help transcript whose
# "--input" token is deliberately split across two separate stdout writes
# with a stderr write in between — reproducing, on demand and
# deterministically, the kind of stdout/stderr interleaving the real H1
# capture shows happening for real (issues/0008.md's `## Gotchas`).
#
# Read through Preflight's dedicated two-pipe `--help` runner (stdout on its
# own pipe, stderr drained and discarded on a second one), the stdout byte
# stream never contains the stderr line at all, so "--input" reassembles
# correctly. Read through a single merged pipe (the falsification for this
# fixture: temporarily point `process.standardError` at the same pipe as
# `process.standardOutput` in `runHelpProbe`), the stderr line lands between
# the two stdout writes in the byte stream, and "--input" never appears as
# a whole token.
printf -- '--inp'
echo 'libhb: some interleaved stderr line' >&2
printf 'ut <string>\n'
echo '--output <string>'
echo '--main-feature'
echo '--title <number>'
echo '--format <string>'
echo '--encoder <string> x265'
echo '--encoder-preset <string>'
echo '--quality <number>'
echo '--aencoder <string>'
echo '--markers'
echo '--filler1'
echo '--filler2'
echo '--filler3'
echo '--filler4'
echo '--filler5'
echo '--filler6'
echo '--filler7'
echo '--filler8'
echo '--filler9'
echo '--filler10'
echo '--filler11'
echo '--filler12'
exit 0
