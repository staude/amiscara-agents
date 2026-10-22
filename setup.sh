#!/usr/bin/env bash
# Prepares a fresh checkout: toolchain check, build and tests.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo not found. Install Rust from https://rustup.rs and run this again." >&2
    exit 1
fi
if command -v rustup >/dev/null 2>&1; then
    rustup component add rustfmt clippy
fi

cargo build --workspace
cargo test --workspace

# Mac app: Rust library, Swift bindings, Xcode project from project.yml.
if [[ "$(uname)" == "Darwin" ]]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "xcodegen not found: brew install xcodegen" >&2
        exit 1
    fi
    rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
    scripts/build-ffi.sh debug all
    (cd apps/AmiscaraAgents && xcodegen generate)
fi

# Android app: only when an Android SDK is there (Android Studio). The NDK
# comes from the SDK manager (version in apps/android/app/build.gradle.kts).
android_home="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ -d "$android_home" ]] && command -v rustup >/dev/null 2>&1; then
    rustup target add aarch64-linux-android x86_64-linux-android
    command -v cargo-ndk >/dev/null 2>&1 || cargo install cargo-ndk --locked
    [[ -d "$android_home/ndk" ]] || echo "No NDK yet: sdkmanager \"ndk;29.0.14206865\"" >&2
fi
