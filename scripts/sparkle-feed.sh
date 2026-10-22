#!/usr/bin/env bash
# Signs the Mac app's zip with the Sparkle key and writes appcast.xml, the
# feed in the release `updates` (docs/release.md). scripts/release.sh runs
# it at the end; the CI runs it as a step of its own, so the key never
# reaches the build.
#
#   scripts/sparkle-feed.sh <zip> <version> <build>
#
# The key comes from SPARKLE_ED_PRIVATE_KEY (CI, the output of
# `generate_keys -x`) or else from the login keychain (account
# amiscara-agents). The feed lands next to the zip.
set -euo pipefail

cd "$(dirname "$0")/.."

zip="${1:?zip}" version="${2:?version}" build="${3:?build}"
die() { echo "sparkle-feed: $*" >&2; exit 1; }

[[ -f "$zip" ]] || die "no zip at $zip"
# Sparkle comes as a Swift package; release.sh keeps its derived data here.
sign_update=$(find target/release-app/derived/SourcePackages/artifacts target/xcode/SourcePackages/artifacts \
    -path '*/old_dsa_scripts' -prune -o -type f -name sign_update -print 2>/dev/null | head -1 || true)
[[ -x "$sign_update" ]] || die "Sparkle's sign_update not found; build the app first"

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    key_file=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sparkle.XXXXXX")
    trap 'rm -f "$key_file"' EXIT
    chmod 600 "$key_file"
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" >"$key_file"
    unset SPARKLE_ED_PRIVATE_KEY
    signature=$("$sign_update" -f "$key_file" "$zip")
else
    signature=$("$sign_update" --account amiscara-agents "$zip")
fi
ed_signature=$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$signature")
length=$(sed -nE 's/.*length="([0-9]+)".*/\1/p' <<<"$signature")
[[ -n "$ed_signature" && -n "$length" ]] || die "cannot read the output of sign_update: $signature"

tag="apple-v$version"
appcast="$(dirname "$zip")/appcast.xml"
OUTPUT_PATH="$appcast" VERSION="$version" BUILD="$build" \
    ZIP_URL="https://github.com/staude/amiscara-agents/releases/download/$tag/$(basename "$zip")" \
    ZIP_LENGTH="$length" ZIP_ED_SIGNATURE="$ed_signature" \
    MIN_SYSTEM="$(sed -n 's/^ *macOS: "\(.*\)"$/\1/p' apps/AmiscaraAgents/project.yml | head -1)" \
    NOTES_URL="https://github.com/staude/amiscara-agents/releases/tag/$tag" \
    PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" \
    python3 scripts/appcast.py
echo "==> Feed: $appcast (for release $tag)"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "appcast=$appcast" >> "$GITHUB_OUTPUT"
fi
