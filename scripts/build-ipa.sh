#!/usr/bin/env bash
# Builds an unsigned Release LocalProxy.ipa for sideloading, with a fresh build
# number every run. Sideloading tools silently keep the old binary if the build
# number doesn't change, so never package without bumping it.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d.%H%M%S)}"
PRODUCTS="build/Build/Products/Release-iphoneos"
IPA="$PRODUCTS/LocalProxy.ipa"
LOG="build/xcodebuild.log"

mkdir -p build
echo "Building LocalProxy (build $BUILD_NUMBER)..."
if ! xcodebuild -project LocalProxy.xcodeproj -scheme LocalProxy -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > "$LOG" 2>&1; then
  echo "BUILD FAILED — errors:"
  grep "error:" "$LOG" || true
  echo "--- last 30 lines of $LOG ---"
  tail -30 "$LOG"
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Payload"
cp -R "$PRODUCTS/LocalProxy.app" "$tmp/Payload/"

built_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$tmp/Payload/LocalProxy.app/Info.plist")"
if [ "$built_version" != "$BUILD_NUMBER" ]; then
  echo "ERROR: built CFBundleVersion is '$built_version', expected '$BUILD_NUMBER' — refusing to package a stale version."
  exit 1
fi
short_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$tmp/Payload/LocalProxy.app/Info.plist")"

rm -f "$IPA"
ipa_abs="$(pwd)/$IPA"
(cd "$tmp" && zip -qry -X "$ipa_abs" Payload)

echo "BUILD SUCCEEDED"
echo "IPA:     $ipa_abs"
echo "Version: $short_version ($built_version)"
echo "Size:    $(du -h "$IPA" | cut -f1)"
