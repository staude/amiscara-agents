#!/usr/bin/env bash
# Builds the Android app, installs it on a connected phone or emulator and
# launches it.
#
#   scripts/install-android.sh               the only connected device
#   scripts/install-android.sh <serial>      a device by serial (adb devices)
#   scripts/install-android.sh --no-launch   install only
#
# The phone needs USB debugging (developer options) and must trust this Mac.
set -euo pipefail

cd "$(dirname "$0")/.."

launch=true
serial=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-launch) launch=false ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) serial="$1" ;;
    esac
    shift
done

die() { echo "install-android: $*" >&2; exit 1; }
step() { echo "==> $*"; }

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$ANDROID_HOME/platform-tools/adb"
[[ -x "$adb" ]] || die "adb not found under $ANDROID_HOME"

if [[ -z "$serial" ]]; then
    devices="$("$adb" devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
    [[ -n "$devices" ]] || die "no device connected (adb devices)"
    [[ "$(wc -l <<<"$devices")" -eq 1 ]] || die "several devices, name one: $(tr '\n' ' ' <<<"$devices")"
    serial="$devices"
fi

step "Build"
(cd apps/android && ./gradlew -q assembleDebug)

step "Install on $serial"
"$adb" -s "$serial" install -r apps/android/app/build/outputs/apk/debug/app-debug.apk

if $launch; then
    step "Launch"
    "$adb" -s "$serial" shell am start -n net.staude.amiscara.agents/.MainActivity >/dev/null
fi
echo "Done."
