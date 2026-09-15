#!/usr/bin/env zsh
# Build, sign, (optionally notarize,) and package Changeover.app into a DMG you
# copy to another Mac to install.
#
# Produces dist/Changeover-<sha>.dmg with a drag-to-Applications layout, signed
# with Developer ID. If a notarytool credential is configured it also notarizes
# + staples (Gatekeeper-clean, no xattr needed); otherwise it ships a signed-only
# DMG that runs after one `xattr -cr` on the target Mac.
#
# Adapted from ../Batty/scripts/release.sh. No Sparkle / appcast / website:
# this app is hand-copied to another Mac, not auto-updated.
#
# Usage:
#   ./release.sh                 # auto: notarize if a profile exists, else sign-only
#   NOTARIZE=0 ./release.sh      # force signed-only (skip notarization)
#   NOTARIZE=1 ./release.sh      # require notarization (error if no profile)
#   BUILD_NUMBER=123 ./release.sh
#   NOTARY_PROFILE=Batty-notary ./release.sh   # reuse an existing notary profile

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="$SCRIPT_DIR"
PROJECT="$REPO_ROOT/Changeover.xcodeproj"
SCHEME="Changeover"
APP_NAME="Changeover"
BUILD_DIR="$REPO_ROOT/build/release"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/Export"
EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"

TEAM_ID="XV8BAAVZ6V"
SIGN_IDENTITY="Developer ID Application: Brennan Stehling ($TEAM_ID)"
# Notary credentials are account-level, not app-specific: an existing profile
# from another app under the same Apple ID works. Override with NOTARY_PROFILE.
NOTARY_PROFILE="${NOTARY_PROFILE:-Changeover-notary}"

# auto (default) = notarize only if the profile is configured; 1 = require it;
# 0 = skip and ship a signed-only DMG (unquarantine on the target with xattr).
NOTARIZE="${NOTARIZE:-auto}"

# Unique build number per image (UTC, to the second) so CFBundleVersion never
# collides across two DMGs built the same day. Override with BUILD_NUMBER=...
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"

# --- Preflight ---------------------------------------------------------------

if [[ ! -d "$PROJECT" ]]; then
    print -u2 "error: $PROJECT not found"
    exit 1
fi

if ! security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
    print -u2 "error: signing identity not found in Keychain:"
    print -u2 "       $SIGN_IDENTITY"
    print -u2 "       Add via Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    exit 1
fi

# Decide whether this run notarizes. A profile is "available" if notarytool can
# reach Apple with it. NOTARIZE=0 skips outright; =1 demands it; auto degrades
# to signed-only when no profile is configured.
WILL_NOTARIZE=0
if [[ "$NOTARIZE" != "0" ]]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        WILL_NOTARIZE=1
    elif [[ "$NOTARIZE" == "1" ]]; then
        print -u2 "error: notarytool keychain profile '$NOTARY_PROFILE' missing or invalid."
        print -u2 "       Reuse a profile from another app with: NOTARY_PROFILE=<name> ./release.sh"
        print -u2 "       Create one with: ./setup-notary.sh (see its --help)"
        print -u2 "       Or build a signed-only DMG now with: NOTARIZE=0 ./release.sh"
        exit 1
    else
        print "note: notary profile '$NOTARY_PROFILE' not configured — building a"
        print "      signed-only DMG (run xattr -cr on the target Mac). Set up"
        print "      notarization later with ./setup-notary.sh for a cleaner install."
    fi
fi

# --- Build & export ----------------------------------------------------------

print "==> Cleaning previous release build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

print "==> Build number for this release: $BUILD_NUMBER"

print "==> Writing export options plist"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

print "==> Archiving Release (CURRENT_PROJECT_VERSION=$BUILD_NUMBER)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

print "==> Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "error: exported app not found at $APP_PATH"
    exit 1
fi

print "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Confirm the archive honored the injected build number before packaging.
# If CURRENT_PROJECT_VERSION didn't take, every DMG would carry the same
# CFBundleVersion and you'd have no way to tell two images apart.
ACTUAL_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [[ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
    print -u2 "error: built CFBundleVersion ($ACTUAL_BUILD) != injected build number ($BUILD_NUMBER)"
    print -u2 "       The archive did not honor CURRENT_PROJECT_VERSION=$BUILD_NUMBER."
    exit 1
fi
print "==> Version: $ACTUAL_SHORT (build $ACTUAL_BUILD)"

# AppIcon.icns (generated from Assets.xcassets/AppIcon.appiconset during the
# build) is used later to set the DMG *file's* Finder icon. Optional.
APP_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"

# --- DMG ---------------------------------------------------------------------

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || print unknown)"

# Build/sign/notarize/staple against a fixed-name DMG that matches the volume
# name, then rename to the sha-tagged name once stapling completes. When the
# DMG filename and volume name differ, macOS can silently rename the file during
# the notarytool roundtrip, breaking the next step.
WORK_DMG="$DIST_DIR/$APP_NAME.dmg"
DMG_PATH="$DIST_DIR/$APP_NAME-$GIT_SHA.dmg"

# Stage the app next to an /Applications symlink so the mounted DMG shows a
# drag target. hdiutil (built in — no Homebrew dependency) packs the folder
# into a compressed read-only image. No custom window layout or icon
# positioning; that cosmetic polish is the only thing create-dmg would add.
print "==> Creating DMG: $WORK_DMG"
rm -f "$WORK_DMG" "$DMG_PATH"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$WORK_DMG"

rm -rf "$STAGING"

print "==> Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$WORK_DMG"

# --- Notarize (optional) -----------------------------------------------------

if [[ "$WILL_NOTARIZE" == "1" ]]; then
    print "==> Submitting for notarization (this can take several minutes)"
    xcrun notarytool submit "$WORK_DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    print "==> Stapling notarization ticket"
    xcrun stapler staple "$WORK_DMG"
    xcrun stapler validate "$WORK_DMG"

    print "==> Verifying Gatekeeper acceptance"
    spctl -a -t open --context context:primary-signature -vv "$WORK_DMG"
else
    print "==> Skipping notarization (signed-only DMG)"
fi

print "==> Tagging final artifact with git sha"
mv "$WORK_DMG" "$DMG_PATH"

# Optionally set the DMG file's Finder icon to the app icon. fileicon writes
# only to extended attributes, leaving the data fork (and thus the codesign +
# stapled ticket) intact. Skipped silently if fileicon isn't installed.
if [[ -f "$APP_ICON" ]] && command -v fileicon >/dev/null 2>&1; then
    print "==> Setting DMG file icon"
    fileicon set "$DMG_PATH" "$APP_ICON"
fi

# --- Cleanup -----------------------------------------------------------------

# Remove the exported Release .app so LaunchServices doesn't index it next to
# the Debug build Xcode runs from DerivedData (both share co.sstools.Changeover).
# The DMG in dist/ is the canonical distributable. Leaves the dev build/ dir
# used by build.sh untouched.
print "==> Cleaning up release build artifacts ($BUILD_DIR)"
rm -rf "$BUILD_DIR"

print
print "Done. Distributable at:"
print "  $DMG_PATH"
print "  Build number: $BUILD_NUMBER"
print
print "On your other Mac mini:"
print "  - Copy the DMG over, double-click it"
print "  - Drag $APP_NAME.app onto the Applications shortcut"
if [[ "$WILL_NOTARIZE" == "1" ]]; then
    print "  - Launch from Applications — no Gatekeeper warning, no xattr needed"
else
    print "  - First launch is signed but NOT notarized, so clear the quarantine:"
    print "        xattr -cr /Applications/$APP_NAME.app"
    print "    then open it from Applications (or right-click > Open the first time)."
fi
