#!/usr/bin/env bash
# Builds how sub-agents nest under their parent (#330) into a small command
# line test and runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/sub-agents-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/sub-agents-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/SubAgentTree.swift \
    apps/AmiscaraAgents/Tests/SubAgents/main.swift \
    -o "$out/sub-agents-test"

"$out/sub-agents-test"
