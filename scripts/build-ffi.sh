#!/usr/bin/env bash
# Builds herdr-ffi for the apps: static libraries wrapped as
# HerdrFFI.xcframework plus the generated Swift bindings, both in
# apps/AmiscaraAgents/Generated (not checked in).
#
# Usage: scripts/build-ffi.sh [debug|release] [macosx|iphoneos|iphonesimulator|appletvos|appletvsimulator|all]
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
        appletvos) echo aarch64-apple-tvos ;;
        appletvsimulator) echo aarch64-apple-tvos-sim ;;
        *) echo "unknown platform: $1" >&2; exit 1 ;;
    esac
}

if [[ "$platform" == "all" ]]; then
    platforms=(macosx iphoneos iphonesimulator appletvos appletvsimulator)
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
    # iOS SDK or with a deployment target the host loader rejects. iOS and
    # tvOS slices get the app's deployment target, so the C parts (aws-lc)
    # match it. tvOS stays at 26: the Apple TV 4K (AppleTV6,2) gets no 27.
    ios_target=()
    case "$p" in
        iphoneos | iphonesimulator) ios_target=(IPHONEOS_DEPLOYMENT_TARGET=27.0) ;;
        appletvos | appletvsimulator) ios_target=(TVOS_DEPLOYMENT_TARGET=26.0) ;;
    esac
    # ${a[@]+"${a[@]}"}: empty arrays count as unset under `set -u` in the
    # bash 3.2 that Xcode build phases run.
    env -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET -u IPHONEOS_DEPLOYMENT_TARGET -u TVOS_DEPLOYMENT_TARGET \
        ${ios_target[@]+"${ios_target[@]}"} \
        cargo build -p herdr-ffi --target "$(triple_for "$p")" ${cargo_profile[@]+"${cargo_profile[@]}"}
done

work="target/ffi"
out="apps/AmiscaraAgents/Generated"
rm -rf "$work"
mkdir -p "$work/swift" "$work/headers" "$out"

# Bindings come from the slice just built; all slices share one API.
bindings_lib="target/$(triple_for "${platforms[0]}")/$profile/libherdr_ffi.a"
env -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET -u IPHONEOS_DEPLOYMENT_TARGET -u TVOS_DEPLOYMENT_TARGET \
    cargo run -q -p uniffi-bindgen -- generate \
    --library "$bindings_lib" \
    --language swift \
    --out-dir "$work/swift"

cp "$work/swift/herdr_ffiFFI.h" "$work/headers/"
cp "$work/swift/herdr_ffiFFI.modulemap" "$work/headers/module.modulemap"

libraries=()
stamp_input=()
for p in macosx iphoneos iphonesimulator appletvos appletvsimulator; do
    lib="target/$(triple_for "$p")/$profile/libherdr_ffi.a"
    if [[ -f "$lib" ]]; then
        libraries+=(-library "$lib" -headers "$work/headers")
        stamp_input+=("$lib")
    fi
done

# Leave the framework alone when nothing changed: Xcode may already be
# reading it for the app target.
stamp="$(shasum "${stamp_input[@]}" "$work/headers/herdr_ffiFFI.h" | shasum | cut -d' ' -f1)"
if [[ -d "$out/HerdrFFI.xcframework" && "$(cat "$out/.ffi-stamp" 2>/dev/null)" == "$stamp" ]] \
    && cmp -s "$work/swift/herdr_ffi.swift" "$out/herdr_ffi.swift"; then
    echo "herdr-ffi ($profile, ${platforms[*]}) unchanged"
    exit 0
fi

# Build next to the old framework and swap, so Xcode never finds the path
# missing, and only touch the Swift file when it changed (no needless
# recompiles).
xcodebuild -create-xcframework "${libraries[@]}" \
    -output "$work/HerdrFFI.xcframework" >/dev/null
rm -rf "$out/HerdrFFI.xcframework.old"
if [[ -d "$out/HerdrFFI.xcframework" ]]; then
    mv "$out/HerdrFFI.xcframework" "$out/HerdrFFI.xcframework.old"
fi
mv "$work/HerdrFFI.xcframework" "$out/HerdrFFI.xcframework"
rm -rf "$out/HerdrFFI.xcframework.old"
if ! cmp -s "$work/swift/herdr_ffi.swift" "$out/herdr_ffi.swift"; then
    cp "$work/swift/herdr_ffi.swift" "$out/"
fi
echo "$stamp" > "$out/.ffi-stamp"

echo "herdr-ffi ($profile, ${platforms[*]}) -> $out"
