#!/usr/bin/env bash
# Builds which agents one prompt to several can go to (#299) and the quick
# selections into a small command line test and runs it. Needs no herdr
# server and no Rust build.
#
# Usage: scripts/multi-send-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/multi-send-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/MultiSend.swift \
    apps/AmiscaraAgents/Shared/WidgetSnapshot.swift \
    apps/AmiscaraAgents/Tests/MultiSend/main.swift \
    -o "$out/multi-send-test"

"$out/multi-send-test"
