#!/bin/bash
#
# Build `changeover-menudump` into the app bundle.
#
# Run as a build phase of the Changeover target. Until this existed the helper
# was never shipped: `MenuHelper.locateDefault()` looks in `Contents/Helpers/`
# first and found nothing, so on any Mac but a developer's own checkout
# `JobController.startMenuRead` bailed at its first guard with
# `.unavailable(.helperMissing)` and the whole menu path — chapter names,
# audio track names, the upgrade offer — was dead code. Everything about that
# feature had only ever been exercised by running this binary by hand.
#
# The helper links nothing (libdvdread is dlopen'd at runtime from the user's
# own Homebrew, and tier 1 needs no library at all), so there is no framework
# to embed and nothing here can fail for want of a DVD toolchain.
set -euo pipefail

SRC_DIR="${SRCROOT}/Tools/menudump"
# TARGET_BUILD_DIR, not BUILT_PRODUCTS_DIR. They are the same directory for an
# ordinary build and different ones for an archive, which sets
# DEPLOYMENT_LOCATION and sends the app to InstallationBuildProductsLocation.
# The sandbox permits exactly the output path this phase declared, so the two
# have to name the same place or the archive is denied a write it was granted
# five seconds earlier in a Debug build.
HELPERS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
NAME="changeover-menudump"

# This phase needs ENABLE_USER_SCRIPT_SANDBOXING = NO, and the project sets
# it. Not a shortcut — the sandbox grants a script phase the exact output path
# it declared and very little else, which is not enough to produce a signed
# nested executable:
#
#   - `ld` into DERIVED_FILE_DIR: "Operation not permitted";
#   - `lipo` writing the universal binary: denied, because it creates through
#     a neighbouring temporary;
#   - `codesign` in place: "Write permissions error", for the same reason;
#   - `ditto` or `cp` onto the destination: denied for the extended
#     attributes they carry across.
#
# And signing here is not optional. Xcode signs the app bundle but not the
# executables nested inside it, and refuses to sign a bundle containing one
# that is unsigned: "code object is not signed at all / In subcomponent:
# Contents/Helpers/changeover-menudump".
mkdir -p "${HELPERS}"

# Build and sign in a scratch directory, then move the finished binary in, so
# a failed build never leaves a half-written helper inside the app.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/menudump.XXXXXX")"
trap 'rm -rf "${SCRATCH}"' EXIT

# Match the app: same deployment target and architectures, so a universal app
# does not ship a single-architecture helper that fails to launch on the other
# one. ARCHS is a space-separated list.
ARCH_FLAGS=()
for arch in ${ARCHS}; do ARCH_FLAGS+=(-arch "${arch}"); done

TARGET_FLAG=()
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  TARGET_FLAG=(-mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET}")
fi

cc -std=c11 -Wall -Wextra -O2 "${ARCH_FLAGS[@]}" "${TARGET_FLAG[@]}" \
   -o "${SCRATCH}/${NAME}" "${SRC_DIR}/menudump.c"

# EXPANDED_CODE_SIGN_IDENTITY is empty for an unsigned build
# (CODE_SIGNING_ALLOWED=NO), and then there is nothing to sign.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  SIGN_FLAGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}")
  # The helper must carry the same hardened runtime and secure timestamp the
  # app does, or notarization rejects the bundle for containing a nested
  # binary that does not — and with the hardened runtime it needs the
  # library-validation exception too, or its dlopen of the user's Homebrew
  # libdvdread is blocked and reported as the library being missing. See
  # menudump.entitlements.
  if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
    SIGN_FLAGS+=(--options runtime --timestamp
                 --entitlements "${SRC_DIR}/menudump.entitlements")
  fi
  codesign "${SIGN_FLAGS[@]}" "${SCRATCH}/${NAME}"
fi

ditto "${SCRATCH}/${NAME}" "${HELPERS}/${NAME}"

echo "embedded ${NAME} in ${CONTENTS_FOLDER_PATH}/Helpers"
