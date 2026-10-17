#!/usr/bin/env bash
# Raises CURRENT_PROJECT_VERSION in the app's project.yml by one and
# regenerates the Xcode project. Every notarized build gets its own number;
# numbers are never reused or lowered.
set -euo pipefail

cd "$(dirname "$0")/.."
spec="apps/HerdrRemote/project.yml"

current=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p' "$spec")
if [[ -z "$current" ]]; then
    echo "CURRENT_PROJECT_VERSION not found in $spec" >&2
    exit 1
fi
next=$((current + 1))
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: \)\"$current\"$/\1\"$next\"/" "$spec"
(cd apps/HerdrRemote && xcodegen generate --quiet)
echo "build $current -> $next"
