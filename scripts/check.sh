#!/usr/bin/env bash
# The checks before a merge, on this machine: CI runs only for releases
# (desktop-v* tags) and by hand, to save Actions minutes.
# --apple also builds the Mac and iOS schemes (needs ./setup.sh once),
# --android the Android app with lint (needs the NDK and cargo-ndk).
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
    for scheme in AmiscaraAgents AmiscaraAgents-iOS; do
        destination="platform=macOS"
        [[ "$scheme" == AmiscaraAgents-iOS ]] && destination="generic/platform=iOS"
        env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin" \
            xcodebuild -project apps/AmiscaraAgents/AmiscaraAgents.xcodeproj -scheme "$scheme" \
            -destination "$destination" -derivedDataPath target/xcode -quiet build
    done
fi
if $android; then
    (cd apps/android && ./gradlew -q assembleDebug lintDebug)
fi
echo "All checks passed."
