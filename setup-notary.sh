#!/usr/bin/env zsh
# One-time setup of the notarytool keychain profile that release.sh uses to
# notarize the DMG. Adapted from ../Batty/scripts/setup-keys.sh.
#
# You need an App Store Connect API key (.p8) plus its Key ID and Issuer ID:
#   App Store Connect > Users and Access > Integrations > App Store Connect API
#   > Team Keys > +  (role: Developer). The .p8 downloads ONCE — keep it safe.
#
# Usage:
#   ./setup-notary.sh --key ~/.appstoreconnect/AuthKey_XXXX.p8 \
#                     --key-id XXXX --issuer <ISSUER_UUID> [--profile Changeover-notary]
#
# After this, ./release.sh auto-detects the profile and notarizes.

set -euo pipefail

PROFILE="Changeover-notary"
KEY=""
KEY_ID=""
ISSUER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --key)     KEY="$2";     shift 2 ;;
        --key-id)  KEY_ID="$2";  shift 2 ;;
        --issuer)  ISSUER="$2";  shift 2 ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0 ;;
        *) print -u2 "unknown argument: $1"; exit 2 ;;
    esac
done

if [[ -z "$KEY" || -z "$KEY_ID" || -z "$ISSUER" ]]; then
    print -u2 "error: --key, --key-id and --issuer are all required."
    print -u2 "       Run ./setup-notary.sh --help for details."
    exit 2
fi

if [[ ! -f "$KEY" ]]; then
    print -u2 "error: key file not found: $KEY"
    exit 1
fi

print "==> Storing notarytool credentials as profile '$PROFILE'"
xcrun notarytool store-credentials "$PROFILE" \
    --key "$KEY" \
    --key-id "$KEY_ID" \
    --issuer "$ISSUER"

print "==> Verifying the profile can reach Apple"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null

print "Done. ./release.sh will now notarize using profile '$PROFILE'."
