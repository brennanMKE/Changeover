# Releasing Changeover: signed DMG, notarization, and Sparkle updates

How to turn a working checkout into a `.dmg` that a stranger can download
from a website, drag into `/Applications`, and launch without seeing a
Gatekeeper warning — and how to make that app update itself from then on.

Read the whole thing once before running anything. The order matters: the
versioning decisions in Part 1 are baked into every artifact produced by
Parts 4 and 5, and changing them after the first public release is painful.

---

## What already exists, and what is missing

The repository root already carries most of the packaging pipeline:

| File | What it does |
|---|---|
| `release.sh` | Archives Release, exports a Developer ID–signed `.app`, stages it beside an `/Applications` symlink, packs a compressed DMG with `hdiutil`, signs the DMG, and — if a notary profile is configured — notarizes, staples, and runs a Gatekeeper check. Output: `dist/Changeover-<sha>.dmg` |
| `setup-notary.sh` | Stores the app-specific Apple ID password in a keychain profile that `notarytool` reads |
| `verify-dmg.sh` | Independent verification of a built image |
| `build.sh` | Ordinary development build |

What is **not** in place yet, and what this document covers:

1. **Hardened Runtime is not enabled.** `ENABLE_HARDENED_RUNTIME` does not
   appear anywhere in `Changeover.xcodeproj/project.pbxproj`. Notarization
   rejects binaries without it. This is a hard blocker and is Part 2.
2. **Versioning is static.** `MARKETING_VERSION = 1.0` and
   `CURRENT_PROJECT_VERSION = 1` are hardcoded across all four targets.
   `release.sh` injects a timestamp build number at archive time, which
   solves telling two images apart but not what the numbers *mean*. Part 1.
3. **No Sparkle.** There is no update mechanism of any kind. Parts 3 and 5.
4. **No hosting.** An appcast needs a stable HTTPS URL. Part 5.

Fixed facts this document assumes, all read from the project as it stands:

- Bundle identifier `co.sstools.Changeover`, team `XV8BAAVZ6V`
- Deployment target macOS 26.2
- `INFOPLIST_KEY_LSUIElement = YES` — a menu bar app with no Dock icon,
  which has real consequences for Sparkle's UI (see Part 3)
- `ENABLE_APP_SANDBOX = NO` — this simplifies Sparkle considerably
- `GENERATE_INFOPLIST_FILE = YES` with `INFOPLIST_FILE = Changeover/Info.plist`

---

## Part 1 — Versioning discipline

Do this first. Sparkle decides whether an update exists by comparing version
numbers, and the most common way to break an updater is to be careless here
before anyone is watching.

### The two numbers

| Key | Build setting | Who reads it |
|---|---|---|
| `CFBundleShortVersionString` | `MARKETING_VERSION` | Humans. Shown in About and in release notes |
| `CFBundleVersion` | `CURRENT_PROJECT_VERSION` | Sparkle. The actual update comparison |

**Sparkle compares `CFBundleVersion`, not the marketing version.** It must
increase monotonically across every release, forever. It never resets when
the marketing version changes.

### What to adopt

Move `MARKETING_VERSION` to real SemVer — `1.0.0`, not `1.0` — and bump it
deliberately per release. Keep `release.sh`'s existing UTC timestamp scheme
for `CURRENT_PROJECT_VERSION`; it is monotonic by construction, unique per
image, and needs no bookkeeping. The script already injects it at archive
time and verifies afterward that the archive honored it, which is the check
that matters.

Move both settings out of `project.pbxproj` and into an `.xcconfig` — the
project already uses that pattern for `Secrets.xcconfig`, so the mechanism
is familiar. Four targets each carrying their own copy of a version number
is four places to forget.

### The drift trap

The failure looks like this: a user runs 1.0.1, the appcast advertises
1.0.2, and Sparkle says "You're up to date."

It happens when the number in the appcast does not match the number actually
inside the shipped app. The appcast says `sparkle:version` 42; the DMG
contains a bundle whose `CFBundleVersion` is 41 because the archive did not
pick up the injection. Sparkle believes the bundle, not the feed.

The defense is mechanical, not vigilance: **generate the appcast entry from
the built artifact, never by hand.** Part 5 does this by reading the values
back out of the DMG. Never type a version into `appcast.xml`.

---

## Part 2 — Build settings for a notarizable app

### Enable Hardened Runtime

This is the blocker. Notarization will reject the submission without it.

```
ENABLE_HARDENED_RUNTIME = YES
```

Set it for the `Changeover` app target in Release (an `.xcconfig` is the
better home, per Part 1). Verify after your next archive:

```sh
codesign -d --verbose=2 dist/Changeover.app 2>&1 | grep -i flags
# expect: flags=0x10000(runtime)
```

### Entitlements

There are no `.entitlements` files in the project today, and for an
unsandboxed app that is often correct. Add them only if something breaks
under Hardened Runtime. The ones most likely to matter here:

- `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` —
  only if a dependency needs them. Do not add speculatively; each one
  weakens the runtime protections notarization is checking for.
- If Changeover shells out to helper binaries (the ripping and encoding
  pipeline suggests it might), those helpers must themselves be signed and
  hardened if they live inside the bundle. A bundled unsigned executable is
  a notarization rejection with a message that does not obviously say so.

### Signing the whole bundle

`release.sh` already runs `codesign --verify --deep --strict` after export.
Keep that. Signing is inside-out: nested frameworks, XPC services, and
helper tools are signed before the enclosing app. Xcode's export handles
this for framework dependencies, which is why Part 3 recommends adding
Sparkle through Xcode rather than by hand-copying the framework.

---

## Part 3 — Adding Sparkle

### Add the dependency

In Xcode: **File → Add Package Dependencies**, URL
`https://github.com/sparkle-project/Sparkle`, and pin to the current 2.x
release. Add the `Sparkle` library to the `Changeover` target.

Because the app is **not sandboxed**, you can skip the XPC installer
services Sparkle requires for sandboxed apps. That removes most of the
fiddly setup.

### Generate signing keys

Sparkle signs updates with an EdDSA key pair, separate from your Apple
Developer ID. The private key goes in your login keychain; the public key
ships inside the app.

The tools come with the package. After the first build, locate them:

```sh
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f 2>/dev/null | head -1
```

Run it once, ever:

```sh
/path/to/generate_keys
```

It prints a public key and stores the private key in your keychain. **Back
the private key up now**, before you ship anything. Losing it means no
existing installation can ever be updated again — every user has to
re-download manually. Export it with `generate_keys -x private-key.txt`,
store that file somewhere durable and offline, and delete it from the Mac.

### Info.plist keys

Add to `Changeover/Info.plist`:

| Key | Type | Value |
|---|---|---|
| `SUFeedURL` | String | `https://<your-host>/appcast.xml` |
| `SUPublicEDKey` | String | The public key `generate_keys` printed |
| `SUEnableAutomaticChecks` | Boolean | `YES` |
| `SUScheduledCheckInterval` | Number | `86400` (daily) |

`SUFeedURL` must be **HTTPS**. Sparkle refuses plain HTTP.

When you paste `SUPublicEDKey`, take the whole string including any trailing
`=` padding. A silently truncated key produces signature failures that look
like corrupt downloads.

### Wiring it up

Sparkle 2 exposes `SPUStandardUpdaterController`, which owns the updater's
lifecycle and can be created once and held for the life of the app. In a
SwiftUI app that means holding it on your app type or in `AppDelegate.swift`,
which already exists here.

Then add a "Check for Updates…" item to the menu that calls the controller's
`checkForUpdates(_:)`, with its enabled state bound to the updater's
`canCheckForUpdates` so it disables itself while a check is in flight.

### The menu bar app problem

`LSUIElement = YES` means Changeover has no Dock icon and is not a regular
activating app. Sparkle's update window can therefore appear **behind**
whatever the user is looking at, or not visibly at all.

Call `NSApp.activate(ignoringOtherApps: true)` before presenting an update
check that the user initiated, and consider doing the same when an automatic
check finds something. Test this specifically — it is the single most likely
thing to be wrong in a menu bar app's Sparkle integration, and it will not
show up in any automated check.

### Verify the framework survives signing

After your first archive with Sparkle included:

```sh
codesign --verify --deep --strict --verbose=2 dist/Changeover.app
spctl -a -t exec -vv dist/Changeover.app
```

Sparkle ships helper executables inside its framework (the updater app and,
on some configurations, XPC services). All of them must be signed and
hardened. This is the step most likely to surface a notarization problem
before you spend several minutes waiting for Apple to tell you the same
thing.

---

## Part 4 — Cutting a release

### One-time setup

1. **Developer ID Application certificate** in your login keychain for team
   `XV8BAAVZ6V`. Confirm:
   ```sh
   security find-identity -p codesigning -v | grep "Developer ID Application"
   ```
2. **Notary keychain profile** — run `./setup-notary.sh` and follow the
   prompts. It stores an app-specific password (generated at
   appleid.apple.com, not your Apple ID password) under a profile name
   `notarytool` looks up later.
3. **Sparkle EdDSA key**, from Part 3, backed up.

### The run

```sh
./release.sh                 # notarizes if a profile exists, else signs only
NOTARIZE=1 ./release.sh      # require notarization; fail if unavailable
```

Use `NOTARIZE=1` for anything you publish. The default `auto` mode silently
degrades to a signed-only image, which is fine for hand-copying to your own
Mac and **not** fine for a download page — a signed-but-unnotarized app
requires the user to run `xattr -cr` from a terminal, which defeats the
purpose of a drag-to-Applications DMG.

Notarization takes minutes, not seconds. `--wait` blocks until Apple
answers.

### Naming for publication

`release.sh` names the output `Changeover-<sha>.dmg`. That is right for
development — it ties an image to a commit — but a published download wants
a version in the name, because the URL appears in the appcast and in the
link you give people:

```
Changeover-1.0.2.dmg
```

Rename on publish, or extend the script to take a version. Whatever you
choose, **the appcast's enclosure URL must point at the exact file you
notarized and stapled.** Re-uploading a rebuilt image under a URL that is
already in the appcast is how you ship a broken update.

---

## Part 5 — Publishing the appcast

### Sign the DMG for Sparkle

This is separate from codesigning. Sparkle verifies its own EdDSA signature
over the downloaded file.

```sh
find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -1
/path/to/sign_update dist/Changeover-1.0.2.dmg
```

It prints an `sparkle:edSignature` value and a `length` in bytes. Both go
into the appcast entry.

### The appcast

`appcast.xml` is an RSS feed; each release is one `<item>`. A minimal entry:

```xml
<item>
  <title>1.0.2</title>
  <pubDate>Fri, 12 Sep 2026 10:00:00 -0700</pubDate>
  <sparkle:version>20260912100000</sparkle:version>
  <sparkle:shortVersionString>1.0.2</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>26.2</sparkle:minimumSystemVersion>
  <description><![CDATA[
    <ul><li>What changed in this release.</li></ul>
  ]]></description>
  <enclosure
    url="https://<your-host>/Changeover-1.0.2.dmg"
    sparkle:edSignature="<from sign_update>"
    length="<from sign_update>"
    type="application/octet-stream" />
</item>
```

`sparkle:version` is the `CFBundleVersion` from inside the built app, and
`sparkle:shortVersionString` is its `CFBundleShortVersionString`. Read them
back out of the artifact rather than typing them:

```sh
hdiutil attach dist/Changeover-1.0.2.dmg -nobrowse -mountpoint /tmp/co
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    /tmp/co/Changeover.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    /tmp/co/Changeover.app/Contents/Info.plist
hdiutil detach /tmp/co
```

This is the mechanical defense against the drift trap from Part 1. A small
script that emits the `<item>` block from a DMG path is worth writing once;
it removes the entire class of "you're up to date" bugs.

Keep old `<item>` entries in the feed. Sparkle picks the newest one it can
install, and a user several versions behind still needs to find a path
forward.

### Hosting

You need two things reachable over HTTPS:

- `appcast.xml` at the exact URL in `SUFeedURL`
- every DMG referenced by an enclosure, at a URL that never changes

Options, roughly in order of least ongoing cost:

- **GitHub Releases** — upload the DMG as a release asset, host
  `appcast.xml` on GitHub Pages. Free, durable URLs, no server.
- **S3 + CloudFront** — cheap, boring, scales. Watch cache TTLs on
  `appcast.xml`, or users will keep seeing a stale feed after you publish.
- **A web server you run** — most control, most maintenance. If you already
  have one for the download page, hosting two more files there is trivial.

Serve `appcast.xml` as `application/xml` and set a short cache lifetime on
it. The DMGs are immutable and can be cached indefinitely.

### The download page

The page a person actually visits needs very little: what the app is, a
button linking to the newest DMG, and the macOS version requirement (26.2).
Because the image is notarized and stapled, the instruction is genuinely
"open it and drag Changeover to Applications" — no terminal step, no
right-click-Open workaround.

---

## Part 6 — Verifying on a clean Mac

A notarized DMG that works on the machine that built it proves nothing —
your Mac already trusts your own certificate and has the app's ticket
cached. The checks that matter simulate a stranger's machine.

Run the project's own verification first:

```sh
./verify-dmg.sh dist/Changeover-1.0.2.dmg
```

Then confirm the quarantine path specifically, which is what a real download
gets and a local build does not:

```sh
xattr -w com.apple.quarantine \
    "0081;00000000;Safari;" dist/Changeover-1.0.2.dmg
spctl -a -t open --context context:primary-signature -vv \
    dist/Changeover-1.0.2.dmg
xcrun stapler validate dist/Changeover-1.0.2.dmg
```

`spctl` should report `accepted` and `source=Notarized Developer ID`.

Then do it for real at least once, before the first public release: copy the
DMG to a Mac that has never had Changeover on it — or a fresh VM — download
it through a browser rather than AirDrop, and install. Confirm it launches
with no warning and that the menu bar item appears.

**Also verify the update path end to end before the second release, not
during it.** Install the older version, publish the newer appcast entry,
and let Sparkle find it. The first real update is the one most likely to
reveal a wrong `SUFeedURL`, a truncated public key, or a version comparison
that does not do what you expect — and by then it is running on other
people's machines.

---

## Troubleshooting

**Notarization rejected.** Get the log; the summary line is rarely enough:

```sh
xcrun notarytool log <submission-id> --keychain-profile <profile>
```

Most common causes here: Hardened Runtime off (Part 2), a nested binary
signed with a different identity or not at all, or a missing secure
timestamp. `release.sh` passes `--timestamp` when it signs the DMG; make
sure anything you sign by hand does too.

**"You're up to date" while running an older version.** The appcast's
`sparkle:version` does not exceed the installed `CFBundleVersion`. Read both
and compare — the installed one from
`/Applications/Changeover.app/Contents/Info.plist`, the advertised one from
the live feed. Generating the appcast from the artifact prevents this.

**Sparkle reports a signature failure.** Either `SUPublicEDKey` in the
shipped app does not match the private key used by `sign_update`, or the
file on the server is not byte-identical to the one you signed. Re-running
`sign_update` against the uploaded file and comparing is the fastest way to
tell which.

**Update downloads but never installs.** On a menu bar app this is usually
the activation problem from Part 3 — the installer window exists but is
behind everything. Check with Mission Control before assuming a deeper bug.

**Gatekeeper warns on a notarized DMG.** Confirm the ticket is stapled
(`stapler validate`). Stapling is what lets a first launch succeed offline;
without it the check depends on the user's machine reaching Apple.

---

## Release checklist

- [ ] `MARKETING_VERSION` bumped and in SemVer form
- [ ] `ENABLE_HARDENED_RUNTIME = YES` for the app target
- [ ] `SUFeedURL` and `SUPublicEDKey` present and correct in `Info.plist`
- [ ] `NOTARIZE=1 ./release.sh` completed, stapled, and Gatekeeper-verified
- [ ] DMG renamed to carry the version
- [ ] `sign_update` run against the **final** DMG file
- [ ] Appcast `<item>` generated from the artifact, not typed
- [ ] DMG and `appcast.xml` uploaded; enclosure URL fetches the right bytes
- [ ] Installed from a browser download on a Mac that never had the app
- [ ] Sparkle private key backed up somewhere that survives losing this Mac
