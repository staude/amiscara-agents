# shellcheck shell=bash
# Shared by release.sh and testflight.sh (sourced, not run).
#
# Authentication for xcodebuild and notarytool: with an App Store Connect
# API key in the environment (CI), otherwise the Xcode account and the
# notarytool keychain profile of this Mac.
#
#   APPLE_API_KEY_PATH   path to the AuthKey_<id>.p8 file
#   APPLE_API_KEY_ID     key ID
#   APPLE_API_ISSUER_ID  issuer ID
#
# BUILD_NUMBER overrides CURRENT_PROJECT_VERSION for one build without
# touching project.yml (CI passes <project build>.<run number>.<attempt>).

# shellcheck disable=SC2034 # used by the scripts that source this
team="7N2W4T6UPV"
spec="apps/AmiscaraAgents/project.yml"

die() { echo "$(basename "$0"): $*" >&2; exit 1; }
step() { echo "==> $*"; }

has_api_key() {
    [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]
}

# Arguments for -allowProvisioningUpdates, used by the export only: the
# archive signs manually (scripts/Signing-*.xcconfig), so Xcode never
# creates a development certificate. With an API key xcodebuild needs no
# signed-in Xcode account.
xcode_auth=(-allowProvisioningUpdates)
if has_api_key; then
    [[ -f "$APPLE_API_KEY_PATH" ]] || die "APPLE_API_KEY_PATH: no file at $APPLE_API_KEY_PATH"
    xcode_auth+=(
        -authenticationKeyPath "$APPLE_API_KEY_PATH"
        -authenticationKeyID "$APPLE_API_KEY_ID"
        -authenticationKeyIssuerID "$APPLE_API_ISSUER_ID"
    )
fi

# Build settings for xcodebuild archive.
build_settings=()
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    [[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "BUILD_NUMBER '$BUILD_NUMBER' is not 1 to 3 numbers with dots"
    build_settings+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
fi

marketing_version() { sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' "$spec"; }
build_number() { echo "${BUILD_NUMBER:-$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' "$spec")}"; }

# Stops unless the keychain holds a signing identity of the team, e.g.
# require_identity "Developer ID Application".
require_identity() {
    security find-identity -v -p codesigning | grep -q "$1: .*($team)" \
        || die "no '$1' certificate for team $team in the keychain"
}

require_clean_tree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        die "working tree not clean; commit first so the build matches a revision"
    fi
}
