#!/usr/bin/env bash
# Builds the answer of "Was macht der Agent?" (#275) into a small command
# line test and runs it: screen lines and texts. Needs no herdr server
# and no Rust build.
#
# Usage: scripts/agent-status-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/agent-status-test"
mkdir -p "$out"

model=apps/AmiscaraAgents/AmiscaraAgents/Model
swiftc -swift-version 6 \
    "$model/ScreenLines.swift" \
    "$model/AgentStatusText.swift" \
    apps/AmiscaraAgents/Tests/AgentStatus/main.swift \
    -o "$out/agent-status-test"

"$out/agent-status-test"
