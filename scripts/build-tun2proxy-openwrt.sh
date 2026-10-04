#!/bin/bash
# Builds the tun2proxy binary for an OpenWrt router: a static, stripped aarch64 musl ELF (MediaTek Filogic routers such
# as the GL.iNet GL-MT3000 / GL-MT6000), with TARGET=mipsel-unknown-linux-musl a 32-bit little-endian MIPS one (GL.iNet
# GL-SFT1200: tier-3 Rust target, so nightly + -Zbuild-std, plus patch 0009 for the missing 64-bit atomics), or, with
# TARGET=x86_64-unknown-linux-musl, an x86-64 one for a Linux test box. From the same patched tree the Apple and Windows builds use. The patch list
# lives in scripts/lib/tun2proxy-tree.sh. 0006b (64 KB TCP window) is applied, as on macOS: a router has hundreds of MB
# of RAM, unlike an iOS network extension.
#
#   scripts/build-tun2proxy-openwrt.sh                                   -> build/tun2proxy-openwrt/tun2proxy-bin (aarch64)
#   TARGET=x86_64-unknown-linux-musl scripts/build-tun2proxy-openwrt.sh  -> build/tun2proxy-openwrt/tun2proxy-bin-x86_64-unknown-linux-musl
#
# Needs: rustup, cargo-zigbuild (cargo install cargo-zigbuild), and zig. zig is taken from PATH, else from the
# virtualenv  build/openwrt-tools/venv  (python3 -m venv build/openwrt-tools/venv && build/openwrt-tools/venv/bin/pip
# install ziglang). Network access for the clone and crates. Only the work tree and output are rebuilt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$ROOT/LWIPTunnelEngine/patches"
OUT="$ROOT/build/tun2proxy-openwrt"
REV=fc77ca3
IPSTACK_VERSION=1.0.1
TARGET="${TARGET:-aarch64-unknown-linux-musl}"
# The default (router) target keeps the plain name; other targets get a suffix so builds never overwrite each other.
BIN_NAME=tun2proxy-bin
[ "$TARGET" = aarch64-unknown-linux-musl ] || BIN_NAME="tun2proxy-bin-$TARGET"

VENV_BIN="$ROOT/build/openwrt-tools/venv/bin"
# MIPS needs zig 0.14.x: 0.13 ships no soft-float musl for mipsel ("unable to find or provide libc ... musleabi") and 0.16
# links its new zig-written libc pieces with unresolved internals (mem.eqlBytes, heap.SmpAllocator...). Set up with:
#   python3 -m venv build/openwrt-tools/venv-zig0141 && build/openwrt-tools/venv-zig0141/bin/pip install ziglang==0.14.1
case "$TARGET" in mips*) VENV_BIN="$ROOT/build/openwrt-tools/venv-zig0141/bin"
    [ -d "$VENV_BIN" ] || { echo "MIPS needs zig 0.14.1 in build/openwrt-tools/venv-zig0141 (see the comment above)" >&2; exit 1; } ;;
esac
[ -d "$VENV_BIN" ] && export PATH="$VENV_BIN:$PATH"
command -v cargo-zigbuild >/dev/null || { echo "cargo-zigbuild not found (cargo install cargo-zigbuild)" >&2; exit 1; }
python3 -m ziglang version >/dev/null 2>&1 || command -v zig >/dev/null || { echo "zig not found (see header)" >&2; exit 1; }

source "$ROOT/scripts/lib/tun2proxy-tree.sh"

rm -rf "$OUT/tree" "$OUT/$BIN_NAME"
case "$TARGET" in
    mips*)  # tier 3: no prebuilt std, so build it from source on nightly (rust-src); 0009 replaces std AtomicU64
        rustup component add rust-src --toolchain nightly >/dev/null
        prepare_tree "$OUT/tree" 1 1
        (cd "$OUT/tree/src" && cargo +nightly zigbuild --release --target "$TARGET" --bin tun2proxy-bin \
            -Zbuild-std=std,panic_abort)
        ;;
    *)
        rustup target add "$TARGET" >/dev/null
        prepare_tree "$OUT/tree" 1
        (cd "$OUT/tree/src" && cargo zigbuild --release --target "$TARGET" --bin tun2proxy-bin)
        ;;
esac

cp "$OUT/tree/src/target/$TARGET/release/tun2proxy-bin" "$OUT/$BIN_NAME"
# assert what we built: a static ELF for the requested CPU (a wrong or dynamically linked binary must fail the build)
info=$(file "$OUT/$BIN_NAME"); echo "$info"
case "$TARGET" in aarch64-*) want="ARM aarch64" ;; x86_64-*) want="x86-64" ;; mipsel-*) want="MIPS, MIPS32" ;; *) want="" ;; esac
case "$TARGET" in mipsel-*) case "$info" in *"32-bit LSB"*) ;; *) echo "not little-endian 32-bit: $info" >&2; exit 1 ;; esac ;; esac
case "$info" in *"$want"*"statically linked"*|*"$want"*"static-pie linked"*) ;; *) echo "unexpected binary (wanted static $want): $info" >&2; exit 1 ;; esac
ls -l "$OUT/$BIN_NAME" | awk '{print "size:", $5, "bytes"}'
shasum "$OUT/$BIN_NAME"
