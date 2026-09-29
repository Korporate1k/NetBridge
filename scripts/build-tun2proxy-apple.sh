#!/bin/bash
# Builds all three slices of LWIPTunnelEngine/tun2proxy.xcframework (ios-arm64, ios-arm64-simulator, macos-arm64)
# from source: tun2proxy @ fc77ca3 plus the local patches in LWIPTunnelEngine/patches, applied in the same order as
# NetBridgeWindows/patch-deps.sh. Supersedes scripts/build-tun2proxy-macos.sh, which rebuilt only the macOS slice and
# kept the hand-built iOS slices (0001-0003 only) byte-identical; that policy has ended.
#
#   tun2proxy root:          0001, 0003, 0005, 0006a, 0007b (every slice)
#                            0006b (64 KB TCP window)            (macOS slice only)
#   vendored ipstack 1.0.1:  0002, 0004, 0007a                   (every slice)
#
# 0006b stays off iOS: ~128 KB of window per TCP session does not fit a network extension's memory limit, and the
# iOS bridge is a 1 MB socketpair. So there are two work trees: "ios" (without 0006b) builds both iOS slices,
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
[ "${1:-}" = "--install" ] && INSTALL=1

# Same floors as LWIPTunnelEngine/Package.swift (iOS 15, macOS 14). Without these the objects are stamped with the
# SDK version and Xcode warns "built for newer iOS/macOS version" on every link.
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export MACOSX_DEPLOYMENT_TARGET=14.0

rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin >/dev/null

# prepare_tree <dir> <with_0006b: 0|1>: clone, patch and vendor one tun2proxy tree at <dir>/src.
prepare_tree() {
    local dir="$1" with_0006b="$2"
    rm -rf "$dir"
    mkdir -p "$dir"
    git clone -q https://github.com/tun2proxy/tun2proxy "$dir/src"
    (
        cd "$dir/src"
        git checkout -q "$REV"

        # tun2proxy itself.
        git apply "$PATCHES/0001-udp-no-connect-eisconn.patch"             # UDP relays: no EISCONN on Darwin
        git apply "$PATCHES/0003-virtual-dns-long-mapping-timeout.patch"   # virtual-DNS mappings live 24 h
        patch -s -p1 < "$PATCHES/0005-virtual-dns-nodata-for-non-a.patch"  # NODATA for AAAA and other non-A queries
        patch -s -p1 < "$PATCHES/0006a-engine-latency.patch"               # TCP_NODELAY, 5 s DNS sessions, 300 s TTL
        if [ "$with_0006b" = 1 ]; then
            patch -s -p1 < "$PATCHES/0006b-tcp-window-64k.patch"           # 64 KB TCP window (macOS only)
        fi
        patch -s -p1 < "$PATCHES/0007b-traffic-status-fastpath.patch"      # lock-free traffic_status_update

        # The ipstack patches, so vendor the crate and redirect the dependency.
        cp "$PATCHES/tun2proxy-Cargo.lock" Cargo.lock
        # No --locked: the saved lock records ipstack as a path dependency, so cargo
        # rewrites that one entry here. Every other version stays pinned by the lock.
        cargo fetch >/dev/null
        mkdir -p vendor
        cp -R "$(ls -d "$HOME"/.cargo/registry/src/*/ipstack-$IPSTACK_VERSION | head -1)" vendor/ipstack
        (cd vendor/ipstack && patch -s -p1 < "$PATCHES/0002-ipstack-upload-backpressure.patch")  # upload backpressure
        (cd vendor/ipstack && patch -s -p1 < "$PATCHES/0004-ipstack-nonfatal-device-io.patch")   # failed device I/O not fatal
        (cd vendor/ipstack && patch -s -p1 < "$PATCHES/0007a-ipstack-lazy-trace.patch")          # no eager per-packet log strings
        printf '\n[patch.crates-io]\nipstack = { path = "vendor/ipstack" }\n' >> Cargo.toml
    )
}

# Only the work trees and the staged output are rebuilt; earlier xcframework-backup-* directories are kept.
mkdir -p "$OUT"
rm -rf "$OUT/stage" "$OUT/tun2proxy.xcframework"

prepare_tree "$OUT/ios" 0
prepare_tree "$OUT/macos" 1

(cd "$OUT/ios/src" && cargo build --release --target aarch64-apple-ios --lib \
                   && cargo build --release --target aarch64-apple-ios-sim --lib)
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
mkdir -p "$STAGE/ios-arm64" "$STAGE/ios-arm64-simulator" "$STAGE/macos-arm64"
cp "$OUT/ios/src/target/aarch64-apple-ios/release/libtun2proxy.a" "$STAGE/ios-arm64/"
cp "$OUT/ios/src/target/aarch64-apple-ios-sim/release/libtun2proxy.a" "$STAGE/ios-arm64-simulator/"
cp "$OUT/macos/src/target/aarch64-apple-darwin/release/libtun2proxy.a" "$STAGE/macos-arm64/"
cp -R "$XCF/ios-arm64/Headers" "$STAGE/Headers"

xcodebuild -create-xcframework \
    -library "$STAGE/ios-arm64/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/ios-arm64-simulator/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/macos-arm64/libtun2proxy.a" -headers "$STAGE/Headers" \
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
