#!/bin/bash
# Prepares vendor/tun2proxy: tun2proxy @ fc77ca3 with the local patches in
# LWIPTunnelEngine/patches (0001-0007b; the Apple builds apply them via
# scripts/build-tun2proxy-apple.sh), with ipstack 1.0.1 vendored inside it.
# Cargo.toml depends on it by path. Idempotent: re-running rebuilds the checkout.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHES="$HERE/../LWIPTunnelEngine/patches"
DEST="$HERE/vendor/tun2proxy"
REV=fc77ca3
IPSTACK_VERSION=1.0.1

rm -rf "$DEST"
mkdir -p "$HERE/vendor"
git clone -q https://github.com/tun2proxy/tun2proxy "$DEST"
cd "$DEST"
git checkout -q "$REV"

git apply "$PATCHES/0001-udp-no-connect-eisconn.patch"
git apply "$PATCHES/0003-virtual-dns-long-mapping-timeout.patch"
# 0005 (Windows client only so far): AAAA and other non-A queries get NODATA instead of an A record, which Windows'
# getaddrinfo rejects (every hostname lookup failed through the tunnel). Found in the Tiny11 ARM64 VM test.
patch -s -p1 < "$PATCHES/0005-virtual-dns-nodata-for-non-a.patch"
# 0006a (all platforms): TCP_NODELAY on the proxy connection, 5 s idle limit on virtual-DNS sessions (they held
# session slots for the full UDP timeout), 300 s DNS TTL.
patch -s -p1 < "$PATCHES/0006a-engine-latency.patch"
# 0006b (macOS and Windows, not iOS): 64 KB TCP window per flow instead of 16 KB.
patch -s -p1 < "$PATCHES/0006b-tcp-window-64k.patch"
# 0007b (all platforms): lock-free traffic_status_update when no traffic-status callback is registered.
patch -s -p1 < "$PATCHES/0007b-traffic-status-fastpath.patch"

cp "$PATCHES/tun2proxy-Cargo.lock" Cargo.lock
cargo fetch >/dev/null
mkdir -p vendor
cp -R "$(ls -d "$HOME"/.cargo/registry/src/*/ipstack-$IPSTACK_VERSION | head -1)" vendor/ipstack
(cd vendor/ipstack && patch -s -p1 < "$PATCHES/0002-ipstack-upload-backpressure.patch")
(cd vendor/ipstack && patch -s -p1 < "$PATCHES/0004-ipstack-nonfatal-device-io.patch")
# 0007a (all platforms): per-packet log strings in ipstack's TCP paths are built only when that log level is enabled.
(cd vendor/ipstack && patch -s -p1 < "$PATCHES/0007a-ipstack-lazy-trace.patch")
# Windows only: ipstack's build.rs copies wintun.dll next to its *examples* by running `cargo metadata` for its
# `wintun` dev-dependency, which fails when ipstack is a path dependency of another crate. The library does not use
# it (we ship our own signed wintun.dll), so neutralise it. No effect on the Apple builds, which don't use this copy.
printf '// Replaced by NetBridgeWindows/patch-deps.sh: only copied wintun.dll for ipstack examples.\nfn main() {}\n' > vendor/ipstack/build.rs
# The [patch] that points ipstack at vendor/ipstack lives in NetBridgeWindows/Cargo.toml:
# cargo only honours [patch] in the workspace root, not in a path dependency.

# Seed our lock from the pinned tun2proxy lock the first time, so every crate the
# engine shares with the Apple builds resolves to the same version.
if [ ! -f "$HERE/Cargo.lock" ]; then
    cp "$PATCHES/tun2proxy-Cargo.lock" "$HERE/Cargo.lock"
fi
echo "vendor/tun2proxy ready ($REV + patches 0001-0007b)"
