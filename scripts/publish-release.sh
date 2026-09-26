#!/usr/bin/env zsh
# Create the GitHub release for v<MARKETING_VERSION>, attaching the notarized DMG and its
# SHA-256. Release notes come from that version's section in CHANGELOG.md.
#
# Usage: scripts/publish-release.sh [--draft]
#
# Run after ./release.sh and scripts/tag-release.sh --push. The release is public
# unless --draft, so a person runs this.

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"
VERSION="$(awk -F= '/^MARKETING_VERSION/ { gsub(/ /, "", $2); print $2 }' Config/App.xcconfig)"
TAG="v$VERSION"
DMG="dist/Changeover-$VERSION.dmg"

fail() { print -u2 -r -- "error: $*"; exit 1; }

[[ -f "$DMG" && -f "$DMG.sha256" ]] || fail "$DMG (and .sha256) not found; run ./release.sh"
(cd dist && shasum -a 256 -c "${DMG:t}.sha256" >/dev/null) || fail "$DMG doesn't match its .sha256"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || fail "$TAG isn't on origin; run scripts/tag-release.sh --push"
gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists"

print "==> Re-verifying the DMG"
./verify-dmg.sh "$DMG" >/dev/null || fail "$DMG no longer verifies; run ./verify-dmg.sh $DMG"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
awk -v v="$VERSION" '
    $0 == "## " v || index($0, "## " v " ") == 1 { on = 1; next }
    on && /^## / { exit }
    on { print }
' CHANGELOG.md > "$NOTES"
[[ -n "$(tr -d '[:space:]' < "$NOTES")" ]] || fail "no notes under '## $VERSION' in CHANGELOG.md"
cat >> "$NOTES" <<NOTES_END

---

**Install:** download \`Changeover-$VERSION.dmg\`, open it and drag Changeover to Applications. It's
signed with Developer ID and notarized by Apple. Requires macOS 26 or later.
NOTES_END

args=(--title "Changeover $VERSION" --notes-file "$NOTES" --verify-tag)
[[ "${1:-}" == "--draft" ]] && args+=(--draft)
print "==> Creating GitHub release $TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" "${args[@]}"
