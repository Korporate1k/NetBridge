#!/bin/bash
# Builds the NetBridge Windows client on this Mac and packages it:
#   scripts/build-windows.sh [x64|arm64]   (default x64)
#   build/windows/NetBridge-win-<arch>.zip  =  NetBridge.exe + wintun.dll + README.txt + wintun-LICENSE.txt
#
# Cross-compiles with cargo-xwin (downloads the MSVC CRT + Windows SDK libraries on first use into
# ~/Library/Caches/cargo-xwin; nothing needs to be installed system-wide). The engine is tun2proxy @ fc77ca3 with
# the same patches as the Apple builds, prepared by NetBridgeWindows/patch-deps.sh.
#
# Needs: rustup, network access (crates, the xwin SDK and wintun.net on first run).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/NetBridgeWindows"
OUT="$ROOT/build/windows"
ARCH="${1:-x64}"
case "$ARCH" in
    x64) TARGET=x86_64-pc-windows-msvc; WINTUN_DIR=amd64 ;;
    arm64) TARGET=aarch64-pc-windows-msvc; WINTUN_DIR=arm64 ;;
    *) echo "usage: $0 [x64|arm64]" >&2; exit 2 ;;
esac
# Official signed build from wintun.net. Pinned: a different download is refused.
WINTUN_VERSION=0.14.1
WINTUN_ZIP_SHA256=07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51

rustup target add "$TARGET" >/dev/null
command -v cargo-xwin >/dev/null || cargo install cargo-xwin --locked

if [ ! -d "$APP/vendor/tun2proxy" ]; then
    "$APP/patch-deps.sh"
fi

echo "== unit tests (host)"
(cd "$APP" && cargo test --quiet)

echo "== cross-compiling for $TARGET"
(cd "$APP" && cargo xwin build --release --target "$TARGET")
EXE="$APP/target/$TARGET/release/NetBridge.exe"

echo "== wintun $WINTUN_VERSION"
mkdir -p "$OUT/cache"
ZIP="$OUT/cache/wintun-$WINTUN_VERSION.zip"
[ -f "$ZIP" ] || curl -sSfL -o "$ZIP" "https://www.wintun.net/builds/wintun-$WINTUN_VERSION.zip"
echo "$WINTUN_ZIP_SHA256  $ZIP" | shasum -a 256 -c -
rm -rf "$OUT/cache/wintun"
unzip -oq "$ZIP" -d "$OUT/cache"

echo "== packaging"
DIST="$OUT/dist-$ARCH/NetBridge"
rm -rf "$OUT/dist-$ARCH"
mkdir -p "$DIST"
cp "$EXE" "$DIST/NetBridge.exe"
cp "$OUT/cache/wintun/bin/$WINTUN_DIR/wintun.dll" "$DIST/wintun.dll"
cp "$OUT/cache/wintun/LICENSE.txt" "$DIST/wintun-LICENSE.txt"
cp "$APP/README-windows.txt" "$DIST/README.txt"
ZIPOUT="$OUT/NetBridge-win-$ARCH.zip"
rm -f "$ZIPOUT"
(cd "$OUT/dist-$ARCH" && zip -qr "$ZIPOUT" NetBridge)

file "$DIST/NetBridge.exe" "$DIST/wintun.dll"
shasum -a 256 "$DIST/NetBridge.exe" "$DIST/wintun.dll" "$ZIPOUT"
echo "Built $ZIPOUT"
