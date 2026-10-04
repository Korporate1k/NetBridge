#!/bin/bash
# Builds the NetBridge router-client package: a tarball that unpacks onto an OpenWrt router (tar xzf - -C /).
#
#   scripts/build-openwrt-package.sh                                   -> build/netbridge-openwrt-aarch64.tar.gz
#   TARGET=x86_64-unknown-linux-musl scripts/build-openwrt-package.sh  -> build/netbridge-openwrt-x86_64.tar.gz
#   TARGET=mipsel-unknown-linux-musl scripts/build-openwrt-package.sh  -> build/netbridge-openwrt-mipsel.tar.gz (GL-SFT1200;
#                                         nightly + rust-src and zig 0.14.1, see build-tun2proxy-openwrt.sh)
#   SKIP_BUILD=1 ...   reuse binaries already in build/ (tun2proxy-bin via build-tun2proxy-openwrt.sh, nb-probe via cargo)
#
# Contents: NetBridgeOpenWrt/files/ (init script, config, ctl, netbridge CLI) + usr/bin/tun2proxy-bin + usr/bin/nb-probe.
# Needs what build-tun2proxy-openwrt.sh needs (cargo-zigbuild + zig).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${TARGET:-aarch64-unknown-linux-musl}"
ARCH="${TARGET%%-*}"
VENV_BIN="$ROOT/build/openwrt-tools/venv/bin"; [ -d "$VENV_BIN" ] && export PATH="$VENV_BIN:$PATH"

ENGINE="$ROOT/build/tun2proxy-openwrt/tun2proxy-bin"
[ "$TARGET" = aarch64-unknown-linux-musl ] || ENGINE="$ENGINE-$TARGET"
PROBE="$ROOT/NetBridgeOpenWrt/nb-probe/target/$TARGET/release/nb-probe"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
    TARGET="$TARGET" "$ROOT/scripts/build-tun2proxy-openwrt.sh"
    case "$TARGET" in
        mips*)  # tier 3: std from source on nightly, linked with zig 0.14.1
            (cd "$ROOT/NetBridgeOpenWrt/nb-probe" && PATH="$ROOT/build/openwrt-tools/venv-zig0141/bin:$PATH" \
                cargo +nightly zigbuild --release --target "$TARGET" -Zbuild-std=std,panic_abort) ;;
        *) (cd "$ROOT/NetBridgeOpenWrt/nb-probe" && rustup target add "$TARGET" >/dev/null && cargo zigbuild --release --target "$TARGET") ;;
    esac
fi
[ -f "$ENGINE" ] || { echo "missing $ENGINE" >&2; exit 1; }
[ -f "$PROBE" ]  || { echo "missing $PROBE" >&2; exit 1; }

STAGE="$ROOT/build/netbridge-openwrt/$ARCH/root"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$ROOT/NetBridgeOpenWrt/files/." "$STAGE/"
install -m 0755 "$ENGINE" "$STAGE/usr/bin/tun2proxy-bin"
install -m 0755 "$PROBE"  "$STAGE/usr/bin/nb-probe"
chmod 0755 "$STAGE/etc/init.d/netbridge" "$STAGE/etc/init.d/netbridge-guard" "$STAGE/usr/bin/netbridge" \
    "$STAGE/usr/libexec/netbridge/ctl" "$STAGE/usr/libexec/netbridge/engine"
chmod 0600 "$STAGE/etc/config/netbridge"   # it holds the proxy password once filled in

OUT="$ROOT/build/netbridge-openwrt-$ARCH.tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --numeric-owner -czf "$OUT" -C "$STAGE" .
echo "package: $OUT ($(du -h "$OUT" | cut -f1))"
tar -tvzf "$OUT" | awk '{print $1, $5, $9}' | grep -v '/$'
