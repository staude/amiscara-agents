#!/usr/bin/env bash
# Builds the rules for pull requests (#309) into a small command line test
# and runs it: which pull request belongs to a space, the merge method and
# the check states. Needs no network and no Rust build.
#
# Usage: scripts/pull-request-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/pull-request-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/PullRequestRules.swift \
    apps/AmiscaraAgents/Tests/PullRequests/main.swift \
    -o "$out/pull-request-test"

"$out/pull-request-test"
