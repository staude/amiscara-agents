#!/usr/bin/env bash
# Archives the iPhone/iPad app (with the Watch app) and the Apple TV app and
# uploads them to App Store Connect for TestFlight.
#
#   scripts/testflight.sh             iOS and tvOS
#   scripts/testflight.sh ios         only iOS (with the Watch app)
#   scripts/testflight.sh tvos        only tvOS
#
# Needs the app record in App Store Connect, the App Store profiles that
# scripts/ExportOptions-TestFlight-<platform>.plist names (Xcode > Settings
# > Accounts > Download Manual Profiles), the Apple Distribution certificate
# in the keychain (the archive is signed manually with
# scripts/Signing-AppStore.xcconfig) and either an Xcode account of
# team 7N2W4T6UPV on this Mac or an App Store Connect API key in the
# environment (see scripts/apple-common.sh). A build number goes up only
# once: run scripts/bump-build.sh and commit first, or set BUILD_NUMBER.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/apple-common.sh
source scripts/apple-common.sh

out="target/testflight"
case "${1:-all}" in
    all) platforms=(ios tvos) ;;
    ios | tvos) platforms=("$1") ;;
    *) die "unknown platform '$1' (ios, tvos or nothing for both)" ;;
esac

command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
require_identity "Apple Distribution"
require_clean_tree

version=$(marketing_version)
build=$(build_number)
step "Amiscara Agents $version ($build) for TestFlight, $(git rev-parse --short HEAD)"

rm -rf "$out"
mkdir -p "$out"

# Xcode checks the XCFramework for the platform while planning the build,
# so each slice has to exist before its archive starts.
step "Rust core and Xcode project"
for platform in "${platforms[@]}"; do
    case "$platform" in
        ios) scripts/build-ffi.sh release iphoneos ;;
        tvos) scripts/build-ffi.sh release appletvos ;;
    esac
done
(cd apps/AmiscaraAgents && xcodegen generate --quiet)

for platform in "${platforms[@]}"; do
    case "$platform" in
        ios) scheme="AmiscaraAgents-iOS" destination="generic/platform=iOS" ;;
        tvos) scheme="AmiscaraAgents-tvOS" destination="generic/platform=tvOS" ;;
    esac
    archive="$out/$scheme.xcarchive"

    step "Archive $scheme"
    xcodebuild -project apps/AmiscaraAgents/AmiscaraAgents.xcodeproj -scheme "$scheme" \
        -configuration Release -destination "$destination" \
        -derivedDataPath "$out/derived" -archivePath "$archive" \
        -xcconfig scripts/Signing-AppStore.xcconfig archive -quiet ${build_settings[@]+"${build_settings[@]}"}

    step "Upload $scheme"
    xcodebuild -exportArchive -archivePath "$archive" \
        -exportOptionsPlist "scripts/ExportOptions-TestFlight-$platform.plist" -exportPath "$out/export-$platform" \
        "${xcode_auth[@]}"
done

step "Done: $version ($build) uploaded, TestFlight processes it in a few minutes"
