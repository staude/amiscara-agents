#!/usr/bin/env bash
# Screenshots of all apps from the seeded demo session (#199).
#
#   scripts/screenshots.sh [--platform mac|ios|duo|duo-open|ipad|tvos|android|desktop|all]...
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
[[ ${#platforms[@]} -eq 0 || " ${platforms[*]} " == *" all "* ]] && platforms=(mac ios duo ipad tvos android desktop)

step() { echo "==> $*"; }
want() { [[ " ${platforms[*]} " == *" $1 "* ]]; }

# Pane id from the seed: pane <space label> <tab index> <pane index>.
pane() {
    python3 -c 'import json,sys; ids=json.load(open(sys.argv[1])); print(ids["spaces"][sys.argv[2]]["tabs"][int(sys.argv[3])]["panes"][int(sys.argv[4])])' \
        "$root/ids.json" "$1" "$2" "$3"
}

pids=()
keys=~/.ssh/authorized_keys
key_comment=amiscara-agents-screenshots-demo
keys_backup=""
emulator_started=false
cleanup() {
    for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
    pkill -f "vite --port 1420 --strictPort" 2>/dev/null || true
    if [[ -n "$keys_backup" ]]; then
        # Only the demo line goes; the file must then match the backup.
        grep -v " $key_comment\$" "$keys" >"$keys_backup.new" || true
        cat "$keys_backup.new" >"$keys"
        rm -f "$keys_backup.new"
        if cmp -s "$keys" "$keys_backup"; then
            rm -f "$keys_backup"
        else
            echo "screenshots: $keys differs from its backup $keys_backup, check it" >&2
        fi
    fi
    if $emulator_started; then adb emu kill >/dev/null 2>&1 || true; fi
    for udid in ${booted[@]+"${booted[@]}"}; do xcrun simctl shutdown "$udid" 2>/dev/null || true; done
    if ! $keep; then python3 "$here/seed.py" --stop; fi
}
trap cleanup EXIT

step "Demo session $session"
python3 "$here/seed.py"
mkdir -p "$out"
if want mac || want desktop; then swiftc -O -o "$out/window-id" "$here/window-id.swift"; fi

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
# id from IPHONE_SIM, DUO_SIM, IPAD_SIM, TV_SIM. The iPhone Duo has two
# displays: duo takes the outer one (folded), duo-open the inner one, for
# which the simulator has to be unfolded first (Device Hub, buttons under
# the device); simctl cannot fold it.
booted=()
sim_display=""
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
        xcrun simctl io "$udid" screenshot ${sim_display:+--display="$sim_display"} "$out/$name/$shot.png" >/dev/null 2>&1
        echo "    $out/$name/$shot.png"
    done
    xcrun simctl terminate "$udid" net.staude.amiscara.agents 2>/dev/null || true
    if $bars; then xcrun simctl status_bar "$udid" clear; fi
}

# --- Android (emulator) -------------------------------------------------
# The emulator reaches the Mac over SSH at 10.0.2.2 with a throwaway key
# whose line in authorized_keys only opens the demo session's socket (no
# SFTP, so no conversation view); the line is removed again at the end.
android() {
    step "Android app (debug build)"
    (cd apps/android && ./gradlew -q :app:assembleDebug)
    if ! adb get-state >/dev/null 2>&1; then
        step "Emulator ${ANDROID_AVD:-Pixel_9}"
        "${ANDROID_HOME:-$HOME/Library/Android/sdk}/emulator/emulator" -avd "${ANDROID_AVD:-Pixel_9}" \
            -no-window -no-audio -no-boot-anim -no-snapshot-save >"$root/emulator.log" 2>&1 &
        emulator_started=true
        adb wait-for-device
        until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do sleep 2; done
    fi
    adb install -r apps/android/app/build/outputs/apk/debug/app-debug.apk >/dev/null
    local app=net.staude.amiscara.agents
    for permission in android.permission.POST_NOTIFICATIONS android.permission.ACCESS_LOCAL_NETWORK; do
        adb shell pm grant "$app" "$permission" 2>/dev/null || true
    done
    adb shell cmd uimode night "$([[ $appearance == dark ]] && echo yes || echo no)" >/dev/null

    step "Demo key for 10.0.2.2"
    ssh-keygen -q -t ed25519 -N "" -C "$key_comment" -f "$root/demo-key"
    keys_backup="$out/.authorized_keys.backup"
    cp -p "$keys" "$keys_backup"
    # shellcheck disable=SC2016 # $SSH_ORIGINAL_COMMAND is for sshd
    printf 'restrict,command="case \\"$SSH_ORIGINAL_COMMAND\\" in *sftp*) exit 1 ;; *) exec nc -U \\"%s\\" ;; esac" %s\n' \
        "$socket" "$(cat "$root/demo-key.pub")" >>"$keys"
    local key host_key
    key=$(base64 <"$root/demo-key" | tr -d '\n')
    host_key=$(ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | awk '!/^#/ {printf "%s %s", $2, $3}' | base64 | tr -d '\n')

    # Clean status bar: 9:41, full battery, no notifications.
    adb shell settings put global sysui_demo_allowed 1
    local demo=com.android.systemui.demo
    adb shell am broadcast -a $demo -e command enter >/dev/null
    adb shell am broadcast -a $demo -e command clock -e hhmm 0941 >/dev/null
    adb shell am broadcast -a $demo -e command battery -e level 100 -e plugged false >/dev/null
    adb shell am broadcast -a $demo -e command network -e wifi show -e level 4 >/dev/null
    adb shell am broadcast -a $demo -e command notifications -e visible false >/dev/null

    mkdir -p "$out/android"
    local entry shot space where view search target
    for entry in "hosts||||" "${views[@]}" "settings|||settings|"; do
        IFS='|' read -r shot space where view search <<<"$entry"
        [[ "$shot" == conversation || "$shot" == search ]] && continue
        target=""
        # shellcheck disable=SC2086 # where is "tab index"
        [[ -n "$space" ]] && target=$(pane "$space" $where)
        adb shell am start -S -W -n "$app/.MainActivity" \
            --es demoHost 10.0.2.2 --es demoUser "$USER" --es demoSocket "$socket" \
            --es demoKey "$key" --es demoHostKey "$host_key" \
            --es demoPane "'$target'" --es demoView "'$view'" >/dev/null
        sleep 8
        adb exec-out screencap -p >"$out/android/$shot.png"
        echo "    $out/android/$shot.png"
    done
    adb shell am force-stop "$app"
    adb shell am broadcast -a $demo -e command exit >/dev/null
}

want mac && mac
if want ios || want duo || want duo-open || want ipad; then
    step "iOS app for the simulator"
    sim_build AmiscaraAgents-iOS "iOS Simulator"
    ios_app=target/xcode-sim/Build/Products/Debug-iphonesimulator/AmiscaraAgents.app
    want ios && sim ios "${IPHONE_SIM:-$(sim_id "iPhone 18 Pro")}" "$ios_app" true \
        "spaces||||" "${views[@]}"
    if want duo; then
        sim_display=primary
        sim duo "${DUO_SIM:-$(sim_id "iPhone Duo")}" "$ios_app" true "spaces||||" "${views[@]}"
        sim_display=""
    fi
    if want duo-open; then
        sim_display=primary-1
        sim duo-open "${DUO_SIM:-$(sim_id "iPhone Duo")}" "$ios_app" true "${views[@]}"
        sim_display=""
    fi
    want ipad && sim ipad "${IPAD_SIM:-$(sim_id "iPad Pro 13-inch (M5)")}" "$ios_app" true \
        "${views[@]}"
fi
# --- Windows and Linux desktop app -------------------------------------
# The same Svelte UI and Rust side, run here as a debug build against the
# vite dev server, with a home of its own whose hosts.json holds only the
# demo session (a local host, as on Linux).
desktop() {
    step "Desktop app (debug build)"
    (cd apps/desktop && { [[ -d node_modules ]] || npm ci --silent; })
    cargo build -q -p amiscara-desktop
    local data="$root/home/Library/Application Support/net.staude.amiscara.agents"
    mkdir -p "$data" "$out/desktop"
    printf '[{"id":"demo","name":"Mac Studio","kind":"local","socketPath":"%s","notify":false}]\n' \
        "$socket" >"$data/hosts.json"
    (cd apps/desktop && exec npx vite --port 1420 --strictPort >"$root/vite.log" 2>&1) &
    pids+=("$!")
    sleep 4
    local entry shot space where view search target pid window
    for entry in "${views[@]}" "settings|Shop/API|0 0|settings|"; do
        IFS='|' read -r shot space where view search <<<"$entry"
        # shellcheck disable=SC2086 # where is "tab index"
        target=$(pane "$space" $where)
        # SCREENSHOT_LANG=de|en: the app's language instead of the system's.
        HOME="$root/home" AMISCARA_DEMO=$(printf '{"space":"%s","pane":"%s","view":"%s","search":"%s","appearance":"%s","lang":"%s"}' \
            "$space" "$target" "$view" "$search" "$appearance" "${SCREENSHOT_LANG:-}") \
            target/debug/amiscara-desktop >"$root/desktop.log" 2>&1 &
        pid=$!
        pids+=("$pid")
        sleep 8
        window=$("$out/window-id" "$pid")
        screencapture -x -o -l "$window" "$out/desktop/$shot.png"
        kill "$pid"
        wait "$pid" 2>/dev/null || true
        echo "    $out/desktop/$shot.png"
    done
}

want android && android
want desktop && desktop
if want tvos; then
    step "tvOS app for the simulator"
    sim_build AmiscaraAgents-tvOS "tvOS Simulator"
    sim tvos "${TV_SIM:-$(sim_id "Apple TV 4K (3rd generation)")}" \
        target/xcode-sim/Build/Products/Debug-appletvsimulator/AmiscaraAgents.app false \
        "spaces||||" "space-waiting|Shop/API|0 0||" "split-tab|Shop/Web|1 0||" \
        "agent-done|Lab/WeatherStation|0 0||"
fi
step "Done: $out"
