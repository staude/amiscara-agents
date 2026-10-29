#!/usr/bin/env bash
# Builds the NetBird host rules (#305) into a small command line test and
# runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/netbird-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/netbird-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/NetBird.swift \
    apps/AmiscaraAgents/Tests/NetBird/main.swift \
    -o "$out/netbird-test"

"$out/netbird-test"
