#!/usr/bin/env bash
# Builds the token sums of the dashboard and the 30-day page (#302) with the
# Swift bindings into a small command line test and runs it. Needs
# scripts/build-ffi.sh first (scripts/check.sh --apple builds it), no herdr
# server.
#
# Usage: scripts/usage-sums-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

gen="apps/AmiscaraAgents/Generated"
lib="$gen/HerdrFFI.xcframework/macos-arm64"
model="apps/AmiscaraAgents/AmiscaraAgents/Model"
out="target/usage-sums-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    -I "$lib/Headers" -L "$lib" -lherdr_ffi \
    "$gen/herdr_ffi.swift" "$model/UsageSums.swift" "$model/UsagePrices.swift" \
    apps/AmiscaraAgents/Shared/WidgetSnapshot.swift \
    apps/AmiscaraAgents/Tests/UsageSums/main.swift \
    -o "$out/usage-sums-test"

"$out/usage-sums-test"
