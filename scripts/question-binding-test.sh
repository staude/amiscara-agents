#!/usr/bin/env bash
# Builds the check that a notification's answer button only answers the
# question it was shown for (#286) into a small command line test and
# runs it. Needs no herdr server and no Rust build.
#
# Usage: scripts/question-binding-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/question-binding-test"
mkdir -p "$out"

model=apps/AmiscaraAgents/AmiscaraAgents/Model
swiftc -swift-version 6 \
    "$model/QuestionBinding.swift" \
    apps/AmiscaraAgents/Tests/QuestionBinding/main.swift \
    -o "$out/question-binding-test"

"$out/question-binding-test"
