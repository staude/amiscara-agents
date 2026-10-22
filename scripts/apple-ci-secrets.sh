#!/usr/bin/env bash
# Stores the Apple signing data as secrets of the GitHub environment
# `apple-release`, which .github/workflows/apple-release.yml uses. Run it
# once on a Mac with `gh` signed in; nothing is written to the repository
# or to disk.
#
#   scripts/apple-ci-secrets.sh --key-id <id> --issuer-id <uuid> --key <AuthKey_<id>.p8> \
#       [--devid <developer-id.p12>] [--dist <apple-distribution.p12>]
#
# Without --devid or --dist the workflow signs with cloud-managed
# certificates, which needs an API key of the Admin role. Passwords of
# the .p12 files are asked for and not echoed. See docs/release.md.
set -euo pipefail

env="apple-release"
key_id="" issuer_id="" key="" devid="" dist=""

die() { echo "apple-ci-secrets: $*" >&2; exit 1; }
usage() { sed -n '7,8p' "$0" | sed 's/^# //'; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key-id) key_id="${2:-}"; shift 2 ;;
        --issuer-id) issuer_id="${2:-}"; shift 2 ;;
        --key) key="${2:-}"; shift 2 ;;
        --devid) devid="${2:-}"; shift 2 ;;
        --dist) dist="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -n "$key_id" && -n "$issuer_id" && -n "$key" ]] || usage
[[ -f "$key" ]] || die "no file at $key"
[[ -z "$devid" || -f "$devid" ]] || die "no file at $devid"
[[ -z "$dist" || -f "$dist" ]] || die "no file at $dist"
command -v gh >/dev/null || die "gh not found (brew install gh)"
# Paths stay relative to where the script was started; gh looks at this repo.
repo=$(cd "$(dirname "$0")" && gh repo view --json nameWithOwner --jq .nameWithOwner)

# The environment keeps the secrets away from pull requests and other
# refs: it is created with its deployment rules before any secret goes in,
# so only `main` and tags `apple-v*` can use them. Running the script again
# keeps the rules that exist.
gh api -X PUT "repos/$repo/environments/$env" \
    -F "deployment_branch_policy[protected_branches]=false" \
    -F "deployment_branch_policy[custom_branch_policies]=true" >/dev/null
policies=$(gh api "repos/$repo/environments/$env/deployment-branch-policies" \
    --jq '.branch_policies[] | "\(.type // "branch"):\(.name)"')
allow() {
    grep -qxF "$1:$2" <<<"$policies" && return
    gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" \
        -f "name=$2" -f "type=$1" >/dev/null
}
allow branch main
allow tag 'apple-v*'

secret() { gh secret set "$1" --env "$env" --repo "$repo"; }

# Reads a password without echoing it and checks it opens the .p12.
p12_password() {
    local file="$1" password
    read -r -s -p "Password of $(basename "$file"): " password </dev/tty
    echo >&2
    openssl pkcs12 -in "$file" -nokeys -passin fd:3 -legacy >/dev/null 2>&1 3<<<"$password" \
        || openssl pkcs12 -in "$file" -nokeys -passin fd:3 >/dev/null 2>&1 3<<<"$password" \
        || die "wrong password for $file"
    printf '%s' "$password"
}

echo "Secrets for environment '$env' of $repo"
printf '%s' "$key_id" | secret APPLE_API_KEY_ID
printf '%s' "$issuer_id" | secret APPLE_API_ISSUER_ID
base64 <"$key" | secret APPLE_API_KEY_P8

if [[ -n "$devid" ]]; then
    password=$(p12_password "$devid")
    base64 <"$devid" | secret APPLE_DEVID_P12
    printf '%s' "$password" | secret APPLE_DEVID_P12_PASSWORD
fi
if [[ -n "$dist" ]]; then
    password=$(p12_password "$dist")
    base64 <"$dist" | secret APPLE_DIST_P12
    printf '%s' "$password" | secret APPLE_DIST_P12_PASSWORD
fi
unset password

# Only protects the temporary keychain on the runner.
openssl rand -base64 24 | tr -d '\n' | secret KEYCHAIN_PASSWORD

echo "Done. Check them under Settings > Environments > $env."
