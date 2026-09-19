#!/bin/bash
#
# Build `changeover-menudump` and put it inside the app bundle, signed.
#
# Run as a build phase of the Changeover target. Until this existed the helper
# was never shipped: `MenuHelper.locateDefault()` looked in
# `Contents/Helpers/` first and found nothing, so on any Mac but a developer's
# own checkout `JobController.startMenuRead` bailed at its first guard with
# `.unavailable(.helperMissing)` and the whole menu path — chapter names,
# audio track names, the upgrade offer — was dead code. Everything about that
# feature was demonstrated by running this binary by hand over ssh.
#
# The helper links nothing (libdvdread is dlopen'd at runtime from the user's
# own Homebrew, and tier 1 needs no library at all), so there is no framework
# to embed and nothing here can fail for want of a DVD toolchain.
set -euo pipefail

SRC_DIR="${SRCROOT}/Tools/menudump"
HELPERS="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
NAME="changeover-menudump"

# Build and sign in a scratch directory, then move the finished binary into
# place. Three constraints pick this shape, and each one was met the hard way:
#
#   - not the source tree, or every build dirties the working copy;
#   - not DERIVED_FILE_DIR, because with user script sandboxing on (the
#     default) this phase may write only the output paths it declares, and
#     `ld` fails there with a bare "Operation not permitted";
#   - not in place at the destination either, because `codesign` rewrites the
#     file through a neighbouring temporary and the sandbox allows the
#     declared output itself, not siblings of it — "Write permissions error".
#
# TMPDIR is per-build and writable under the sandbox, so both tools get a
# directory they can work in and only the finished file crosses into the app.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/menudump.XXXXXX")"
trap 'rm -rf "${SCRATCH}"' EXIT
mkdir -p "${HELPERS}"

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

# Sign it ourselves. Xcode signs the app bundle, not the executables nested
# inside it, and an unsigned nested binary under the hardened runtime is
# refused at launch — which would look exactly like the helper being missing
# again. EXPANDED_CODE_SIGN_IDENTITY is empty for an unsigned build
# (CODE_SIGNING_ALLOWED=NO), and then there is nothing to do.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  SIGN_FLAGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}")
  # The helper must carry the same hardened runtime and secure timestamp the
  # app does, or notarization rejects the bundle for containing a nested
  # binary that does not.
  if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
  fi
  codesign "${SIGN_FLAGS[@]}" "${SCRATCH}/${NAME}"
fi

# A plain byte copy, not `ditto` or `cp`. Both of those also carry extended
# attributes and ACLs across, and setting those on the destination is refused
# by the script sandbox ("Operation not permitted") even though writing the
# declared output itself is allowed. The code signature lives inside the
# binary, so copying its bytes preserves it exactly.
cat "${SCRATCH}/${NAME}" > "${HELPERS}/${NAME}"
chmod 755 "${HELPERS}/${NAME}"

echo "embedded ${NAME} in ${CONTENTS_FOLDER_PATH}/Helpers"
