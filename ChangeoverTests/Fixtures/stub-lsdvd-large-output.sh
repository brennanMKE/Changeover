#!/bin/sh
# Fake `lsdvd -x -Oj` used only by ChangeoverTests/DVDMonitorTests.swift's
# pipe-deadlock regression test (#0013 re-pass). Emits valid JSON with a
# `dvddiscid` plus a ~300KB pad field — well over the pipe's ~64KB kernel
# buffer, exactly the shape that deadlocked the old read-after-wait
# `LSDVDIdentity.discID` (reviewer's own repro number). `LSDVDIdentity`
# ignores every argument it's called with here, so `-x -Oj <mountPath>` is
# accepted but unused.

pad=$(head -c 300000 /dev/zero | tr '\0' 'A')
printf '{"device": "/dev/rdisk6", "title": "FARGO_SE__16X9", "dvddiscid": "ceaaceba983071d9a7e28fd6107947b7", "pad": "%s"}\n' "$pad"
exit 0
