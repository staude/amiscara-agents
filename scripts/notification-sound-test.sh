#!/usr/bin/env bash
# Builds the check of how the notification sound per state is stored and
# read (#336) into a small command line test and runs it. Needs no herdr
# server and no Rust build.
#
# Usage: scripts/notification-sound-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/notification-sound-test"
mkdir -p "$out"

model=apps/AmiscaraAgents/AmiscaraAgents/Model
swiftc -swift-version 6 \
    "$model/NotificationSound.swift" \
    apps/AmiscaraAgents/Tests/NotificationSound/main.swift \
    -o "$out/notification-sound-test"

"$out/notification-sound-test"
