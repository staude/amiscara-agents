#!/usr/bin/env bash
# Builds the Spotlight entries of spaces and agents (#308) into a small
# command line test and runs it: detail text, keywords, the cap per kind,
# and the two link helpers on WidgetSnapshot. Needs no herdr server and no
# Rust build, and not CoreSpotlight, which SpotlightEntries.swift avoids.
#
# Usage: scripts/spotlight-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/spotlight-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/Shared/WidgetSnapshot.swift \
    apps/AmiscaraAgents/Shared/WidgetSnapshot+Style.swift \
    apps/AmiscaraAgents/AmiscaraAgents/Model/SpotlightEntries.swift \
    apps/AmiscaraAgents/Tests/Spotlight/main.swift \
    -o "$out/spotlight-test"

"$out/spotlight-test"
