#!/bin/sh
# Installs (or upgrades) the NetBridge router-client package on an OpenWrt router over SSH. No scp/sftp needed (dropbear
# on OpenWrt usually has no sftp-server): the tarball is streamed through ssh.
#   - refuses a package whose CPU architecture doesn't match the router's, and checks the engine actually runs there
#     before installing anything
#   - unpacks into a staging dir first, so a failed transfer changes nothing
#   - never overwrites an existing /etc/config/netbridge
#   - replaces each file by rename, which works even while the engine binary is running ("text file busy")
#
#   NetBridgeOpenWrt/install.sh ROUTER_IP [path/to/netbridge-openwrt-<arch>.tar.gz]     (user: root)
set -eu
# extra ssh options, e.g. a shared connection from setup-router.sh (one password prompt for everything)
NB_SSH_OPTS="${NB_SSH_OPTS:-}"
ROUTER="${1:?usage: install.sh ROUTER_IP [package.tar.gz]}"
PKG="${2:-$(dirname "$0")/../build/netbridge-openwrt-aarch64.tar.gz}"
[ -f "$PKG" ] || { echo "package not found: $PKG (build it: scripts/build-openwrt-package.sh)" >&2; exit 1; }

# The ELF header of the packaged engine says which CPU it is for: e_machine (bytes 18-19) and, for MIPS, the byte
# order (EI_DATA, byte 5: 01 = little-endian, as on the GL-SFT1200). uname -m says "mips" for both byte orders, so the
# final word is running the engine on the router before anything is installed (below).
hdr=$(tar -xOzf "$PKG" ./usr/bin/tun2proxy-bin 2>/dev/null | od -An -tx1 -N20 | tr -d ' \n')   # od stops early: tar's broken pipe is expected
machine=$(echo "$hdr" | cut -c37-40); eidata=$(echo "$hdr" | cut -c11-12)
case "$machine" in
    b700) pkg_arch=aarch64 ;;
    3e00) pkg_arch=x86_64 ;;
    0800) [ "$eidata" = 01 ] && pkg_arch=mips || { echo "big-endian MIPS packages are not built" >&2; exit 1; } ;;
    *) echo "cannot tell the package's architecture (e_machine=$machine)" >&2; exit 1 ;;
esac
router_arch=$(ssh $NB_SSH_OPTS "root@$ROUTER" uname -m)
[ "$router_arch" = "$pkg_arch" ] || { echo "architecture mismatch: package is $pkg_arch, router is $router_arch" >&2; exit 1; }

ssh $NB_SSH_OPTS "root@$ROUTER" 'rm -rf /tmp/nb-install && mkdir -p /tmp/nb-install && tar xzf - -C /tmp/nb-install' < "$PKG"
ssh $NB_SSH_OPTS "root@$ROUTER" 'sh -s' <<'REMOTE'
set -e
cd /tmp/nb-install
# the real compatibility check: the engine must run here (CPU, byte order, float ABI) before anything is installed
if ! ./usr/bin/tun2proxy-bin --version >/dev/null 2>&1; then
    echo "ERROR: this package's engine does not run on this router; nothing was installed" >&2
    rm -rf /tmp/nb-install; exit 1
fi
if [ -e /etc/config/netbridge ]; then rm -f ./etc/config/netbridge; echo "kept your existing /etc/config/netbridge"; fi
find . -type f | while read -r f; do
    dst="/${f#./}"
    mkdir -p "$(dirname "$dst")"
    cp -p "$f" "$dst.nbnew"
    mv -f "$dst.nbnew" "$dst"
done
chmod 600 /etc/config/netbridge
rm -rf /tmp/nb-install
/etc/init.d/netbridge enable
/etc/init.d/netbridge-guard enable
if /etc/init.d/netbridge running >/dev/null 2>&1; then
    /etc/init.d/netbridge restart && echo "restarted the running service with the new files"
fi
echo installed
REMOTE
[ -n "${NB_QUIET_NEXT:-}" ] || cat <<MSG

Installed ($pkg_arch). Next, on the router:
  netbridge setup <phone-ip> <port> <username> <password>     # writes the config, enables and starts it
  netbridge status
MSG
