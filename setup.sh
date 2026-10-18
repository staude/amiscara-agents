#!/usr/bin/env bash
# Prepares a fresh checkout: git identity, toolchain check, build and tests.
set -euo pipefail

cd "$(dirname "$0")"

git config user.name "Frank Neumann-Staude"
git config user.email "frank@staude.net"

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
