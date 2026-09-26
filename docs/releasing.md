# Releasing Changeover

Changeover is distributed from its own website, not the App Store — it cannot be
sandboxed, because it runs HandBrakeCLI and writes to volumes the user picks. So
it is signed with Developer ID, notarized by Apple, and updates itself with
Sparkle.

The same shape as [Curator](../../Curator), deliberately: one version in one
file, a GitHub release per version, and a website that serves the DMG and the
update feed.

## One-time setup

### 1. The Sparkle signing key

Sparkle signs each update with an EdDSA key. The public half goes in
`Config/App.xcconfig`; the private half never leaves this machine and is never
in the repo.

```sh
"$(scripts/sparkle-tool.sh generate_keys)" -f ~/.sparkle/Changeover.key
```

That prints the **public** key. Put it in `Config/App.xcconfig`:

```
SU_PUBLIC_ED_KEY = <the printed key>
```

Back `~/.sparkle/Changeover.key` up somewhere safe. **Losing it ends the update
channel**: every existing install verifies against the public key baked into
it, so a new key means those copies will never accept another update and have to
be re-downloaded by hand.

Until the key exists `SU_PUBLIC_ED_KEY` is empty, and that is a safe state:
Sparkle refuses an update it cannot verify, the "Check for Updates…" menu item
is hidden, and nothing updates. An unverified update channel would be worse than
none, because this app runs command-line tools.

### 2. Notarization credentials

```sh
./setup-notary.sh
```

Stores an App Store Connect API key in the keychain as a `notarytool` profile.
`release.sh` finds it and notarizes; without it, it builds a signed-only DMG and
says so.

## Each release

```sh
# 1. Bump the version. This file is the only place it lives.
#    Config/App.xcconfig -> MARKETING_VERSION = X.Y.Z

# 2. Write the release notes under "## X.Y.Z" in CHANGELOG.md.

# 3. Build, sign, notarize, staple, package.
./release.sh
#    -> dist/Changeover-X.Y.Z.dmg and .dmg.sha256

# 4. Verify what you are about to publish.
./verify-dmg.sh dist/Changeover-X.Y.Z.dmg

# 5. Tag and push.
scripts/tag-release.sh --push

# 6. Create the GitHub release and attach the DMG.
scripts/publish-release.sh

# 7. Add it to the site: signs the appcast item, rebuilds changelog.html,
#    points the download button at the new DMG.
scripts/update-website.sh
git add website && git commit -m "Release X.Y.Z"
```

Then whoever owns deployment publishes `website/` and copies the DMG from the
GitHub release into `website/downloads/`. See `website/README.md`.

## Why the version lives in one file

`Config/App.xcconfig` is the single source. Nothing sets `MARKETING_VERSION` in
the Xcode project, and `release.sh` reads it from there to name the DMG.

This matters because Sparkle decides *whether there is an update* from
`CFBundleVersion` — the build number, set to a UTC timestamp at archive time so
every build sorts after the last — but *shows the user* the marketing version.
Two copies of the marketing version that disagree produce the worst possible
dialog: "you're up to date, running 1.0.2" offered to somebody on 1.0.1. The
version-consistency check in `release.sh` fails the build rather than ship that.

For the same reason `scripts/appcast-item.sh` reads every value — version, build
number, minimum OS, file size — out of the finished DMG. Nothing in the appcast
is typed by hand.

## Rebuilding `favicon.ico`

The PNGs regenerate with `sips` (see `website/README.md`). macOS ships no `.ico`
writer, so:

```sh
python3 - <<'PY'
import struct
sizes = [(16, "website/assets/favicon-16.png"),
         (32, "website/assets/favicon-32.png"),
         (48, "/tmp/favicon-48.png")]
imgs = [(s, open(p, "rb").read()) for s, p in sizes]
header = struct.pack("<HHH", 0, 1, len(imgs))
offset, entries, payload = 6 + 16 * len(imgs), b"", b""
for size, data in imgs:
    entries += struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(data), offset)
    payload += data
    offset += len(data)
open("website/favicon.ico", "wb").write(header + entries + payload)
PY
```

An `.ico` may carry PNG payloads for sizes up to 256, which every current
browser reads — so this needs no image library.

## What is deliberately not automated

**Notarizing and publishing.** `release.sh` submits to Apple and
`publish-release.sh` creates a public GitHub release. Both put something outside
this machine that cannot be quietly taken back, so a person runs them.

**Generating or replacing the signing key.** Losing or rotating it breaks
updates for every existing install.
