#!/usr/bin/env bash
# Puts the App Store Connect API key and an optional certificate (.p12)
# for apple-release.yml in $RUNNER_TEMP/apple, the certificate in a
# temporary keychain that codesign finds. `--cleanup` removes both.
#
# Input from secrets: APPLE_API_KEY_P8 (base64), KEYCHAIN_PASSWORD, and
# optionally P12 (base64) with P12_PASSWORD.
set -euo pipefail

dir="$RUNNER_TEMP/apple"
keychain="$dir/signing.keychain-db"

if [[ "${1:-}" == "--cleanup" ]]; then
    if [[ -f "$keychain" ]]; then
        security delete-keychain "$keychain" || true
    fi
    rm -rf "${dir:?}"
    exit 0
fi

[[ -n "${APPLE_API_KEY_P8:-}" ]] || { echo "::error::secret APPLE_API_KEY_P8 missing (scripts/apple-ci-secrets.sh)"; exit 1; }
[[ -n "${KEYCHAIN_PASSWORD:-}" ]] || { echo "::error::secret KEYCHAIN_PASSWORD missing (scripts/apple-ci-secrets.sh)"; exit 1; }

mkdir -p "$dir"
chmod 700 "$dir"
printf '%s' "$APPLE_API_KEY_P8" | base64 --decode >"$dir/AuthKey.p8"

if [[ -z "${P12:-}" ]]; then
    echo "No certificate in the secrets: Xcode signs with a cloud-managed one (API key with the Admin role)."
    exit 0
fi

printf '%s' "$P12" | base64 --decode >"$dir/cert.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security import "$dir/cert.p12" -k "$keychain" -P "${P12_PASSWORD:-}" -A -t cert -f pkcs12
rm "$dir/cert.p12"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$keychain" >/dev/null
# Keep the login keychain in the list, Xcode stores downloaded profiles' keys there.
# shellcheck disable=SC2046
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$keychain"
