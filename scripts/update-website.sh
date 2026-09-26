#!/usr/bin/env zsh
# Adds a release to website/: prepends its signed Sparkle item to appcast.xml, rebuilds
# changelog.html from CHANGELOG.md, and points the download button at the new DMG.
# Run after ./release.sh, then commit website/.
#
# The DMG itself isn't copied here. It's attached to the GitHub release, and whoever deploys
# the site puts it in downloads/ from there (see website/README.md). The Sparkle signature is
# made from dist/Changeover-X.Y.Z.dmg, the same file publish-release.sh attaches, so it matches.
#
# Usage: scripts/update-website.sh [X.Y.Z]   (defaults to MARKETING_VERSION)

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
SITE_DIR="$REPO_ROOT/website"
VERSION="${1:-$(awk -F= '/^MARKETING_VERSION/ { gsub(/ /, "", $2); print $2 }' "$REPO_ROOT/Config/App.xcconfig")}"
DMG="$REPO_ROOT/dist/Changeover-$VERSION.dmg"

fail() { print -u2 -r -- "error: $*"; exit 1; }
[[ -f "$DMG" ]] || fail "$DMG not found; run ./release.sh"
xcrun stapler validate "$DMG" >/dev/null 2>&1 || fail "$DMG isn't notarized and stapled"
grep -q "<sparkle:shortVersionString>$VERSION<" "$SITE_DIR/appcast.xml" && fail "appcast.xml already has $VERSION"

print "==> Signing and adding the appcast item"
ITEM_FILE="$(mktemp)"
trap 'rm -f "$ITEM_FILE"' EXIT
"$REPO_ROOT/scripts/appcast-item.sh" "$DMG" > "$ITEM_FILE"

/usr/bin/python3 - "$SITE_DIR" "$REPO_ROOT/CHANGELOG.md" "$VERSION" "$ITEM_FILE" <<'PY'
import html, re, sys, pathlib
site, changelog, version, item_file = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

# appcast.xml: newest item first, right after the marker.
appcast = site / "appcast.xml"
text = appcast.read_text()
marker = re.search(r"<!-- ITEMS:.*?-->\n", text)
text = text[:marker.end()] + pathlib.Path(item_file).read_text() + text[marker.end():]
appcast.write_text(text)

# index.html: the download button points at this DMG.
index = site / "index.html"
page = index.read_text()
block = (
    "<!-- LATEST: updated by scripts/update-website.sh -->\n"
    f'                <a class="download" href="downloads/Changeover-{version}.dmg">Download Changeover {version}</a>\n'
    '                <span class="fineprint">Free and open source. Requires macOS 26 and a Plex Media Server.</span>\n'
    "                <!-- /LATEST -->"
)
page = re.sub(r"<!-- LATEST:.*?<!-- /LATEST -->", block, page, flags=re.S)
index.write_text(page)

# changelog.html from CHANGELOG.md.
def inline(s):
    s = html.escape(s, quote=False)
    return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
sections, current = [], None
for line in open(changelog).read().splitlines():
    if line.startswith("## "):
        current = {"version": line[3:].split()[0], "lines": []}
        sections.append(current)
    elif current is not None:
        current["lines"].append(line)
body = []
for s in sections:
    v = s["version"]
    body.append(f'        <h2 id="v{v.replace(".", "-")}">Changeover {v}</h2>')
    paras, items, buf = [], [], []
    for line in s["lines"] + [""]:
        if line.startswith("- "): items.append(line[2:])
        elif line.startswith("  ") and items: items[-1] += " " + line.strip()
        elif line.strip(): buf.append(line.strip())
        elif buf: paras.append(" ".join(buf)); buf = []
    body += [f"        <p>{inline(p)}</p>" for p in paras]
    if items:
        body.append("        <ul>")
        body += [f"            <li>{inline(i)}</li>" for i in items]
        body.append("        </ul>")
template = (site / "src" / "changelog.template.html").read_text()
(site / "changelog.html").write_text(template.replace("<!-- ENTRIES -->", "\n".join(body)))
PY

xmllint --noout "$SITE_DIR/appcast.xml" || fail "appcast.xml isn't valid XML"
print "==> website/ updated for $VERSION. Review and commit it."
