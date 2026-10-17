#!/usr/bin/env bash
# Builds, signs (Developer ID), notarizes and staples the Mac app.
#
#   scripts/release.sh            build, notarize, verify; result in target/release-app
#   scripts/release.sh --install  also copy the app to /Applications
#
# One-time setup (see docs/release.md):
#   - "Developer ID Application" certificate of team 7N2W4T6UPV in the login keychain
#   - notarytool profile:  xcrun notarytool store-credentials HerdrRemote \
#                            --apple-id <apple-id> --team-id 7N2W4T6UPV
#     (app-specific password from appleid.apple.com, not the account password)
set -euo pipefail

cd "$(dirname "$0")/.."

team="7N2W4T6UPV"
profile="${NOTARY_PROFILE:-HerdrRemote}"
spec="apps/HerdrRemote/project.yml"
out="target/release-app"
install=false
[[ "${1:-}" == "--install" ]] && install=true

die() { echo "release: $*" >&2; exit 1; }
step() { echo "==> $*"; }

# Preconditions first, so nothing is built that cannot be shipped.
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($team)" \
    || die "no 'Developer ID Application' certificate for team $team in the keychain"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || die "notarytool profile '$profile' missing or invalid (xcrun notarytool store-credentials $profile ...)"
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
if [[ -n "$(git status --porcelain)" ]]; then
    die "working tree not clean; commit first so the build matches a revision"
fi

version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' "$spec")
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' "$spec")
name="HerdrRemote-$version-$build"
step "Herdr Remote $version ($build), $(git rev-parse --short HEAD)"

rm -rf "$out"
mkdir -p "$out"

step "Rust core and Xcode project"
scripts/build-ffi.sh release
(cd apps/HerdrRemote && xcodegen generate --quiet)

step "Archive"
xcodebuild -project apps/HerdrRemote/HerdrRemote.xcodeproj -scheme HerdrRemote \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$out/derived" -archivePath "$out/HerdrRemote.xcarchive" \
    -allowProvisioningUpdates archive -quiet

step "Export with Developer ID"
xcodebuild -exportArchive -archivePath "$out/HerdrRemote.xcarchive" \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$out/export" \
    -allowProvisioningUpdates -quiet
app="$out/export/HerdrRemote.app"
codesign --verify --deep --strict --verbose=2 "$app"

step "Notarize"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"

step "Verify"
codesign -dv --verbose=4 "$app" 2>&1 | grep -E "^(Authority|TeamIdentifier|Runtime)"
spctl -a -vvv -t exec "$app"
xcrun stapler validate "$app"

ditto -c -k --keepParent "$app" "$out/$name.zip"
step "Done: $out/$name.zip"

if $install; then
    step "Install to /Applications"
    rm -rf "/Applications/HerdrRemote.app"
    ditto "$app" "/Applications/HerdrRemote.app"
fi
