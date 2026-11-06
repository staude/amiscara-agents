#!/usr/bin/env bash
# Builds the put away tabs (#333) into a small command line test and runs
# it. Needs no herdr server, no iCloud and no Rust build.
#
# Usage: scripts/settled-tabs-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/settled-tabs-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/SettledTabs.swift \
    apps/AmiscaraAgents/Tests/SettledTabs/main.swift \
    -o "$out/settled-tabs-test"

"$out/settled-tabs-test"
