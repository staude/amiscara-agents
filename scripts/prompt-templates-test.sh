#!/usr/bin/env bash
# Builds the prompt templates (#298) into a small command line test and
# runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/prompt-templates-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/prompt-templates-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/PromptTemplates.swift \
    apps/AmiscaraAgents/Tests/PromptTemplates/main.swift \
    -o "$out/prompt-templates-test"

"$out/prompt-templates-test"
