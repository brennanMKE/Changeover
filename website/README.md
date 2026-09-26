# Changeover website

The static site at [changeover.sstools.co](https://changeover.sstools.co/). Three jobs:

1. **The landing page** (`index.html`): what Changeover is, and the download.
2. **The Sparkle update feed** (`appcast.xml`). Release builds check
   `https://changeover.sstools.co/appcast.xml`, set in `Config/App.xcconfig`.
3. **Release DMGs** (`downloads/`), filled at deploy time from the GitHub
   releases. **Never in git** — `.gitignore` has `website/downloads/*.dmg`.

No build step: plain HTML and one stylesheet, no external fonts or scripts.

## Files

| File | Edited by |
|---|---|
| `index.html`, `privacy.html`, `css/style.css` | hand |
| `appcast.xml` | `scripts/update-website.sh` only — never by hand, because each item carries a signature over the exact DMG |
| `changelog.html` | generated from `CHANGELOG.md` via `src/changelog.template.html` |
| `favicon.ico`, `favicon.svg`, `assets/*` | generated from the app icon; see below |

## Icons

Everything derives from the app icon
(`Changeover/Assets.xcassets/AppIcon.appiconset/appstore1024.png`), cropped to
drop the transparent margin macOS app icons carry — without that crop the mark
is too small to read at 16px.

| File | Size | For |
|---|---|---|
| `favicon.svg` | vector | Current Safari and Chrome. Hand-authored to match the icon; the one that stays crisp at any size |
| `favicon.ico` | 16, 32, 48 | Older browsers, and the one browsers request without being asked |
| `assets/favicon-16.png`, `-32.png` | 16, 32 | Declared explicitly for browsers that prefer PNG |
| `assets/apple-touch-icon.png` | 180 | iOS home screen |
| `assets/icon-192.png`, `icon-512.png` | 192, 512 | `site.webmanifest` |
| `assets/changeover-icon.png` | 256 | The header mark on the page |

To regenerate after an icon change:

```sh
SRC=Changeover/Assets.xcassets/AppIcon.appiconset/appstore1024.png
sips -c 880 880 --cropOffset 72 72 "$SRC" --out /tmp/icon-cropped.png
for spec in 16:favicon-16 32:favicon-32 180:apple-touch-icon \
            192:icon-192 512:icon-512 256:changeover-icon; do
    sips -Z "${spec%%:*}" /tmp/icon-cropped.png --out "website/assets/${spec##*:}.png"
done
```

`favicon.ico` is built from the 16/32/48 PNGs by the snippet in
`docs/releasing.md`; `favicon.svg` is hand-edited and should be changed
alongside the app icon rather than regenerated.

## Deploying

Whoever deploys the site needs to, for each release:

1. Pull `website/` at the tag.
2. Download `Changeover-X.Y.Z.dmg` from that version's GitHub release into
   `downloads/`.
3. Publish. `appcast.xml` already names that exact file, with a signature over
   its bytes — so the DMG on the host must be byte-identical to the one
   attached to the release, or Sparkle will refuse the update.

The `.sha256` beside each DMG in the GitHub release is there to check that.
