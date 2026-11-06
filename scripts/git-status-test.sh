#!/usr/bin/env bash
# Builds the rules for the Git status of worktree spaces (#343) into a small
# command line test and runs it: when the status is read again, how often,
# the text of a row and the search of "Worktree öffnen". Needs no host and
# no Rust build.
#
# Usage: scripts/git-status-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/git-status-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/GitStatusRules.swift \
    apps/AmiscaraAgents/Tests/GitStatus/main.swift \
    -o "$out/git-status-test"

"$out/git-status-test"
