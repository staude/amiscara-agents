#!/usr/bin/env bash
# Builds herdr-ffi for the apps: static libraries wrapped as
# HerdrFFI.xcframework plus the generated Swift bindings, both in
# apps/HerdrRemote/Generated (not checked in).
#
# Usage: scripts/build-ffi.sh [debug|release] [macosx|iphoneos|iphonesimulator|all]
#
# Profile defaults to release. Platform defaults to $PLATFORM_NAME (set by
# Xcode build phases) or macosx. Only the requested slice is built; slices
# built earlier with the same profile are kept in the framework, so the Mac
# and iOS targets can share it.
set -euo pipefail

cd "$(dirname "$0")/.."

profile="${1:-release}"
platform="${2:-${PLATFORM_NAME:-macosx}}"

# Xcode build phases run with a minimal PATH.
export PATH="$HOME/.cargo/bin:$PATH"

triple_for() {
    case "$1" in
        macosx) echo aarch64-apple-darwin ;;
        iphoneos) echo aarch64-apple-ios ;;
        iphonesimulator) echo aarch64-apple-ios-sim ;;
        *) echo "unknown platform: $1" >&2; exit 1 ;;
    esac
}

if [[ "$platform" == "all" ]]; then
    platforms=(macosx iphoneos iphonesimulator)
else
    platforms=("$platform")
fi

cargo_profile=()
if [[ "$profile" == "release" ]]; then
    cargo_profile=(--release)
fi

for p in "${platforms[@]}"; do
    # Xcode exports SDKROOT and deployment targets for its own platform. They
    # must not leak into cargo: host proc-macros would be built against the
    # iOS SDK or with a deployment target the host loader rejects. iOS slices
    # get the app's deployment target, so the C parts (aws-lc) match it.
    ios_target=()
    if [[ "$p" != "macosx" ]]; then
        ios_target=(IPHONEOS_DEPLOYMENT_TARGET=27.0)
    fi
    env -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET -u IPHONEOS_DEPLOYMENT_TARGET "${ios_target[@]}" \
        cargo build -p herdr-ffi --target "$(triple_for "$p")" "${cargo_profile[@]}"
done

work="target/ffi"
out="apps/HerdrRemote/Generated"
rm -rf "$work"
mkdir -p "$work/swift" "$work/headers" "$out"

# Bindings come from the slice just built; all slices share one API.
bindings_lib="target/$(triple_for "${platforms[0]}")/$profile/libherdr_ffi.a"
env -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET -u IPHONEOS_DEPLOYMENT_TARGET \
    cargo run -q -p uniffi-bindgen -- generate \
    --library "$bindings_lib" \
    --language swift \
    --out-dir "$work/swift"

cp "$work/swift/herdr_ffiFFI.h" "$work/headers/"
cp "$work/swift/herdr_ffiFFI.modulemap" "$work/headers/module.modulemap"

libraries=()
for p in macosx iphoneos iphonesimulator; do
    lib="target/$(triple_for "$p")/$profile/libherdr_ffi.a"
    if [[ -f "$lib" ]]; then
        libraries+=(-library "$lib" -headers "$work/headers")
    fi
done

rm -rf "$out/HerdrFFI.xcframework"
xcodebuild -create-xcframework "${libraries[@]}" \
    -output "$out/HerdrFFI.xcframework" >/dev/null
cp "$work/swift/herdr_ffi.swift" "$out/"

echo "herdr-ffi ($profile, ${platforms[*]}) -> $out"
