#!/usr/bin/env bash
# Builds herdr-ffi for the Mac app: a static library wrapped as
# HerdrFFI.xcframework plus the generated Swift bindings, both in
# apps/HerdrRemote/Generated (not checked in).
#
# Usage: scripts/build-ffi.sh [debug|release]   (default: release)
set -euo pipefail

cd "$(dirname "$0")/.."

profile="${1:-release}"
target="aarch64-apple-darwin"

# Xcode build phases run with a minimal PATH.
export PATH="$HOME/.cargo/bin:$PATH"

cargo_flags=(-p herdr-ffi --target "$target")
if [[ "$profile" == "release" ]]; then
    cargo_flags+=(--release)
fi
cargo build "${cargo_flags[@]}"

lib_dir="target/$target/$profile"
work="target/ffi"
out="apps/HerdrRemote/Generated"
rm -rf "$work"
mkdir -p "$work/swift" "$work/headers" "$out"

cargo run -q -p uniffi-bindgen -- generate \
    --library "$lib_dir/libherdr_ffi.dylib" \
    --language swift \
    --out-dir "$work/swift"

cp "$work/swift/herdr_ffiFFI.h" "$work/headers/"
cp "$work/swift/herdr_ffiFFI.modulemap" "$work/headers/module.modulemap"

rm -rf "$out/HerdrFFI.xcframework"
xcodebuild -create-xcframework \
    -library "$lib_dir/libherdr_ffi.a" \
    -headers "$work/headers" \
    -output "$out/HerdrFFI.xcframework" >/dev/null
cp "$work/swift/herdr_ffi.swift" "$out/"

echo "herdr-ffi ($profile) -> $out"
