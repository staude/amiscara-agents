#!/usr/bin/env bash
# Builds herdr-ffi for the Android app: one libherdr_ffi.so per ABI plus the
# generated Kotlin bindings (not checked in). The Gradle task buildRustCore
# runs this before compiling (apps/android/app/build.gradle.kts).
#
# Usage: scripts/build-android-ffi.sh <jni-libs-dir> <kotlin-dir> [debug|release]
#
# Writes <jni-libs-dir>/<abi>/libherdr_ffi.so and the bindings. ABIs
# come from $ANDROID_ABIS (default "arm64-v8a x86_64": the phone and the
# emulator). Needs cargo-ndk and an NDK: $ANDROID_NDK_HOME, else the newest
# one under $ANDROID_HOME/ndk. NDK r28 and later link with 16 KB pages, as
# Google Play requires.
set -euo pipefail

cd "$(dirname "$0")/.."

usage="usage: scripts/build-android-ffi.sh <jni-libs-dir> <kotlin-dir> [debug|release]"
jni_libs="${1:?$usage}"
kotlin="${2:?$usage}"
profile="${3:-release}"
abis="${ANDROID_ABIS:-arm64-v8a x86_64}"
min_sdk=29

# Gradle starts this with its own environment.
export PATH="$HOME/.cargo/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)"
    export ANDROID_NDK_HOME
fi
[[ -d "$ANDROID_NDK_HOME" ]] || { echo "build-android-ffi: no NDK found, set ANDROID_NDK_HOME" >&2; exit 1; }
command -v cargo-ndk >/dev/null || { echo "build-android-ffi: cargo install cargo-ndk" >&2; exit 1; }

cargo_profile=()
if [[ "$profile" == "release" ]]; then
    cargo_profile=(--release)
fi
targets=()
for abi in $abis; do
    targets+=(-t "$abi")
done

cargo ndk "${targets[@]}" -P "$min_sdk" -o "$jni_libs" \
    build -p herdr-ffi ${cargo_profile[@]+"${cargo_profile[@]}"}

# Bindings come from the first ABI; all share one API. Into a scratch
# directory first, so an unchanged file keeps its timestamp and Gradle
# compiles nothing.
lib="$jni_libs/$(set -- $abis; echo "$1")/libherdr_ffi.so"
work="$kotlin.tmp"
rm -rf "$work"
cargo run -q -p uniffi-bindgen -- generate --library "$lib" --language kotlin --no-format --out-dir "$work"
mkdir -p "$kotlin"
rsync -a --checksum --delete "$work/" "$kotlin/"
rm -rf "$work"

echo "herdr-ffi ($profile, $abis) -> $jni_libs, $kotlin"
