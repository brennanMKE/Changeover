#!/usr/bin/env zsh
# Verify a built .dmg before copying it to the other Mac: valid signature, a
# well-formed app inside, and a clear verdict on the Gatekeeper experience the
# recipient will get. Adapted from ../Batty/scripts/verify-dmg.sh, but tolerant
# of a signed-only (not notarized) DMG since that's a valid path for a self-copy.
#
# Usage: ./verify-dmg.sh <path/to/file.dmg>
#
# Exit 0 if the DMG is usable. A signed-only DMG passes with a note that the
# target Mac needs `xattr -cr`; a broken/unsigned DMG fails.

set -uo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "usage: $0 <path/to/file.dmg>"
    exit 2
fi

DMG="$1"
if [[ ! -f "$DMG" ]]; then
    print -u2 "error: not a file: $DMG"
    exit 2
fi

FAILS=0
NOTARIZED=0
MOUNT_POINT=""

cleanup() {
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

step() { print "\n==> $*"; }
pass() { print "    PASS: $*"; }
note() { print "    NOTE: $*"; }
fail() { print "    FAIL: $*"; FAILS=$((FAILS + 1)); }

# 1. DMG signature ---------------------------------------------------------
step "Codesign verification (DMG)"
if codesign --verify --verbose=2 "$DMG" >/dev/null 2>&1; then
    pass "DMG signature valid"
else
    fail "DMG signature invalid or missing"
fi

# 2. Gatekeeper assessment / notarization state ----------------------------
step "Gatekeeper assessment (DMG)"
SPCTL_OUT=$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 || true)
print "$SPCTL_OUT" | sed 's/^/    /'
# A signed-but-unnotarized DMG reports source="Unnotarized Developer ID" and an
# spctl verdict of "rejected" — that's expected here, not a failure. What proves
# it's properly signed is the Developer ID origin/source, so match on that.
if print -r -- "$SPCTL_OUT" | grep -q "source=Notarized Developer ID"; then
    pass "notarized + signed — recipient sees no Gatekeeper warning"
    NOTARIZED=1
elif print -r -- "$SPCTL_OUT" | grep -Eq "Unnotarized Developer ID|origin=Developer ID Application"; then
    note "signed but NOT notarized — fine for a self-copy after 'xattr -cr'"
else
    fail "not signed by Developer ID — Gatekeeper will block it"
fi

# 3. Stapled ticket (only meaningful if notarized) -------------------------
step "Stapler ticket"
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    pass "stapled ticket present (works offline, no xattr)"
elif [[ "$NOTARIZED" == "1" ]]; then
    fail "notarized but ticket not stapled — offline recipients will see warnings"
else
    note "no ticket (expected for a signed-only DMG)"
fi

# 4-7. Mount and inspect the inner app -------------------------------------
step "Mounting DMG to inspect inner app"
ATTACH_OUT=$(hdiutil attach -nobrowse -noautoopen -noverify "$DMG" 2>&1)
MOUNT_POINT=$(print -r -- "$ATTACH_OUT" | awk -F'\t' '/Apple_HFS|Apple_APFS/ { print $NF }' | tail -1)
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
    fail "could not mount DMG"
    print "$ATTACH_OUT" | sed 's/^/    /'
else
    pass "mounted at $MOUNT_POINT"

    APP=$(/bin/ls -d "$MOUNT_POINT"/*.app 2>/dev/null | head -1)
    if [[ -z "$APP" ]]; then
        fail "no .app bundle found in DMG"
    elif [[ ! -L "$MOUNT_POINT/Applications" ]]; then
        fail "no /Applications symlink — recipient can't drag-install"
    else
        pass "contains $(basename "$APP") + /Applications drop target"

        step "Codesign verification (inner app)"
        if codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1; then
            pass "app signature deep-valid"
        else
            fail "app signature invalid"
        fi

        step "Hardened runtime + trust chain (inner app)"
        CS_OUT=$(codesign -dvv "$APP" 2>&1)
        if print -r -- "$CS_OUT" | grep -q "flags=.*runtime"; then
            pass "hardened runtime enabled"
        else
            note "hardened runtime not enabled (required only if you notarize)"
        fi
        TEAM=$(print -r -- "$CS_OUT" | awk -F= '/^TeamIdentifier=/ { print $2 }')
        IDENT=$(print -r -- "$CS_OUT" | awk -F= '/^Identifier=/ { print $2 }')
        print "    TeamIdentifier: $TEAM"
        print "    Bundle identifier: $IDENT"
    fi
fi

# Summary ------------------------------------------------------------------
print
print "================================================================"
if [[ $FAILS -gt 0 ]]; then
    print "  RESULT: NOT USABLE — $FAILS check(s) failed"
    print "================================================================"
    exit 1
elif [[ "$NOTARIZED" == "1" ]]; then
    print "  RESULT: READY — notarized, installs cleanly on any Mac"
else
    print "  RESULT: USABLE — signed-only; on the target Mac run:"
    print "            xattr -cr /Applications/$(basename "${APP:-Changeover.app}")"
fi
print "================================================================"
exit 0
