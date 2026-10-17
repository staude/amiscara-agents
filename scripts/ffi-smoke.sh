#!/usr/bin/env bash
# Builds the Swift bindings into a small command line probe and runs it
# against a herdr server (read-only). Needs scripts/build-ffi.sh first.
#
# Usage: scripts/ffi-smoke.sh [socket-path]
set -euo pipefail

cd "$(dirname "$0")/.."

gen="apps/HerdrRemote/Generated"
lib="$gen/HerdrFFI.xcframework/macos-arm64"
out="target/ffi-smoke"
mkdir -p "$out"

swiftc -O -swift-version 6 \
    -I "$lib/Headers" -L "$lib" -lherdr_ffi \
    "$gen/herdr_ffi.swift" apps/HerdrRemote/Tests/FFISmoke/main.swift \
    -o "$out/ffi-smoke"

"$out/ffi-smoke" "$@"
