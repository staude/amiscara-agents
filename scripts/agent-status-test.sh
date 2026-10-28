#!/usr/bin/env bash
# Builds the answer of "Was macht der Agent?" (#275) into a small command
# line test and runs it: screen lines, state clock, texts. Needs no herdr
# server and no Rust build.
#
# Usage: scripts/agent-status-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/agent-status-test"
mkdir -p "$out"

model=apps/AmiscaraAgents/AmiscaraAgents/Model
swiftc -swift-version 6 \
    apps/AmiscaraAgents/Shared/WidgetSnapshot.swift \
    "$model/ScreenLines.swift" \
    "$model/StateClock.swift" \
    "$model/AgentStatusText.swift" \
    apps/AmiscaraAgents/Tests/AgentStatus/main.swift \
    -o "$out/agent-status-test"

"$out/agent-status-test"
