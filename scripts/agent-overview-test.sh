#!/usr/bin/env bash
# Builds the overview of all hosts (#274) into a small command line test
# and runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/agent-overview-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/agent-overview-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/AgentOverview.swift \
    apps/AmiscaraAgents/Shared/WidgetSnapshot.swift \
    apps/AmiscaraAgents/Shared/CloudBoard.swift \
    apps/AmiscaraAgents/Tests/AgentOverview/main.swift \
    -o "$out/agent-overview-test"

"$out/agent-overview-test"
