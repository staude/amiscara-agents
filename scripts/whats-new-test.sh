#!/usr/bin/env bash
# Builds the rules of "Neuigkeiten" (#341) into a small command line test
# and runs it in the repository root, where it reads apps/whats-new.json.
# Needs no herdr server and no Rust build.
#
# Usage: scripts/whats-new-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/whats-new-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/WhatsNew.swift \
    apps/AmiscaraAgents/Tests/WhatsNew/main.swift \
    -o "$out/whats-new-test"

"$out/whats-new-test"
