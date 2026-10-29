#!/usr/bin/env bash
# Builds the text for reading aloud (#297) into a small command line test
# and runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/spoken-text-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/spoken-text-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/SpokenText.swift \
    apps/AmiscaraAgents/Tests/SpokenText/main.swift \
    -o "$out/spoken-text-test"

"$out/spoken-text-test"
