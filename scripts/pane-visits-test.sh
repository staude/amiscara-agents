#!/usr/bin/env bash
# Builds the per-pane visit memory (#273) into a small command line test and
# runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/pane-visits-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/pane-visits-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/PaneVisits.swift \
    apps/AmiscaraAgents/Tests/PaneVisits/main.swift \
    -o "$out/pane-visits-test"

"$out/pane-visits-test"
