#!/usr/bin/env bash
# Builds, signs (Developer ID), notarizes and staples the Mac app.
#
#   scripts/release.sh            build, notarize, verify; result in target/release-app
#   scripts/release.sh --install  also copy the app to /Applications
#
# One-time setup on a Mac (see docs/release.md):
#   - "Developer ID Application" certificate of team 7N2W4T6UPV in the login keychain
#   - notarytool profile:  xcrun notarytool store-credentials AmiscaraAgents \
#                            --apple-id <apple-id> --team-id 7N2W4T6UPV
#     (app-specific password from appleid.apple.com, not the account password)
#
# In CI an App Store Connect API key replaces both (APPLE_API_KEY_PATH,
# APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, see scripts/apple-common.sh); the
# certificate then comes from a temporary keychain or from cloud signing.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/apple-common.sh
source scripts/apple-common.sh

profile="${NOTARY_PROFILE:-AmiscaraAgents}"
out="target/release-app"
install=false
[[ "${1:-}" == "--install" ]] && install=true

if has_api_key; then
    notary_auth=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
else
    notary_auth=(--keychain-profile "$profile")
fi

# Preconditions first, so nothing is built that cannot be shipped.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($team)"; then
    # With an API key of the Admin role Xcode signs with a cloud-managed
    # Developer ID certificate instead.
    has_api_key || die "no 'Developer ID Application' certificate for team $team in the keychain"
    echo "release: no Developer ID certificate in the keychain, using cloud signing"
fi
xcrun notarytool history "${notary_auth[@]}" >/dev/null 2>&1 \
    || die "notarytool cannot sign in (profile '$profile' or API key missing or invalid)"
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
require_clean_tree

version=$(marketing_version)
build=$(build_number)
name="AmiscaraAgents-$version-$build"
step "Amiscara Agents $version ($build), $(git rev-parse --short HEAD)"

rm -rf "$out"
mkdir -p "$out"

step "Rust core and Xcode project"
scripts/build-ffi.sh release macosx
(cd apps/AmiscaraAgents && xcodegen generate --quiet)

step "Archive"
xcodebuild -project apps/AmiscaraAgents/AmiscaraAgents.xcodeproj -scheme AmiscaraAgents \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$out/derived" -archivePath "$out/AmiscaraAgents.xcarchive" \
    "${xcode_auth[@]}" archive -quiet ${build_settings[@]+"${build_settings[@]}"}

step "Export with Developer ID"
xcodebuild -exportArchive -archivePath "$out/AmiscaraAgents.xcarchive" \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$out/export" \
    "${xcode_auth[@]}" -quiet
app="$out/export/AmiscaraAgents.app"
codesign --verify --deep --strict --verbose=2 "$app"

step "Notarize"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" "${notary_auth[@]}" --wait
xcrun stapler staple "$app"

step "Verify"
codesign -dv --verbose=4 "$app" 2>&1 | grep -E "^(Authority|TeamIdentifier|Runtime)"
spctl -a -vvv -t exec "$app"
xcrun stapler validate "$app"

ditto -c -k --keepParent "$app" "$out/$name.zip"
step "Done: $out/$name.zip"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "zip=$out/$name.zip" >> "$GITHUB_OUTPUT"
fi

if $install; then
    step "Install to /Applications"
    rm -rf "/Applications/AmiscaraAgents.app"
    ditto "$app" "/Applications/AmiscaraAgents.app"
fi
