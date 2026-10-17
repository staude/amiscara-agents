#!/usr/bin/env bash
# Builds the iOS app for a connected iPad or iPhone, installs and launches it.
#
#   scripts/install-ios.sh                 the only connected device
#   scripts/install-ios.sh "iPad (2)"      a device by name or UDID
#   scripts/install-ios.sh --release ...   Release instead of Debug
#   scripts/install-ios.sh --no-launch ... install only
#
# The device must be paired, unlocked and in developer mode. After an iOS
# update the first debug launch from Xcode can take long while Xcode copies
# the device symbols; this script launches without a debugger.
set -euo pipefail

cd "$(dirname "$0")/.."

configuration="Debug"
launch=true
wanted=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) configuration="Release" ;;
        --no-launch) launch=false ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) wanted="$1" ;;
    esac
    shift
done

die() { echo "install-ios: $*" >&2; exit 1; }
step() { echo "==> $*"; }

devices_json="$(mktemp)"
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" >/dev/null

# Connected physical iPhones and iPads: "udid<TAB>name" per line.
candidates="$(python3 -I - "$devices_json" "$wanted" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = sys.argv[2]
for d in data:
    hw, conn, props = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical":
        continue
    if conn.get("tunnelState") != "connected":
        continue
    udid, name = hw.get("udid", ""), props.get("name", "")
    if wanted and wanted not in (udid, name):
        continue
    print(f"{udid}\t{name}")
PY
)"

count=$(printf '%s' "$candidates" | grep -c . || true)
if [[ "$count" -eq 0 ]]; then
    die "no connected iPhone or iPad${wanted:+ matching '$wanted'} (xcrun devicectl list devices)"
elif [[ "$count" -gt 1 ]]; then
    echo "$candidates" | sed 's/^/    /' >&2
    die "several devices connected; pass a name or UDID"
fi
udid="${candidates%%$'\t'*}"
name="${candidates#*$'\t'}"

step "Build HerdrRemote-iOS ($configuration) for $name"
derived="target/xcode-device"
xcodebuild -project apps/HerdrRemote/HerdrRemote.xcodeproj -scheme HerdrRemote-iOS \
    -configuration "$configuration" -destination "id=$udid" \
    -derivedDataPath "$derived" -allowProvisioningUpdates -quiet build

app="$derived/Build/Products/$configuration-iphoneos/HerdrRemote.app"
[[ -d "$app" ]] || die "build product missing: $app"

step "Install on $name"
xcrun devicectl device install app --device "$udid" "$app" >/dev/null

if $launch; then
    step "Launch"
    xcrun devicectl device process launch --device "$udid" --terminate-existing \
        net.staude.herdrremote >/dev/null
fi
step "Done"
