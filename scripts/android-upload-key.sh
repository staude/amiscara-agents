#!/usr/bin/env bash
# Creates the upload key for Google Play once: a PKCS12 keystore outside the
# repository, its random password in the macOS Keychain and
# apps/android/keystore.properties (not checked in) pointing to it.
#
# Usage: scripts/android-upload-key.sh [keystore path]
#
# Back up the keystore and the password (Keychain item
# "amiscara-agents-upload"). With Play App Signing a lost upload key can be
# reset through the Play Console, which takes days.
set -euo pipefail

store="${1:-$HOME/.android/amiscara-agents-upload.p12}"
alias=upload
service=amiscara-agents-upload
cd "$(dirname "$0")/.."

if [[ -e "$store" ]]; then
    echo "$store exists already, not replacing it" >&2
    exit 1
fi
if security find-generic-password -s "$service" >/dev/null 2>&1; then
    echo "Keychain item $service exists already" >&2
    exit 1
fi

password="$(openssl rand -base64 30 | tr -d '/+=\n')"
mkdir -p "$(dirname "$store")"
# The password goes to keytool through the environment, not the command line.
AMISCARA_NEW_PASSWORD="$password" keytool -genkeypair -storetype PKCS12 -keystore "$store" -alias "$alias" \
    -keyalg RSA -keysize 4096 -validity 10000 \
    -dname "CN=Amiscara Agents, O=Frank Neumann-Staude" \
    -storepass:env AMISCARA_NEW_PASSWORD -keypass:env AMISCARA_NEW_PASSWORD
chmod 600 "$store"
security add-generic-password -s "$service" -a "$alias" -w "$password"
printf 'storeFile=%s\nkeyAlias=%s\n' "$store" "$alias" > apps/android/keystore.properties

echo "Upload key: $store (alias $alias), password in the Keychain as $service."
echo "Back up both now."
