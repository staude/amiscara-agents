#!/usr/bin/env bash
# Builds the per-space tab memory (#263) into a small command line test and
# runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/last-tabs-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/last-tabs-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/LastTabs.swift \
    apps/AmiscaraAgents/Tests/LastTabs/main.swift \
    -o "$out/last-tabs-test"

"$out/last-tabs-test"
