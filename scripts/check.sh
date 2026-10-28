#!/usr/bin/env bash
# The checks to run before pushing; CI runs the same and more for every
# pull request.
# --apple also builds the Mac and iOS schemes (needs ./setup.sh once),
# --android the Android app with lint and unit tests (needs the NDK and cargo-ndk).
set -euo pipefail

cd "$(dirname "$0")/.."

apple=false
android=false
for arg in "$@"; do
    case "$arg" in
        --apple) apple=true ;;
        --android) android=true ;;
        *) echo "check.sh: unknown option $arg" >&2; exit 1 ;;
    esac
done

cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
(cd apps/desktop && npm run check)

if $apple; then
    scripts/last-tabs-test.sh
    scripts/netbird-test.sh
    scripts/pane-visits-test.sh
    scripts/pane-cache-test.sh
    scripts/agent-overview-test.sh
    scripts/agent-status-test.sh
    for scheme in AmiscaraAgents AmiscaraAgents-iOS; do
        destination="platform=macOS"
        [[ "$scheme" == AmiscaraAgents-iOS ]] && destination="generic/platform=iOS"
        env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin" \
            xcodebuild -project apps/AmiscaraAgents/AmiscaraAgents.xcodeproj -scheme "$scheme" \
            -destination "$destination" -derivedDataPath target/xcode -quiet build
    done
    # Needs the bindings the Xcode build made.
    scripts/pane-cache-ffi-test.sh
fi
if $android; then
    # Code under cfg(target_os = "android") only compiles for the phone.
    export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
    cargo ndk -t arm64-v8a -P 29 clippy -p herdr-ffi --locked -- -D warnings
    (cd apps/android && ./gradlew -q assembleDebug lintDebug testDebugUnitTest)
fi
echo "All checks passed."
