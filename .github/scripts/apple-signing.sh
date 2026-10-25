#!/usr/bin/env bash
# Puts the App Store Connect API key and the certificate (.p12) for
# apple-release.yml in $RUNNER_TEMP/apple, the certificate in a temporary
# keychain that codesign finds. `--cleanup` removes both.
#
# Input from secrets: APPLE_API_KEY_P8 (base64), KEYCHAIN_PASSWORD, and
# P12 (base64) with P12_PASSWORD, and the provisioning profiles for manual
# signing: PROFILE (one, base64) or PROFILES (a .tar.gz of several,
# base64; GitHub caps a secret at 48 KB, seven plain profiles exceed it).
set -euo pipefail

dir="$RUNNER_TEMP/apple"
keychain="$dir/signing.keychain-db"
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

if [[ "${1:-}" == "--cleanup" ]]; then
    if [[ -f "$keychain" ]]; then
        security delete-keychain "$keychain" || true
    fi
    if [[ -f "$dir/profile-paths" ]]; then
        while IFS= read -r path; do rm -f "$path"; done <"$dir/profile-paths"
    fi
    rm -rf "${dir:?}"
    exit 0
fi

[[ -n "${APPLE_API_KEY_P8:-}" ]] || { echo "::error::secret APPLE_API_KEY_P8 missing (scripts/apple-ci-secrets.sh)"; exit 1; }
[[ -n "${KEYCHAIN_PASSWORD:-}" ]] || { echo "::error::secret KEYCHAIN_PASSWORD missing (scripts/apple-ci-secrets.sh)"; exit 1; }

mkdir -p "$dir"
chmod 700 "$dir"
printf '%s' "$APPLE_API_KEY_P8" | base64 --decode >"$dir/AuthKey.p8"

install_profile() {
    local uuid name
    uuid=$(security cms -D -i "$1" | plutil -extract UUID raw -)
    name=$(security cms -D -i "$1" | plutil -extract Name raw -)
    mkdir -p "$profiles"
    mv "$1" "$profiles/$uuid.provisionprofile"
    echo "$profiles/$uuid.provisionprofile" >>"$dir/profile-paths"
    echo "Provisioning profile \"$name\" ($uuid) installed."
}

if [[ -n "${PROFILE:-}" ]]; then
    printf '%s' "$PROFILE" | base64 --decode >"$dir/profile.provisionprofile"
    install_profile "$dir/profile.provisionprofile"
fi
if [[ -n "${PROFILES:-}" ]]; then
    mkdir "$dir/profiles"
    printf '%s' "$PROFILES" | base64 --decode | tar -xzf - -C "$dir/profiles"
    for profile in "$dir/profiles"/*; do
        install_profile "$profile"
    done
    rmdir "$dir/profiles"
fi

[[ -n "${P12:-}" ]] || { echo "::error::secret P12 missing (scripts/apple-ci-secrets.sh)"; exit 1; }

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
