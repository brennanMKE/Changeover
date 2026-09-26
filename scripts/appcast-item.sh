#!/usr/bin/env zsh
# Prints the Sparkle appcast <item> for a release DMG. Every value is read from the DMG itself
# (never typed by hand), and the EdDSA signature comes from the key file, not the Keychain.
# Adapted from Batty's scripts/appcast-item.sh.
#
# Usage: scripts/appcast-item.sh dist/Changeover-X.Y.Z.dmg
#
# SPARKLE_KEY_FILE overrides the key location (default ~/.sparkle/Changeover.key).

set -euo pipefail

DMG="$1"
REPO_ROOT="${0:A:h:h}"
SITE="https://changeover.sstools.co"
KEY="${SPARKLE_KEY_FILE:-$HOME/.sparkle/Changeover.key}"
[[ -f "$DMG" ]] || { print -u2 "error: no DMG at $DMG"; exit 1; }
[[ -f "$KEY" ]] || { print -u2 "error: Sparkle key not found at $KEY (see docs/releasing.md)"; exit 1; }

MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\// { print $NF }')"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT
plist="$MOUNT/Changeover.app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
hdiutil detach "$MOUNT" -quiet
trap - EXIT

sign_update="$("$REPO_ROOT/scripts/sparkle-tool.sh" sign_update)"
signature="$("$sign_update" --ed-key-file "$KEY" -p "$DMG")"
"$sign_update" --verify --ed-key-file "$KEY" "$DMG" "$signature" >/dev/null \
    || { print -u2 "error: the signature doesn't verify"; exit 1; }
length="$(stat -f %z "$DMG")"
anchor="v${version//./-}"
file="${DMG:t}"
[[ "$file" == "Changeover-$version.dmg" ]] || { print -u2 "error: expected the DMG to be named Changeover-$version.dmg"; exit 1; }

# The release notes: this version's section of CHANGELOG.md as simple HTML.
notes="$(/usr/bin/python3 - "$REPO_ROOT/CHANGELOG.md" "$version" <<'PY'
import html, re, sys
text = open(sys.argv[1]).read().splitlines()
version, out, on = sys.argv[2], [], False
for line in text:
    if re.match(r"^## ", line):
        if on: break
        on = line[3:].split()[0] == version
        continue
    if on: out.append(line)
def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    # Backticks are markdown, not text: without this the update dialog shows
    # a literal `Movies/Title (Year) {tmdb-ID}/...` with the backticks in it.
    return re.sub(r"`(.+?)`", r"<code>\1</code>", s)
paras, items, buf = [], [], []
for line in out + [""]:
    if line.startswith("- "):
        items.append(line[2:])
    elif line.startswith("  ") and items:
        items[-1] += " " + line.strip()
    elif line.strip():
        buf.append(line.strip())
    else:
        if buf: paras.append("<p>" + inline(" ".join(buf)) + "</p>"); buf = []
body = "".join(paras)
if items: body += "<ul>" + "".join("<li>" + inline(i) + "</li>" for i in items) + "</ul>"
print(body)
PY
)"

cat <<ITEM
    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$SITE/changelog.html#$anchor</sparkle:releaseNotesLink>
      <description><![CDATA[$notes]]></description>
      <enclosure url="$SITE/downloads/$file" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
ITEM
