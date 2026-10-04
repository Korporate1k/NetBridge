#!/bin/bash
# End-to-end test of NetBridgeOpenWrt/setup-router.sh against the official OpenWrt rootfs container acting as the router.
# The script runs from a second container that shares the router's network namespace (so it reaches the router's SSH on
# 127.0.0.1:22 without depending on how OpenWrt's netifd treats the container's eth0); that container also runs the
# stand-in proxy (127.0.0.1:1080). Key-based SSH with a throwaway key. Nothing is installed on the docker host.
#   ./setup-router-test.sh DIR_WITH_NetBridgeOpenWrt PACKAGE socks5_test_server.py
set -u
SRC="${1:?dir containing NetBridgeOpenWrt/}"; PKG="${2:?package}"; SERVER="${3:?socks5_test_server.py}"
TAG="${OWRT_TAG:-x86-64-24.10.8}"; IMG="openwrt/rootfs:$TAG"; A=nbsetup; B=nbsetupc
PASS=0; FAILN=0
check() { if [ "$2" = ok ]; then echo "PASS - $1 ${3:+| $3}"; PASS=$((PASS+1)); else echo "FAIL - $1 ${3:+| $3}"; FAILN=$((FAILN+1)); fi; }
x() { docker exec "$A" sh -c "$1" 2>&1; }          # on the router
c() { docker exec "$B" bash -c "$1" 2>&1; }        # on the "Mac" (runs setup-router.sh)
had_img=$(docker images -q "$IMG") || had_img=keep
T=$(mktemp -d)
cleanup() { docker rm -f "$B" "$A" nbsetup-prep >/dev/null 2>&1; docker rmi nbsetup-runner:tmp >/dev/null 2>&1; [ -z "$had_img" ] && docker rmi "$IMG" >/dev/null 2>&1; rm -rf "$T"; echo "cleanup done"; }
trap cleanup EXIT
docker rm -f "$A" "$B" >/dev/null 2>&1
docker pull -q "$IMG" >/dev/null || exit 1
docker run -d --name "$A" --cap-add NET_ADMIN --device /dev/net/tun "$IMG" /sbin/init >/dev/null || exit 1
for _ in $(seq 1 30); do x 'ubus list service' | grep -q '^service' && break; sleep 1; done
# the runner shares the router's network namespace, which has no internet; so prepare its image first, on the normal
# docker network (a throwaway image, removed by cleanup)
RIMG=nbsetup-runner:tmp
docker rm -f nbsetup-prep >/dev/null 2>&1
docker run --name nbsetup-prep python:3-alpine sh -c 'apk add -q bash openssh-client >/dev/null 2>&1 && echo ok' | grep -q ok \
    || { docker rm -f nbsetup-prep >/dev/null 2>&1; echo "cannot install bash/ssh for the runner"; exit 1; }
docker commit nbsetup-prep "$RIMG" >/dev/null && docker rm -f nbsetup-prep >/dev/null 2>&1
docker run -d --name "$B" --network "container:$A" "$RIMG" sleep 3600 >/dev/null || exit 1
c 'mkdir -p /w/NetBridgeOpenWrt' >/dev/null
docker cp "$SRC/NetBridgeOpenWrt/setup-router.sh" "$B:/w/NetBridgeOpenWrt/"; docker cp "$SRC/NetBridgeOpenWrt/install.sh" "$B:/w/NetBridgeOpenWrt/"
docker cp "$PKG" "$B:/w/pkg.tar.gz"; docker cp "$SERVER" "$B:/w/s.py"
c 'nohup python /w/s.py --bind 127.0.0.1 --port 1080 --user nb --password nbpass >/w/proxy.log 2>&1 &' >/dev/null
ssh-keygen -q -t ed25519 -N "" -f "$T/key"
docker cp "$T/key.pub" "$A:/etc/dropbear/authorized_keys"; x 'chmod 600 /etc/dropbear/authorized_keys' >/dev/null
docker cp "$T/key" "$B:/w/key"; c 'chmod 600 /w/key' >/dev/null
E='export NB_SSH_EXTRA="-i /w/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"'
for _ in $(seq 1 15); do c "$E; ssh \$NB_SSH_EXTRA -o BatchMode=yes -o ConnectTimeout=3 root@127.0.0.1 true && echo up" | grep -q up && break; sleep 1; done
c "$E; ssh \$NB_SSH_EXTRA -o BatchMode=yes root@127.0.0.1 true && echo up" | grep -q up && r=ok || r=bad; check "SSH into the router (dropbear, key auth)" $r
[ "$r" = ok ] || { echo "== precondition failed: cannot SSH into the test router; nothing below would mean anything"; exit 1; }
x 'uci show dhcp | sort > /tmp/dhcp.before; uci show firewall | sort > /tmp/firewall.before' >/dev/null
S="$E; cd /w && NetBridgeOpenWrt/setup-router.sh 127.0.0.1"

echo "== 1. fresh install + configure (non-interactive)"
out=$(c "export NB_PASS=nbpass; $S --yes --phone 127.0.0.1 --port 1080 --user nb --package /w/pkg.tar.gz </dev/null; echo rc=\$?")
echo "$out" | grep -E "^(== |Firmware|CPU|NetBridge is running|ERROR)" | sed 's/^/   | /'
echo "$out" | grep -q "^rc=0" && echo "$out" | grep -q "NetBridge is running" && r=ok || r=bad; check "setup ends healthy (exit 0)" $r "$(echo "$out" | grep '^rc=')"
echo "$out" | grep -q "CPU: x86_64 -> package x86_64" && r=ok || r=bad; check "CPU detected and the right package chosen" $r
[ "$(x 'for k in server_host server_port username password enabled policy; do uci -q get netbridge.main.$k; done' | tr '\n' ' ')" = "127.0.0.1 1080 nb nbpass 1 block " ] && r=ok || r=bad
check "settings written to /etc/config/netbridge" $r
x '/usr/libexec/netbridge/ctl status' | grep -q "state=healthy" && r=ok || r=bad; check "router watchdog reports healthy" $r

echo "== 2. re-run (upgrade): keeps the saved settings and password"
out=$(c "$S --yes --package /w/pkg.tar.gz </dev/null; echo rc=\$?")
echo "$out" | grep -q "^rc=0" && echo "$out" | grep -q "NetBridge is running" && r=ok || r=bad; check "re-run with saved settings ends healthy" $r
echo "$out" | grep -q "kept your existing /etc/config/netbridge" && r=ok || r=bad; check "install kept the existing config" $r
[ "$(x 'uci -q get netbridge.main.password')" = nbpass ] && r=ok || r=bad; check "saved password kept" $r

echo "== 3. wrong password is explained"
out=$(c "export NB_PASS=wrong; $S --yes --package /w/pkg.tar.gz </dev/null; echo rc=\$?")
! echo "$out" | grep -q "^rc=0" && echo "$out" | grep -q "refused the username/password" && r=ok || r=bad
check "wrong password -> clear error, non-zero exit" $r "$(echo "$out" | grep ERROR | cut -c1-90)"
out=$(c "export NB_PASS=nbpass; $S --yes --package /w/pkg.tar.gz </dev/null; echo rc=\$?"); echo "$out" | grep -q "^rc=0" && r=ok || r=bad
check "fixing the password brings it back" $r

echo "== 4. uninstall"
out=$(c "$S --yes --uninstall </dev/null; echo rc=\$?")
echo "$out" | grep -q "^rc=0" && echo "$out" | grep -q "NetBridge removed" && r=ok || r=bad; check "uninstall succeeds" $r
x 'ls /etc/init.d/netbridge /usr/bin/tun2proxy-bin /usr/libexec/netbridge /etc/config/netbridge 2>/dev/null | wc -l' | grep -q '^0$' && r=ok || r=bad; check "all files and settings removed" $r
l=$(x 'ip route | grep -E "nbtun|^blackhole (0\.0\.0\.0|128\.0\.0\.0)/1|^unreachable 127\.0\.0\.1"; ip -6 route | grep -E "^(blackhole|unreachable) (::|8000::)/1 "'); [ -z "$l" ] && r=ok || r=bad
check "no routes left" $r "$(echo "$l" | tr '\n' ';')"
d=$(x 'uci show dhcp | sort > /tmp/dhcp.after; cmp -s /tmp/dhcp.after /tmp/dhcp.before && echo same'); [ "$d" = same ] && r=ok || r=bad; check "dhcp settings restored" $r
d=$(x 'uci show firewall | sort > /tmp/firewall.after; cmp -s /tmp/firewall.after /tmp/firewall.before && echo same'); [ "$d" = same ] && r=ok || r=bad; check "firewall settings restored" $r
echo "== $PASS passed, $FAILN failed"; [ "$FAILN" = 0 ]
