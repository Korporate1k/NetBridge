#!/bin/bash
# Builds all five slices of LWIPTunnelEngine/tun2proxy.xcframework (ios-arm64, ios-arm64-simulator, macos-arm64,
# tvos-arm64, tvos-arm64-simulator)
# from source: tun2proxy @ fc77ca3 plus the local patches in LWIPTunnelEngine/patches, applied in the same order as
# NetBridgeWindows/patch-deps.sh. Supersedes scripts/build-tun2proxy-macos.sh, which rebuilt only the macOS slice and
# kept the hand-built iOS slices (0001-0003 only) byte-identical; that policy has ended.
#
#   tun2proxy root:          0001, 0003, 0005, 0006a, 0007b, 0008b (every slice)
#                            0006b (64 KB TCP window)            (macOS slice only)
#   vendored ipstack 1.0.1:  0002, 0004, 0007a, 0008a            (every slice; 0008 = tvOS cfg gates)
#
# 0006b stays off iOS and tvOS: ~128 KB of window per TCP session does not fit a network extension's memory limit, and the
# iOS bridge is a 1 MB socketpair. So there are two work trees: "ios" (without 0006b) builds both iOS and both tvOS slices,
# "macos" (with 0006b) builds the macOS slice.
#
#   scripts/build-tun2proxy-apple.sh            -> stages build/tun2proxy-apple/tun2proxy.xcframework only
#   scripts/build-tun2proxy-apple.sh --install  -> also backs up the checked-in xcframework to
#                                                  build/tun2proxy-apple/xcframework-backup-<timestamp> and replaces it
#
# Idempotent: every run starts from fresh clones (so no C objects cached under another deployment target survive)
# and never touches earlier backups. Headers are the checked-in ones; the build fails if cbindgen's output for the
# patched source differs from them (the patches do not change the C API).
#
# Needs: rustup, cbindgen, Xcode, network access for the clone and crates. Regression test for 0004 afterwards:
#   LWIPTunnelEngine/patches/0004-regression-test/run.sh build/tun2proxy-apple/ios/src/vendor/ipstack
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="$ROOT/LWIPTunnelEngine/tun2proxy.xcframework"
PATCHES="$ROOT/LWIPTunnelEngine/patches"
OUT="$ROOT/build/tun2proxy-apple"
REV=fc77ca3
IPSTACK_VERSION=1.0.1

INSTALL=0
case "${1:-}" in
    "") ;;
    --install) INSTALL=1 ;;
    *) echo "unknown argument: $1 (only --install is accepted)" >&2; exit 2 ;;
esac

# Same floors as LWIPTunnelEngine/Package.swift (iOS 15, macOS 14). Without these the objects are stamped with the
# SDK version and Xcode warns "built for newer iOS/macOS version" on every link.
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export MACOSX_DEPLOYMENT_TARGET=14.0
export TVOS_DEPLOYMENT_TARGET=17.0   # NEPacketTunnelProvider is tvOS 17+

rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin aarch64-apple-tvos aarch64-apple-tvos-sim >/dev/null

# prepare_tree <dir> <with_0006b: 0|1> lives in lib/tun2proxy-tree.sh (shared with the OpenWrt build).
source "$ROOT/scripts/lib/tun2proxy-tree.sh"

# Only the work trees and the staged output are rebuilt; earlier xcframework-backup-* directories are kept.
mkdir -p "$OUT"
rm -rf "$OUT/stage" "$OUT/tun2proxy.xcframework"

prepare_tree "$OUT/ios" 0
prepare_tree "$OUT/macos" 1

(cd "$OUT/ios/src" && cargo build --release --target aarch64-apple-ios --lib \
                   && cargo build --release --target aarch64-apple-ios-sim --lib \
                   && cargo build --release --target aarch64-apple-tvos --lib \
                   && cargo build --release --target aarch64-apple-tvos-sim --lib)
(cd "$OUT/macos/src" && cargo build --release --target aarch64-apple-darwin --lib)

# The C API must not have moved: compare cbindgen's header for the patched source with the checked-in one.
cbindgen --quiet --config "$OUT/ios/src/cbindgen.toml" -o "$OUT/cbindgen-tun2proxy.h" "$OUT/ios/src"
if ! cmp -s "$OUT/cbindgen-tun2proxy.h" "$XCF/ios-arm64/Headers/tun2proxy.h"; then
    echo "cbindgen header differs from $XCF/ios-arm64/Headers/tun2proxy.h:" >&2
    diff "$XCF/ios-arm64/Headers/tun2proxy.h" "$OUT/cbindgen-tun2proxy.h" >&2 || true
    exit 1
fi

# One directory per slice so every library keeps the name libtun2proxy.a
# (xcframework slices are named after the file passed in).
STAGE="$OUT/stage"
mkdir -p "$STAGE/ios-arm64" "$STAGE/ios-arm64-simulator" "$STAGE/macos-arm64" "$STAGE/tvos-arm64" "$STAGE/tvos-arm64-simulator"
cp "$OUT/ios/src/target/aarch64-apple-ios/release/libtun2proxy.a" "$STAGE/ios-arm64/"
cp "$OUT/ios/src/target/aarch64-apple-ios-sim/release/libtun2proxy.a" "$STAGE/ios-arm64-simulator/"
cp "$OUT/macos/src/target/aarch64-apple-darwin/release/libtun2proxy.a" "$STAGE/macos-arm64/"
cp "$OUT/ios/src/target/aarch64-apple-tvos/release/libtun2proxy.a" "$STAGE/tvos-arm64/"
cp "$OUT/ios/src/target/aarch64-apple-tvos-sim/release/libtun2proxy.a" "$STAGE/tvos-arm64-simulator/"
cp -R "$XCF/ios-arm64/Headers" "$STAGE/Headers"

xcodebuild -create-xcframework \
    -library "$STAGE/ios-arm64/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/ios-arm64-simulator/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/macos-arm64/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/tvos-arm64/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/tvos-arm64-simulator/libtun2proxy.a" -headers "$STAGE/Headers" \
    -output "$OUT/tun2proxy.xcframework" >/dev/null

echo "Staged $OUT/tun2proxy.xcframework:"
shasum "$OUT"/tun2proxy.xcframework/*/libtun2proxy.a

if [ "$INSTALL" = 1 ]; then
    BACKUP="$OUT/xcframework-backup-$(date +%Y%m%d-%H%M%S)"
    cp -R "$XCF" "$BACKUP"
    rm -rf "$XCF"
    cp -R "$OUT/tun2proxy.xcframework" "$XCF"
    echo "Installed into $XCF (previous copy: $BACKUP)"
fi
