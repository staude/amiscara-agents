#!/usr/bin/env bash
# Screenshots of all apps from the seeded demo session (#199).
#
#   scripts/screenshots.sh [--platform mac|ios|ipad|tvos|android|desktop|all]...
#                          [--appearance dark|light] [--keep]
#
# Builds the demo in its own herdr session (scripts/screenshots/seed.py),
# drives each app to its important views and saves PNGs to
# target/screenshots/<platform>/<view>.png. Nothing touches the default
# herdr session, the apps' real hosts or settings: the Mac app and the
# simulators run in a demo mode of the debug build (DemoMode.swift) with a
# home of their own under the demo root. --keep leaves the session running.
# See docs/screenshots.md.
set -euo pipefail

cd "$(dirname "$0")/.."
here=scripts/screenshots
out=target/screenshots
root=$(python3 -c 'import json; print(json.load(open("scripts/screenshots/demo.json"))["root"])')
session=$(python3 -c 'import json; print(json.load(open("scripts/screenshots/demo.json"))["session"])')
socket="$HOME/.config/herdr/sessions/$session/herdr.sock"
appearance=dark
keep=false
platforms=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) platforms+=("$2"); shift 2 ;;
        --appearance) appearance="$2"; shift 2 ;;
        --keep) keep=true; shift ;;
        *) sed -n '4,5p' "$0" | sed 's/^# //'; exit 1 ;;
    esac
done
[[ ${#platforms[@]} -eq 0 || " ${platforms[*]} " == *" all "* ]] && platforms=(mac ios ipad tvos android desktop)

step() { echo "==> $*"; }
want() { [[ " ${platforms[*]} " == *" $1 "* ]]; }

# Pane id from the seed: pane <space label> <tab index> <pane index>.
pane() {
    python3 -c 'import json,sys; ids=json.load(open(sys.argv[1])); print(ids["spaces"][sys.argv[2]]["tabs"][int(sys.argv[3])]["panes"][int(sys.argv[4])])' \
        "$root/ids.json" "$1" "$2" "$3"
}

pids=()
cleanup() {
    for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
    for udid in ${booted[@]+"${booted[@]}"}; do xcrun simctl shutdown "$udid" 2>/dev/null || true; done
    if ! $keep; then python3 "$here/seed.py" --stop; fi
}
trap cleanup EXIT

step "Demo session $session"
python3 "$here/seed.py"
mkdir -p "$out"

# Views shared by the Apple apps: name, space, pane (tab, index), view, search.
views=(
    "space-waiting|Shop/API|0 0||"
    "space-working|Shop/Web|0 0||"
    "split-tab|Shop/Web|1 0||"
    "agent-done|Lab/WeatherStation|0 0||"
    "worktree|Shop/API refunds|0 0||"
    "shell|csvtool|0 0||"
    "search|Shop/Web|1 2||passed"
    "conversation|Shop/API|0 0|conversation|"
    "quick-switcher|Shop/API|0 0|switcher|"
    "add-host|Shop/API|0 0|addHost|"
)

# --- Mac ---------------------------------------------------------------
mac() {
    step "Mac app (debug build)"
    env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild \
        -project apps/AmiscaraAgents/AmiscaraAgents.xcodeproj -scheme AmiscaraAgents \
        -derivedDataPath target/xcode build -quiet
    local app=target/xcode/Build/Products/Debug/AmiscaraAgents.app/Contents/MacOS/AmiscaraAgents
    swiftc -O -o "$out/window-id" "$here/window-id.swift"
    mkdir -p "$out/mac" "$root/home"
    local entry name space where view search pid window
    for entry in "${views[@]}" "settings|Shop/API|0 0|settings|"; do
        IFS='|' read -r name space where view search <<<"$entry"
        # shellcheck disable=SC2086 # where is "tab index"
        HOME="$root/home" CFFIXED_USER_HOME="$root/home" "$app" \
            -demoSocket "$socket" -demoSpace "$space" -demoPane "$(pane "$space" $where)" \
            -demoView "$view" -demoSearch "$search" -demoWindow 1440x900 \
            -appearance "$appearance" >"$root/mac.log" 2>&1 &
        pid=$!
        pids+=("$pid")
        sleep 6
        # The front window: the main window, or the settings when asked.
        window=$("$out/window-id" "$pid")
        screencapture -x -o -l "$window" "$out/mac/$name.png"
        kill "$pid"
        wait "$pid" 2>/dev/null || true
        echo "    $out/mac/$name.png"
    done
}

# --- iPhone, iPad, Apple TV (simulators) -------------------------------
# The simulators reach the Mac's sockets, so the demo host is the session's
# socket here too: no SSH key, no authorized_keys. Devices by name, or by
# id from IPHONE_SIM, IPAD_SIM, TV_SIM.
booted=()
sim_id() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if device["name"] == name:
            print(device["udid"]); sys.exit()
sys.exit("no simulator named " + name)' "$1"
}

sim_build() {
    local scheme=$1 platform=$2
    env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild \
        -project apps/AmiscaraAgents/AmiscaraAgents.xcodeproj -scheme "$scheme" \
        -destination "generic/platform=$platform" -derivedDataPath target/xcode-sim \
        ARCHS=arm64 build -quiet
}

sim() {
    local name=$1 udid=$2 app=$3 bars=$4
    shift 4
    step "$name simulator ($udid)"
    if xcrun simctl list devices | grep -q "$udid) (Shutdown)"; then
        xcrun simctl boot "$udid"
        booted+=("$udid")
    fi
    xcrun simctl bootstatus "$udid" >/dev/null
    xcrun simctl install "$udid" "$app"
    xcrun simctl ui "$udid" appearance "$appearance" 2>/dev/null || true
    if $bars; then
        xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged \
            --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
    fi
    mkdir -p "$out/$name"
    local entry shot space where view search target
    for entry in "$@"; do
        IFS='|' read -r shot space where view search <<<"$entry"
        target=""
        # shellcheck disable=SC2086 # where is "tab index"
        [[ -n "$space" ]] && target=$(pane "$space" $where)
        # A relaunch right after terminating can leave tvOS on its home screen.
        xcrun simctl terminate "$udid" net.staude.amiscara.agents 2>/dev/null || true
        sleep 2
        SIMCTL_CHILD_HOME="$root/home" xcrun simctl launch "$udid" \
            net.staude.amiscara.agents -demoSocket "$socket" -demoSpace "$space" \
            -demoPane "$target" -demoView "$view" -demoSearch "$search" \
            -appearance "$appearance" >/dev/null
        sleep 7
        xcrun simctl io "$udid" screenshot "$out/$name/$shot.png" >/dev/null 2>&1
        echo "    $out/$name/$shot.png"
    done
    xcrun simctl terminate "$udid" net.staude.amiscara.agents 2>/dev/null || true
    if $bars; then xcrun simctl status_bar "$udid" clear; fi
}

want mac && mac
if want ios || want ipad; then
    step "iOS app for the simulator"
    sim_build AmiscaraAgents-iOS "iOS Simulator"
    ios_app=target/xcode-sim/Build/Products/Debug-iphonesimulator/AmiscaraAgents.app
    want ios && sim ios "${IPHONE_SIM:-$(sim_id "iPhone 18 Pro")}" "$ios_app" true \
        "spaces||||" "${views[@]}"
    want ipad && sim ipad "${IPAD_SIM:-$(sim_id "iPad Pro 13-inch (M5)")}" "$ios_app" true \
        "${views[@]}"
fi
if want tvos; then
    step "tvOS app for the simulator"
    sim_build AmiscaraAgents-tvOS "tvOS Simulator"
    sim tvos "${TV_SIM:-$(sim_id "Apple TV 4K (3rd generation)")}" \
        target/xcode-sim/Build/Products/Debug-appletvsimulator/AmiscaraAgents.app false \
        "spaces||||" "space-waiting|Shop/API|0 0||" "split-tab|Shop/Web|1 0||" \
        "agent-done|Lab/WeatherStation|0 0||"
fi
step "Done: $out"
