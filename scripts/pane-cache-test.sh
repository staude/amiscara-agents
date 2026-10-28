#!/usr/bin/env bash
# Builds the files of the last pane screens (#276) into a small command line
# test and runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/pane-cache-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/pane-cache-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/PaneCacheFiles.swift \
    apps/AmiscaraAgents/Tests/PaneCache/main.swift \
    -o "$out/pane-cache-test"

"$out/pane-cache-test"
