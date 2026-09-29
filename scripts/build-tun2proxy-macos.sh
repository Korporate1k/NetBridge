#!/bin/bash
# SUPERSEDED (2026-09-26) by scripts/build-tun2proxy-apple.sh, which builds all three slices with the full patch set
# (0001-0007b). Kept for history; running it would rebuild only the macOS slice with patches 0001-0004.
#
# Adds a macOS (arm64) slice to LWIPTunnelEngine/tun2proxy.xcframework.
#
# Rebuilds tun2proxy @ fc77ca3 with the same three local patches the iOS slices
# use (LWIPTunnelEngine/patches/0001-0003) plus 0004 (macOS slice only — the iOS
# slices are deliberately left byte-identical; regression test in
# patches/0004-regression-test/run.sh), then re-creates the xcframework from the
# EXISTING ios-arm64 / ios-arm64-simulator libraries (untouched, byte-identical)
# plus the new macOS library. Idempotent: re-running replaces only the macOS slice.
#
# Needs: rustup target aarch64-apple-darwin, cbindgen, network access for crates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="$ROOT/LWIPTunnelEngine/tun2proxy.xcframework"
PATCHES="$ROOT/LWIPTunnelEngine/patches"
WORK="$ROOT/build/tun2proxy-macos"
REV=fc77ca3
IPSTACK_VERSION=1.0.1

rustup target add aarch64-apple-darwin >/dev/null

rm -rf "$WORK"
mkdir -p "$WORK"
git clone -q https://github.com/tun2proxy/tun2proxy "$WORK/src"
cd "$WORK/src"
git checkout -q "$REV"

# 0001 + 0003 patch tun2proxy itself.
git apply "$PATCHES/0001-udp-no-connect-eisconn.patch"
git apply "$PATCHES/0003-virtual-dns-long-mapping-timeout.patch"

# 0002 patches the ipstack crate, so vendor it and redirect the dependency.
cp "$PATCHES/tun2proxy-Cargo.lock" Cargo.lock
# No --locked: the saved lock records ipstack as a path dependency, so cargo
# rewrites that one entry here. Every other version stays pinned by the lock.
cargo fetch >/dev/null
mkdir -p vendor
cp -R "$(ls -d "$HOME"/.cargo/registry/src/*/ipstack-$IPSTACK_VERSION | head -1)" vendor/ipstack
(cd vendor/ipstack && patch -s -p1 < "$PATCHES/0002-ipstack-upload-backpressure.patch")
# 0004: a failed device write/read no longer ends the ip stack (and, via tun2proxy's forced exit, the whole VPN).
(cd vendor/ipstack && patch -s -p1 < "$PATCHES/0004-ipstack-nonfatal-device-io.patch")
printf '\n[patch.crates-io]\nipstack = { path = "vendor/ipstack" }\n' >> Cargo.toml

cargo build --release --target aarch64-apple-darwin --lib
MAC_LIB="$PWD/target/aarch64-apple-darwin/release/libtun2proxy.a"

# Reuse the iOS slices exactly as they are now.
STAGE="$WORK/stage"
mkdir -p "$STAGE/ios-arm64" "$STAGE/ios-arm64-simulator" "$STAGE/macos-arm64"
# One directory per slice so every library keeps the name libtun2proxy.a
# (xcframework slices are named after the file passed in).
cp "$XCF/ios-arm64/libtun2proxy.a" "$STAGE/ios-arm64/"
cp "$XCF/ios-arm64-simulator/libtun2proxy.a" "$STAGE/ios-arm64-simulator/"
cp "$MAC_LIB" "$STAGE/macos-arm64/"
cp -R "$XCF/ios-arm64/Headers" "$STAGE/Headers"

xcodebuild -create-xcframework \
    -library "$STAGE/ios-arm64/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/ios-arm64-simulator/libtun2proxy.a" -headers "$STAGE/Headers" \
    -library "$STAGE/macos-arm64/libtun2proxy.a" -headers "$STAGE/Headers" \
    -output "$WORK/tun2proxy.xcframework"

rm -rf "$XCF"
mv "$WORK/tun2proxy.xcframework" "$XCF"
echo "Updated $XCF:"
ls "$XCF"
