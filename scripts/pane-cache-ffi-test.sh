#!/usr/bin/env bash
# Builds the memory side of the last pane screens (#276) with the Swift
# bindings into a small command line test and runs it. Needs
# scripts/build-ffi.sh first (scripts/check.sh --apple builds it), no herdr
# server.
#
# Usage: scripts/pane-cache-ffi-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

gen="apps/AmiscaraAgents/Generated"
lib="$gen/HerdrFFI.xcframework/macos-arm64"
model="apps/AmiscaraAgents/AmiscaraAgents/Model"
out="target/pane-cache-ffi-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    -I "$lib/Headers" -L "$lib" -lherdr_ffi \
    "$gen/herdr_ffi.swift" "$model/PaneCacheFiles.swift" "$model/PaneCache.swift" \
    apps/AmiscaraAgents/Tests/PaneCacheFFI/main.swift \
    -o "$out/pane-cache-ffi-test"

"$out/pane-cache-ffi-test"
