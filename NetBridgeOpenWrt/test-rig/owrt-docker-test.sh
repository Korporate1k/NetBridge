#!/bin/bash
# Tests the OpenWrt-specific parts (procd init script, UCI config, dnsmasq + fw4 wiring, stop/restore) inside the
# official OpenWrt x86-64 rootfs container. Run on a Linux box that has docker (no root needed if you are in the
# docker group). The container has its own network namespace; a throwaway SOCKS5 test server shares it (127.0.0.1:1080),
# so the host's firewall and routes are not involved. Everything is removed on exit.
#
#   ./owrt-docker-test.sh netbridge-openwrt-x86_64.tar.gz socks5_test_server.py     [OWRT_TAG=x86-64-24.10.8]
set -u
PKG="${1:?package tarball}"; SERVER="${2:?socks5_test_server.py}"
TAG="${OWRT_TAG:-x86-64-24.10.8}"; IMG="openwrt/rootfs:$TAG"; PYIMG="python:3-alpine"
A=nbowrt; B=nbproxy
EXTRA="${EXTRA_DOCKER_ARGS:-}"
PASS=0; FAILN=0; SKIPN=0
check() { if [ "$2" = ok ]; then echo "PASS - $1 ${3:+| $3}"; PASS=$((PASS+1)); else echo "FAIL - $1 ${3:+| $3}"; FAILN=$((FAILN+1)); fi; }
x() { docker exec "$A" sh -c "$1" 2>&1; }
# if docker cannot answer, assume the images were already there so cleanup never removes something of yours
had_img=$(docker images -q "$IMG") || had_img=keep; had_py=$(docker images -q "$PYIMG") || had_py=keep
SVC=$(mktemp)
cleanup() {
    docker rm -f "$B" "$A" >/dev/null 2>&1
    rm -f "$SVC"
    [ -z "$had_img" ] && docker rmi "$IMG" >/dev/null 2>&1
    [ -z "$had_py" ] && docker rmi "$PYIMG" >/dev/null 2>&1
    echo "cleanup done (containers removed; images pulled by this test removed)"
}
trap cleanup EXIT
docker rm -f "$A" "$B" >/dev/null 2>&1

echo "== start OpenWrt $TAG"
docker pull -q "$IMG" >/dev/null || { echo "cannot pull $IMG"; exit 1; }
docker run -d --name "$A" --cap-add NET_ADMIN --device /dev/net/tun $EXTRA "$IMG" /sbin/init >/dev/null || exit 1
for _ in $(seq 1 30); do x 'ubus list service' | grep -q '^service' && break; sleep 1; done
x 'ubus list service' | grep -q '^service' && r=ok || r=bad; check "procd + ubus are running in the container" $r
[ "$r" = ok ] || { docker logs "$A" 2>&1 | tail -15; echo "== $PASS passed, $FAILN failed"; exit 1; }

echo "== start the stand-in proxy (shares the container's network namespace)"
docker pull -q "$PYIMG" >/dev/null || { echo "cannot pull $PYIMG"; exit 1; }
docker run -d --name "$B" --network "container:$A" -v "$(cd "$(dirname "$SERVER")" && pwd)/$(basename "$SERVER"):/srv/s.py:ro" "$PYIMG" \
    python /srv/s.py --bind 127.0.0.1 --port 1080 --user nb --password nbpass --host-map example.test=127.0.0.1 >/dev/null || exit 1
sleep 2

x 'pidof dnsmasq' | grep -q '[0-9]' && echo "(dnsmasq was running before install)" || echo "(dnsmasq was NOT running before install)"
echo "== install the package"
# a user who already has their own upstream DNS servers, one of them 8.8.8.8 (it must survive a stop)
x "uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'; uci add_list dhcp.@dnsmasq[0].server='9.9.9.9'; uci set dhcp.@dnsmasq[0].max_ttl='600'; uci commit dhcp" >/dev/null
# configs are compared semantically: `uci show` gives one line per option (a list's values in order); sorting ignores only
# where an option sits inside its section, which uci changes when a list is removed and re-added
x 'uci show dhcp | sort > /tmp/dhcp.before; uci show firewall | sort > /tmp/firewall.before; uci show network | sort > /tmp/network.before
   [ -s /tmp/dhcp.before ] && [ -s /tmp/firewall.before ] && [ -s /tmp/network.before ] && echo snapshot-ok' | grep -q snapshot-ok && r=ok || r=bad
check "snapshot original dhcp/firewall/network config (non-empty), user DNS = 8.8.8.8 9.9.9.9, max_ttl=600" $r
docker cp "$PKG" "$A:/tmp/p.tgz" && x 'tar xzf /tmp/p.tgz -C / && echo extracted' | grep -q extracted && r=ok || r=bad
check "package unpacks onto OpenWrt" $r
x 'ls -l /etc/init.d/netbridge /usr/bin/tun2proxy-bin /usr/bin/nb-probe /usr/libexec/netbridge/ctl >/dev/null && /usr/bin/tun2proxy-bin --version' | grep -q "tun2proxy 0.8.3" && r=ok || r=bad
check "engine binary runs on OpenWrt's musl userland" $r "$(x '/usr/bin/tun2proxy-bin --version' | head -1)"
x '/etc/init.d/netbridge start; echo "rc=$?"' | tail -1 | grep -q "rc=0" && r=ok || r=bad
check "disabled by default: start does nothing and succeeds" $r
x 'pgrep -f "[t]un2proxy-bin" >/dev/null && echo running || echo none' | grep -q none && r=ok || r=bad; check "no engine process while disabled" $r

echo "== enable with netbridge setup"
x 'netbridge setup 127.0.0.1 1080 nb nbpass >/tmp/setup.out 2>&1; echo done' >/dev/null
for _ in $(seq 1 25); do st=$(x '/usr/libexec/netbridge/ctl status' | sed -n 's/^state=//p'); [ "$st" = healthy ] && break; sleep 1; done
[ "$st" = healthy ] && r=ok || r=bad; check "watchdog reaches state=healthy against the proxy" $r "state=$st $(x '/usr/libexec/netbridge/ctl status' | sed -n 's/^udp=/udp=/p')"
x 'ubus call service list "{\"name\":\"netbridge\"}"' > "$SVC"
grep -q '"engine"' "$SVC" && grep -q '"watchdog"' "$SVC" && r=ok || r=bad; check "procd supervises both instances (engine, watchdog)" $r
x 'command -v pgrep >/dev/null && pgrep -f "[t]un2proxy-bin" >/dev/null && echo found' | grep -q found && r=ok || r=bad; check "pgrep finds the running engine (positive control for the stop checks)" $r
x 'ip link show nbtun >/dev/null 2>&1 && echo up' | grep -q up && r=ok || r=bad; check "engine created the nbtun device" $r
x 'ip route | grep -q "^0.0.0.0/1 dev nbtun" && ip route | grep -q "^128.0.0.0/1 dev nbtun" && echo ok' | grep -q ok && r=ok || r=bad; check "tun routes (0/1, 128/1) installed" $r "$(x 'ip route | grep -E "nbtun|blackhole" | tr "\n" ";"')"
x 'ip route | grep -q "^127.0.0.1 " && echo pinned' | grep -q pinned && r=ok || r=bad; check "proxy address pinned (busybox ip has no 'route get': default-route fallback)" $r "$(x 'ip route | grep "^127.0.0.1"')"
x 'ip -6 route | grep -q "^unreachable ::/1" && echo v6' | grep -q v6 && r=ok || r=bad; check "IPv6 guard (unreachable) installed (busybox ip -6)" $r
x 'ip route | grep -q "^unreachable 127.0.0.1 " && echo ok' | grep -q ok && r=ok || r=bad; check "proxy safety route (unreachable /32 under the pin) installed (busybox ip)" $r
x 'ip route | grep -q "^blackhole 0.0.0.0/1"; echo $?' | grep -q "^0" && r=ok || r=bad; check "block policy: blackhole safety net installed" $r
[ "$(x 'uci get dhcp.@dnsmasq[0].server; uci get dhcp.@dnsmasq[0].noresolv' | tr '\n' ' ')" = "8.8.8.8 1 " ] && r=ok || r=bad
check "dnsmasq upstream is ONLY the virtual-DNS address (user servers set aside), no-resolv" $r "$(x 'uci get dhcp.@dnsmasq[0].server' | tr '\n' ' ')"
# NOTE: procd cannot create dnsmasq's cgroup in an unprivileged container ("failed adding instance cgroup"), and dnsmasq
# was not running before the install either, so we test the config the init script generated and run dnsmasq by hand.
conf=$(x 'ls /var/etc/dnsmasq.conf.* 2>/dev/null | head -1')
x "grep -q '^server=8.8.8.8' $conf && grep -q '^no-resolv' $conf && echo ok" | grep -q ok && r=ok || r=bad
check "dnsmasq's generated config has server=8.8.8.8 and no-resolv" $r "$conf"
# newer dnsmasq init: caps via UCI into the generated config; older (18.06): a file in dnsmasq's conf-dir
if x 'grep -q "\"max_ttl\"" /etc/init.d/dnsmasq && echo uci' | grep -q uci; then ttlmode=uci
    x "grep -q '^max-ttl=30' $conf && grep -q '^max-cache-ttl=30' $conf && echo ok" | grep -q ok && r=ok || r=bad
else ttlmode=confdir
    x "grep -q '^conf-dir=/tmp/dnsmasq.d' $conf && grep -q '^max-ttl=30' /tmp/dnsmasq.d/netbridge-ttl.conf && grep -q '^max-cache-ttl=30' /tmp/dnsmasq.d/netbridge-ttl.conf && echo ok" | grep -q ok && r=ok || r=bad
fi
check "dnsmasq caps TTLs at 30 s (via $ttlmode)" $r
x "dnsmasq -C $conf -k >/tmp/dnsmasq.out 2>&1 &"; sleep 2
x 'pidof dnsmasq' | grep -q '[0-9]' && r=ok || r=bad; check "dnsmasq runs with that generated config" $r "$(x 'tail -2 /tmp/dnsmasq.out' | tr '\n' '|')"
x 'uci get firewall.netbridge_zone.name; uci get firewall.netbridge_fwd.dest' | tr '\n' ' ' | grep -q "nbtun nbtun" && r=ok || r=bad; check "firewall zone + lan->nbtun forwarding configured" $r
# fw4 (nftables, 21.02+) or fw3 (iptables, 18.06): both can print the rules they would install
fw=$(x 'command -v fw4 >/dev/null && echo fw4 || echo fw3')
if [ "$fw" = fw3 ] && [ "$(x 'fw3 print 2>/dev/null | wc -l')" -eq 0 ]; then
    # fw3 can't resolve the container's network devices, so it prints no rules at all (not even the default lan zone):
    # not a verdict on our zone. Reported as a skip, never as a pass.
    echo "SKIP - fw3 prints no rules at all in this container (not even the lan zone): nbtun rendering can't be checked here"; SKIPN=$((SKIPN+1))
else
    x "$fw print 2>/dev/null | grep -c nbtun" | grep -q '^[1-9]' && r=ok || r=bad; check "$fw renders rules for the nbtun zone" $r "$(x "$fw print 2>/dev/null | grep -c nbtun") lines"
fi
# A real router always has LAN/WAN IPv4 addresses for its own traffic to use as source. On 18.06, netifd strips the
# container's eth0 address, which would leave only 127.0.0.1 (a reply to that is dropped as invalid), so give it one.
x 'ip -4 addr show | grep -v " 127\." | grep -q "inet " || ip addr add 192.0.2.1/32 dev lo' >/dev/null
ans=$(x 'nslookup example.com 127.0.0.1 2>&1 | grep -E "^Address" | tail -1')
echo "$ans" | grep -qE "198\.1[89]\." && r=ok || r=bad; check "router DNS (dnsmasq) answers with a virtual 198.18/15 address" $r "$ans"
x 'pkill dnsmasq; true' >/dev/null
x 'netbridge status' | grep -q "state=healthy" && r=ok || r=bad; check "'netbridge status' reports healthy" $r
x 'netbridge probe' | grep -q "state=answering udp=yes" && r=ok || r=bad; check "'netbridge probe' uses the configured server + credentials" $r

echo "== engine respawn alternates the virtual-DNS pool"
pool() { x 'p=$(pidof tun2proxy-bin); [ -n "$p" ] && tr "\0" " " < /proc/$p/cmdline | sed -n "s/.*--virtual-dns-pool \([^ ]*\).*/\1/p"'; }
p1=$(pool); x 'kill $(pidof tun2proxy-bin)' >/dev/null
for _ in $(seq 1 15); do p2=$(pool); [ -n "$p2" ] && [ "$p2" != "$p1" ] && break; sleep 1; done
[ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ] && r=ok || r=bad; check "procd respawned the engine on the other pool half" $r "$p1 -> $p2"
for _ in $(seq 1 15); do x 'grep -q "engine restarted: DNS cache flushed" /var/run/netbridge/log && echo y' | grep -q y && break; sleep 1; done
x 'grep -q "engine restarted: DNS cache flushed" /var/run/netbridge/log && echo y' | grep -q y && r=ok || r=bad; check "watchdog noticed the respawn and flushed the DNS cache" $r
echo "== restart keeps the guard (no window around the proxy) and is idempotent"
out=$(x 'i=0; ( while [ $i -lt 80 ]; do ip route | grep -q "^blackhole 0.0.0.0/1" || echo GAP; i=$((i+1)); sleep 0.1; done ) & /etc/init.d/netbridge restart; wait; echo restart-done')
echo "$out" | grep -q restart-done && ! echo "$out" | grep -q GAP && r=ok || r=bad
check "guard present at every 0.1 s sample during a restart" $r "$(echo "$out" | grep -c GAP) gaps"
x '/etc/init.d/netbridge restart; sleep 3' >/dev/null
[ "$(x 'uci get dhcp.@dnsmasq[0].server')" = "8.8.8.8" ] && r=ok || r=bad; check "after restarts the upstream list is still only 8.8.8.8" $r "$(x 'uci get dhcp.@dnsmasq[0].server')"
x 'uci show firewall | grep -c "firewall.netbridge_zone=zone"' | tail -1 | grep -q '^1$' && r=ok || r=bad; check "two restarts leave exactly one firewall zone" $r

echo "== stop restores everything"
x '/etc/init.d/netbridge stop' >/dev/null
gone() { x 'pgrep -f "[t]un2proxy-bin|[n]etbridge/ctl" >/dev/null && echo running || echo none'; }
for _ in $(seq 1 10); do [ "$(gone)" = none ] && break; sleep 1; done
[ "$(gone)" = none ] && r=ok || r=bad; check "stop ends the engine and the watchdog" $r
# only OUR routes: OpenWrt itself keeps e.g. "unreachable fdXX:...::/48" for its ULA prefix, which must not count
left() { x 'ip route | grep -E "nbtun|^blackhole (0\.0\.0\.0|128\.0\.0\.0)/1|^unreachable 127\.0\.0\.1 |^127\.0\.0\.1 "; ip -6 route | grep -E "^(blackhole|unreachable) (::|8000::)/1 "'; }
l=$(left); [ -z "$l" ] && r=ok || r=bad; check "stop removes every route (tun, pin, proxy safety route, IPv4 + IPv6 guard)" $r "$(echo "$l" | tr '\n' ';')"
x '[ -e /tmp/dnsmasq.d/netbridge-ttl.conf ] && echo left || echo gone' | grep -q gone && r=ok || r=bad; check "stop removes the conf-dir TTL file (if one was used)" $r
d=$(x 'uci show dhcp | sort > /tmp/dhcp.after; cmp -s /tmp/dhcp.after /tmp/dhcp.before && echo same || echo changed'); [ "$d" = same ] && r=ok || r=bad; check "dhcp config restored exactly (incl. the user's own 8.8.8.8 and 9.9.9.9)" $r "$(x 'cmp /tmp/dhcp.before /tmp/dhcp.after 2>&1 | head -1')"
d=$(x 'uci show firewall | sort > /tmp/firewall.after; cmp -s /tmp/firewall.after /tmp/firewall.before && echo same || echo changed'); [ "$d" = same ] && r=ok || r=bad; check "firewall config restored exactly" $r "$(x 'cmp /tmp/firewall.before /tmp/firewall.after 2>&1 | head -1')"
d=$(x 'uci show network | sort > /tmp/network.after; cmp -s /tmp/network.after /tmp/network.before && echo same || echo changed'); [ "$d" = same ] && r=ok || r=bad; check "network config never touched" $r "$(x 'cmp /tmp/network.before /tmp/network.after 2>&1 | head -1')"


echo "== boot guard (/etc/init.d/netbridge-guard, START=11)"
x 'uci set netbridge.main.enabled=1; uci commit netbridge; /etc/init.d/netbridge-guard start' >/dev/null
[ "$(x 'ip route | grep -cE "^blackhole (0\.0\.0\.0|128\.0\.0\.0)/1 "; ip -6 route | grep -cE "^unreachable (::|8000::)/1 "' | tr '\n' ' ')" = "2 2 " ] && r=ok || r=bad
check "boot guard installs the IPv4 blackholes + IPv6 unreachables before the service starts" $r
x '/etc/init.d/netbridge stop' >/dev/null; l=$(left); [ -z "$l" ] && r=ok || r=bad; check "a stop removes the boot guard too" $r "$(echo "$l" | tr '\n' ';')"
x 'uci set netbridge.main.enabled=0; uci commit netbridge; /etc/init.d/netbridge-guard start' >/dev/null; l=$(left)
[ -z "$l" ] && r=ok || r=bad; check "boot guard does nothing while disabled" $r

echo "== setting enabled=0 tears everything down (e.g. disabled, then rebooted)"
x 'netbridge setup 127.0.0.1 1080 nb nbpass >/dev/null 2>&1' >/dev/null
for _ in $(seq 1 25); do st=$(x '/usr/libexec/netbridge/ctl status' | sed -n 's/^state=//p'); [ "$st" = healthy ] && break; sleep 1; done
[ "$st" = healthy ] && r=ok || r=bad; check "re-enabled and healthy again" $r
x 'uci set netbridge.main.enabled=0; uci commit netbridge; /etc/init.d/netbridge restart' >/dev/null
for _ in $(seq 1 10); do [ "$(gone)" = none ] && break; sleep 1; done
[ "$(gone)" = none ] && r=ok || r=bad; check "enabled=0: no engine or watchdog" $r
l=$(left); [ -z "$l" ] && r=ok || r=bad; check "enabled=0: no routes left" $r "$(echo "$l" | tr '\n' ';')"
d=$(x 'uci show dhcp | sort > /tmp/dhcp.after; cmp -s /tmp/dhcp.after /tmp/dhcp.before && echo same || echo changed'); [ "$d" = same ] && r=ok || r=bad; check "enabled=0: dhcp (user DNS 8.8.8.8 + 9.9.9.9, max_ttl 600) restored exactly" $r "$(x 'uci get dhcp.@dnsmasq[0].server')"
d=$(x 'uci show firewall | sort > /tmp/firewall.after; cmp -s /tmp/firewall.after /tmp/firewall.before && echo same || echo changed'); [ "$d" = same ] && r=ok || r=bad; check "enabled=0: firewall restored exactly" $r

echo "== $PASS passed, $FAILN failed${SKIPN:+, $SKIPN skipped}"; [ "$FAILN" = 0 ]
