#!/usr/bin/env bash
# Builds the chain log (#300) into a small command line test and
# runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/chain-log-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/chain-log-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/ChainLog.swift \
    apps/AmiscaraAgents/Tests/ChainLog/main.swift \
    -o "$out/chain-log-test"

"$out/chain-log-test"
