#!/usr/bin/env bash
# Sets the desktop app's version and tags it; pushing the tag starts the
# release workflow (.github/workflows/desktop-release.yml).
#
# Usage: scripts/desktop-release.sh <version>    e.g. 0.2.0
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <major.minor.patch>" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree not clean" >&2
    exit 1
fi

(cd apps/desktop && npm version "$version" --no-git-tag-version >/dev/null)
# The package's own version, the first `version =` line.
perl -0pi -e "s/^version = \".*?\"/version = \"$version\"/m" apps/desktop/src-tauri/Cargo.toml
cargo update -q -p amiscara-desktop

git add apps/desktop/package.json apps/desktop/package-lock.json apps/desktop/src-tauri/Cargo.toml Cargo.lock
git commit -q -m "chore(desktop): release $version"
git tag "desktop-v$version"
echo "Tagged desktop-v$version. Push both to release:"
echo "  git push && git push origin desktop-v$version"
