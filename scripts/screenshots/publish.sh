#!/usr/bin/env bash
# Copies the screenshots from target/screenshots into docs/screenshots for
# the README (#199), scaled down so the repository stays small:
#
#   scripts/screenshots.sh && scripts/screenshots/publish.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
from=target/screenshots
to=docs/screenshots
[[ -d "$from" ]] || { echo "publish: no $from, run scripts/screenshots.sh first" >&2; exit 1; }

# Longest side per platform, in pixels: about twice the size shown.
size() {
    case "$1" in
        mac | desktop) echo 1440 ;;
        ipad) echo 1400 ;;
        ios | android) echo 1200 ;;
        tvos) echo 1280 ;;
        *) echo 1440 ;;
    esac
}

for dir in "$from"/*/; do
    platform=$(basename "$dir")
    mkdir -p "$to/$platform"
    for png in "$dir"*.png; do
        sips -Z "$(size "$platform")" "$png" --out "$to/$platform/$(basename "$png")" >/dev/null
    done
    echo "$to/$platform"
done
du -sh "$to"
