#!/usr/bin/env bash
# Sets the Android app's version, raises its versionCode (Google Play needs
# a higher one for every upload), commits and tags it and builds the signed
# App Bundle for the Play Console.
#
# Usage: scripts/android-release.sh <version>    e.g. 0.2.0
#
# Needs the upload key from scripts/android-upload-key.sh.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <major.minor.patch>" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree not clean" >&2
    exit 1
fi
if [[ ! -f apps/android/keystore.properties ]]; then
    echo "no upload key, run scripts/android-upload-key.sh first" >&2
    exit 1
fi
password="$(security find-generic-password -s amiscara-agents-upload -w)"

props=apps/android/version.properties
code=$(( $(sed -n 's/^versionCode=//p' "$props") + 1 ))
sed -i '' -e "s/^versionName=.*/versionName=$version/" -e "s/^versionCode=.*/versionCode=$code/" "$props"

(cd apps/android && AMISCARA_UPLOAD_KEY_PASSWORD="$password" ./gradlew -q bundleRelease)
bundle=apps/android/app/build/outputs/bundle/release/app-release.aab
if ! jarsigner -verify "$bundle" | grep -q "jar verified"; then
    echo "$bundle is not signed" >&2
    exit 1
fi

git add "$props"
git commit -q -m "chore(android): release $version ($code)"
git tag "android-v$version"
echo "Built $bundle ($version, versionCode $code), tagged android-v$version."
echo "Upload it in the Play Console, then push:"
echo "  git push && git push origin android-v$version"
