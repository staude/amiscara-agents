#!/usr/bin/env bash
# Builds the switcher's command logic (#346) into a small command line test
# and runs it: the `>` prefix, how commands and entries are combined, the
# shortcut glyphs and the matching. Needs no herdr server, no Rust build
# and no SwiftUI, which PaletteCommand.swift avoids.
#
# Usage: scripts/command-palette-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

out="target/command-palette-test"
mkdir -p "$out"

swiftc -swift-version 6 \
    apps/AmiscaraAgents/AmiscaraAgents/Model/PaletteCommand.swift \
    apps/AmiscaraAgents/Tests/CommandPalette/main.swift \
    -o "$out/command-palette-test"

"$out/command-palette-test"
