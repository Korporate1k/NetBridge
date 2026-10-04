#!/bin/bash
# NetBridge router test rig for any Linux box with root. Everything runs inside network namespaces, so the host's
# routes, firewall (UFW etc.), resolv.conf and docker are never touched and no host firewall rule is needed:
#
#   [nblan: LAN client] --veth-- [nbrouter: forwards + tun2proxy + dnsmasq] --veth-- [nbphone: stand-in "iPhone" proxy
#       10.98.0.2                10.98.0.1   default route -> nbtun   10.99.0.2     10.99.0.1:1080 + local test targets
#                                                                                    on 203.0.113.10: HTTP :80, UDP echo :9999]
#
# The stand-in proxy is scripts/socks5_test_server.py (CONNECT + UDP ASSOCIATE + auth, logs every request); the
# "internet" is 203.0.113.10 (TEST-NET-3), served inside nbphone, so the rig works offline. The proxy resolves
# example.test itself (--host-map), because name lookups on systemd boxes go to the HOST's resolver, not the namespace's.
#
#   sudo ./rig.sh up | test | down | status    (needs ./tun2proxy-bin ./nb-probe ./ctl ./socks5_test_server.py ./udp_echo.py)
#
# The router namespace also has a modeled "WAN default" (via the phone namespace, like a USB-tether link), so the
# failure policies can be tested: with policy "block" nothing may leak around the proxy; with "fallback" traffic goes
# out the plain WAN while the proxy is down. The real scripts under test: ./ctl (routes + watchdog) and ./nb-probe.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$DIR/tun2proxy-bin}"
SERVER="$DIR/socks5_test_server.py"; ECHO="$DIR/udp_echo.py"
CTL="${CTL:-$DIR/ctl}"; NBPROBE="${NBPROBE:-$DIR/nb-probe}"; POLICY="${POLICY:-block}"; WRAP="${WRAP:-$DIR/engine}"
RUN="$DIR/run"
PROXY_IP=10.99.0.1; ROUTER_WAN=10.99.0.2; LAN_GW=10.98.0.1; LAN_CLIENT=10.98.0.2; TARGET_IP=203.0.113.10
PROXY_PORT=1080; PUSER=nb; PPASS=nbpass
ROUTER="ip netns exec nbrouter"; LAN="ip netns exec nblan"; PHONE="ip netns exec nbphone"

die() { echo "ERROR: $*" >&2; [ "${UPPING:-0}" = 1 ] && { echo "cleaning up the half-built rig" >&2; down >/dev/null 2>&1; }; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
exists() { ip netns list 2>/dev/null | grep -q "^$1\b"; }

start_proxy() {
    nohup $PHONE python3 "$SERVER" --bind "$PROXY_IP" --port "$PROXY_PORT" --user "$PUSER" --password "$PPASS" \
        --host-map "example.test=$TARGET_IP" >> "$RUN/proxy.log" 2>&1 &
    echo $! > "$RUN/proxy.pid"
}
stop_pidfile() {
    [ -f "$RUN/$1.pid" ] || return 0
    _p=$(cat "$RUN/$1.pid"); kill "$_p" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$_p" 2>/dev/null || break; sleep 0.1; done
    rm -f "$RUN/$1.pid"
}
# a real stop, like `/etc/init.d/netbridge stop`: the marker tells the watchdog to remove everything, guard included
real_stop_ctl() { mkdir -p "$RUN/state"; touch "$RUN/state/stopping"; stop_pidfile ctl; sleep 0.5; }

start_engine() {
    # through the real engine wrapper (alternating virtual-DNS pool), as procd starts it on the router
    mkdir -p "$RUN/state"
    nohup $ROUTER env NB_STATE="$RUN/state" NB_ENGINE="$BIN" sh "$WRAP" --tun nbtun --proxy "socks5://$PUSER:$PPASS@$PROXY_IP:$PROXY_PORT" \
        --dns virtual --dns-addr 8.8.8.8 --udp-timeout 120 --tcp-mss 1440 -v info \
        >> "$RUN/tun2proxy.log" 2>&1 &
    echo $! > "$RUN/tun2proxy.pid"
    for _ in $(seq 1 20); do $ROUTER ip link show nbtun >/dev/null 2>&1 && break; sleep 0.5; done
    $ROUTER ip link show nbtun >/dev/null 2>&1 || { tail -5 "$RUN/tun2proxy.log"; die "tun2proxy did not create nbtun"; }
}
# ctl runs INSIDE nbrouter, so its `ip` calls act on the router namespace only
start_ctl() {  # $1 = policy, $2 = extra env (e.g. NB_NO_ROUTE_GET=1)
    mkdir -p "$RUN/state"; rm -f "$RUN/state/status"   # a stale status from the previous watchdog must not satisfy wait_state
    nohup $ROUTER env NB_SERVER=$PROXY_IP NB_PORT=$PROXY_PORT NB_USER=$PUSER NB_PASS=$PPASS NB_TUN=nbtun NB_POLICY="$1" ${2:-} \
        NB_DNS_FLUSH="kill -HUP \$(cat $RUN/dnsmasq.pid)" NB_INTERVAL=2 NB_FAILS=2 NB_PROBE="$NBPROBE" NB_STATE="$RUN/state" sh "$CTL" watch >> "$RUN/ctl.log" 2>&1 &
    echo $! > "$RUN/ctl.pid"
}
nbstatus() { sed -n "s/^$1=//p" "$RUN/state/status" 2>/dev/null; }
# only a status the current watchdog wrote recently counts (a dead watchdog leaves a stale file behind)
fresh() { _u=$(nbstatus updated); [ -n "$_u" ] && [ $(( $(date +%s) - _u )) -le 10 ]; }
wait_state() {  # $1 = wanted state, $2 = max seconds
    for _ in $(seq 1 "$2"); do [ "$(nbstatus state)" = "$1" ] && fresh && return 0; sleep 1; done; return 1
}
leftovers() { { $ROUTER ip route | grep -E "nbtun|blackhole|unreachable|^$PROXY_IP "; $ROUTER ip -6 route | grep -E "^(blackhole|unreachable) (::|8000::)/1 "; } 2>/dev/null; }

up() {
    if exists nbrouter || exists nblan || exists nbphone; then die "rig already up (run: $0 down)"; fi
    [ -x "$BIN" ] || die "missing $BIN"; [ -f "$SERVER" ] && [ -f "$ECHO" ] || die "missing server/echo script"
    mkdir -p "$RUN/www"; : > "$RUN/proxy.log"; echo NBRIG-OK > "$RUN/www/index.html"
    host_state > "$RUN/host.before"     # baseline BEFORE the rig touches anything
    UPPING=1
    ip netns add nbphone && ip netns add nbrouter && ip netns add nblan || die "netns create failed"
    ip link add nbwan0 netns nbphone type veth peer name nbwan1 netns nbrouter || die "veth wan"
    $PHONE ip addr add $PROXY_IP/24 dev nbwan0; $PHONE ip link set nbwan0 up; $PHONE ip link set lo up
    $PHONE ip addr add $TARGET_IP/32 dev lo
    $ROUTER ip addr add $ROUTER_WAN/24 dev nbwan1; $ROUTER ip link set nbwan1 up; $ROUTER ip link set lo up
    ip link add nblan0 netns nbrouter type veth peer name nblan1 netns nblan || die "veth lan"
    $ROUTER ip addr add $LAN_GW/24 dev nblan0; $ROUTER ip link set nblan0 up
    $LAN ip addr add $LAN_CLIENT/24 dev nblan1; $LAN ip link set nblan1 up; $LAN ip link set lo up
    $LAN ip route add default via $LAN_GW
    $ROUTER sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
    # the "internet": an HTTP page and a UDP echo, only reachable inside nbphone, i.e. only through the proxy
    nohup $PHONE python3 -m http.server 80 --bind $TARGET_IP --directory "$RUN/www" >> "$RUN/http.log" 2>&1 &
    echo $! > "$RUN/http.pid"
    nohup $PHONE python3 "$ECHO" $TARGET_IP 9999 >> "$RUN/echo.log" 2>&1 &
    echo $! > "$RUN/echo.pid"
    start_proxy
    # "WAN": a plain default route out of the router (via the phone namespace, like a tether link). Traffic only uses it
    # when the tunnel routes are absent, which is exactly what the failure policies decide.
    $ROUTER ip route add default via $PROXY_IP dev nbwan1
    $PHONE ip route add 10.98.0.0/24 via $ROUTER_WAN
    start_engine
    start_ctl "$POLICY"
    # DNS like OpenWrt: dnsmasq on the LAN address, upstream 8.8.8.8 (which lands in the tun's virtual DNS)
    $ROUTER dnsmasq --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces --listen-address=$LAN_GW \
        --server=8.8.8.8 --max-ttl=30 --max-cache-ttl=30 --pid-file="$RUN/dnsmasq.pid" --log-facility="$RUN/dnsmasq.log" || die "dnsmasq failed"
    wait_state healthy 20 || echo "note: watchdog not healthy yet: $(nbstatus state)"
    UPPING=0
    echo "rig up. logs in $RUN/ (proxy.log, tun2proxy.log)"
}

down() {
    stop_pidfile ctl; sleep 1; for p in proxy tun2proxy dnsmasq http echo; do stop_pidfile $p; done
    for ns in nblan nbrouter nbphone; do ip netns pids $ns 2>/dev/null | xargs -r kill 2>/dev/null; done
    sleep 0.5
    ip netns del nblan 2>/dev/null; ip netns del nbrouter 2>/dev/null; ip netns del nbphone 2>/dev/null
    rm -f "$RUN"/*.pid
    echo "rig down"
}

status() {
    ip netns list | grep -E "^nb" || echo "no nb* namespaces"
    for p in proxy tun2proxy ctl dnsmasq http echo; do
        if [ -f "$RUN/$p.pid" ] && kill -0 "$(cat "$RUN/$p.pid")" 2>/dev/null; then echo "$p: running (pid $(cat "$RUN/$p.pid"))"; else echo "$p: not running"; fi
    done
}

PASS=0; FAILN=0
check() { if [ "$2" = ok ]; then echo "PASS - $1 ${3:+| $3}"; PASS=$((PASS+1)); else echo "FAIL - $1 ${3:+| $3}"; FAILN=$((FAILN+1)); fi; }
host_state() {
    { ip route show; ip -6 route show | sed -E 's/expires [0-9]+sec//'; ip rule show; cat /etc/resolv.conf
      iptables-save 2>/dev/null | grep -v '^#' | sed -E 's/\[[0-9]+:[0-9]+\]//'; } | md5sum | cut -c1-12
}
# DNS A query for $1 sent from the LAN namespace to $2:53; prints the first A record (or with $3=ttl its TTL), or the failure
dns_a() {
    $LAN python3 - "$1" "$2" "${3:-ip}" <<'PY'
import socket, struct, sys
name, srv, want = sys.argv[1], sys.argv[2], sys.argv[3]
q = struct.pack("!HHHHHH", 0x4e42, 0x0100, 1, 0, 0, 0)
for label in name.split("."): q += bytes([len(label)]) + label.encode()
q += b"\x00" + struct.pack("!HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(6); s.sendto(q, (srv, 53))
try:
    d, _ = s.recvfrom(512)
    if struct.unpack("!H", d[6:8])[0] < 1: print("no-answer")
    else: print(struct.unpack("!I", d[-10:-6])[0] if want == "ttl" else socket.inet_ntoa(d[-4:]))
except Exception as e:
    print("no-reply:", e)
PY
}
udp_echo() {  # one datagram to the echo target through the tunnel
    $LAN python3 - <<PY
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(8); s.sendto(b"NBRIG-UDP", ("$TARGET_IP", 9999))
try: print(s.recvfrom(512)[0].decode())
except Exception as e: print("no-reply:", e)
PY
}
http_code() { $LAN curl -s -m "$1" -o /dev/null -w '%{http_code}' "${@:2}" 2>&1; }

run_tests() {
    exists nbrouter || die "rig is not up"
    before=$(cat "$RUN/host.before" 2>/dev/null || host_state); mark=$(wc -l < "$RUN/proxy.log")
    echo "== TCP by IP literal"
    c=$(http_code 15 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "LAN client -> http://$TARGET_IP/ through the tunnel" $r "http $c"
    echo "== DNS: LAN client -> dnsmasq -> tun virtual DNS"
    fake=$(dns_a example.test $LAN_GW); case "$fake" in 198.18.*|198.19.*) r=ok;; *) r=bad;; esac
    check "example.test resolves to a virtual 198.18/15 address" $r "$fake"
    t=$(dns_a example.test $LAN_GW ttl); [ -n "$t" ] && [ "$t" -le 30 ] 2>/dev/null && r=ok || r=bad
    check "DNS answers to LAN devices carry a TTL of at most 30 s" $r "ttl=$t"
    echo "== TCP by name (virtual address -> engine sends hostname in SOCKS5 CONNECT)"
    c=$(http_code 20 http://$fake/ -H "Host: example.test"); [ "$c" = 200 ] && r=ok || r=bad; check "LAN client -> virtual address (example.test)" $r "http $c"
    echo "== UDP through SOCKS5 UDP ASSOCIATE (non-DNS port)"
    u=$(udp_echo); [ "$u" = "echo:NBRIG-UDP" ] && r=ok || r=bad; check "UDP echo to $TARGET_IP:9999 via the proxy" $r "$u"
    echo "== Proof the traffic crossed the proxy"
    new=$(tail -n +$((mark+1)) "$RUN/proxy.log")
    echo "$new" | grep -q "CONNECT $TARGET_IP:80$" && r=ok || r=bad; check "proxy log: CONNECT $TARGET_IP:80" $r
    echo "$new" | grep -q "CONNECT example.test:80$" && r=ok || r=bad; check "proxy log: CONNECT by hostname example.test:80" $r
    echo "$new" | grep -q "UDP -> $TARGET_IP:9999" && r=ok || r=bad; check "proxy log: UDP datagram to $TARGET_IP:9999" $r
    echo "== Failure: proxy stops (the 'iPhone app suspended' case)"
    stop_pidfile proxy; sleep 1
    c=$(http_code 8 http://$TARGET_IP/); [ "$c" = 000 ] && r=ok || r=bad; check "with the proxy down the LAN client gets no connectivity" $r "http $c"
    echo "== Recovery"
    start_proxy; sleep 2
    c=$(http_code 15 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "traffic resumes after the proxy returns" $r "http $c"
    echo "== Watchdog + policy BLOCK (default)"
    wait_state healthy 20 && r=ok || r=bad; check "watchdog reports healthy with the proxy up" $r "state=$(nbstatus state) udp=$(nbstatus udp)"
    [ "$(nbstatus udp)" = yes ] && r=ok || r=bad; check "watchdog sees UDP ASSOCIATE granted" $r
    $ROUTER ip -6 route | grep -q "^unreachable ::/1" && r=ok || r=bad; check "IPv6 is made unreachable so it cannot bypass the proxy" $r
    stop_pidfile proxy; wait_state down 25 && r=ok || r=bad; check "proxy killed -> watchdog reports down" $r "state=$(nbstatus state)"
    c=$(http_code 6 http://$TARGET_IP/); [ "$c" = 000 ] && r=ok || r=bad; check "block policy: traffic stays blocked (nothing leaks to the WAN)" $r "http $c"
    start_proxy; wait_state healthy 25 && r=ok || r=bad; check "proxy back -> watchdog reports healthy again" $r "state=$(nbstatus state)"
    c=$(http_code 15 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "traffic flows again" $r "http $c"
    echo "== Engine dies (block policy must not leak)"
    f1=$(dns_a example.test $LAN_GW)
    stop_pidfile tun2proxy; sleep 2
    $ROUTER ip route | grep -q "^blackhole 0.0.0.0/1" && r=ok || r=bad; check "blackhole safety net is in place with the engine gone" $r
    c=$(http_code 6 http://$TARGET_IP/); [ "$c" = 000 ] && r=ok || r=bad; check "engine dead: LAN client gets no connectivity (no leak around the proxy)" $r "http $c"
    start_engine; sleep 4
    c=$(http_code 15 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "engine restarted: watchdog re-installs the tun routes, traffic resumes" $r "http $c"
    echo "== Stale virtual DNS after an engine restart"
    grep -q "engine restarted: DNS cache flushed" "$RUN/state/log" && r=ok || r=bad; check "watchdog noticed the engine restart and flushed the DNS cache" $r
    f2=$(dns_a example.test $LAN_GW)
    [ -n "$f1" ] && [ -n "$f2" ] && [ "$(echo "$f1" | cut -d. -f1-2)" != "$(echo "$f2" | cut -d. -f1-2)" ] && r=ok || r=bad
    check "new engine answers from the other pool half (a cached answer would have returned the old one)" $r "$f1 -> $f2"
    c=$(http_code 15 http://$f2/ -H "Host: example.test"); [ "$c" = 200 ] && r=ok || r=bad; check "the new virtual address works" $r "http $c"
    c=$(http_code 8 http://$f1/ -H "Host: example.test"); [ "$c" != 200 ] && r=ok || r=bad
    check "the stale virtual address does not reach a site (no collision with a new mapping)" $r "http $c"
    echo "== Restart window (block): the watchdog stops as in a restart; the guard must stay"
    stop_pidfile ctl; sleep 0.5
    $ROUTER ip route | grep -q "^blackhole 0.0.0.0/1" && r=ok || r=bad; check "guard (IPv4 blackholes) stays when the watchdog stops for a restart" $r
    $ROUTER ip route | grep -q "dev nbtun" && r=bad || r=ok; check "tun routes removed by the stopping watchdog" $r
    c=$(http_code 6 http://$TARGET_IP/); [ "$c" = 000 ] && r=ok || r=bad; check "restart window: LAN gets no connectivity (no leak to the WAN)" $r "http $c"
    start_ctl block; wait_state healthy 20 && r=ok || r=bad; check "watchdog back after the restart" $r
    c=$(http_code 15 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "traffic flows after the restart" $r "http $c"
    echo "== Policy FALLBACK"
    stop_pidfile ctl; sleep 0.5; start_ctl fallback
    wait_state healthy 20 && r=ok || r=bad; check "fallback: watchdog healthy" $r
    $ROUTER ip route | grep -q "^blackhole 0.0.0.0/1" && r=bad || r=ok; check "fallback: no IPv4 guard (it would block the WAN fallback)" $r
    n0=$(grep -c "CONNECT $TARGET_IP:80$" "$RUN/proxy.log")
    stop_pidfile proxy; wait_state down 25 && r=ok || r=bad; check "fallback: proxy killed -> down" $r
    c=$(http_code 10 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "fallback: traffic goes out the plain WAN while the proxy is down" $r "http $c"
    $ROUTER ip route | grep -q "^unreachable 198.18.0.0/15" && r=ok || r=bad; check "fallback: virtual range made unreachable while the tunnel is bypassed" $r
    t0=$(date +%s%N); c=$(http_code 10 http://$f2/); ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    [ "$c" = 000 ] && [ "$ms" -lt 2000 ] && r=ok || r=bad; check "fallback: a stale virtual address fails at once instead of timing out" $r "http $c in ${ms} ms"
    [ "$(grep -c "CONNECT $TARGET_IP:80$" "$RUN/proxy.log")" = "$n0" ] && r=ok || r=bad; check "fallback: that traffic did NOT go through the proxy" $r
    start_proxy; wait_state healthy 25 && r=ok || r=bad; check "fallback: proxy back -> healthy" $r
    sleep 1; c=$(http_code 15 http://$TARGET_IP/); n1=$(grep -c "CONNECT $TARGET_IP:80$" "$RUN/proxy.log")
    [ "$c" = 200 ] && [ "$n1" -gt "$n0" ] && r=ok || r=bad; check "fallback: traffic is back through the proxy" $r "http $c, CONNECTs $n0 -> $n1"
    $ROUTER ip route | grep -q "^unreachable 198.18.0.0/15" && r=bad || r=ok; check "fallback: virtual range reachable again once the tunnel is back" $r
    real_stop_ctl
    l=$(leftovers); [ -z "$l" ] && r=ok || r=bad; check "a real stop removes every route (tun, pin, IPv4 + IPv6 guard)" $r "$(echo "$l" | tr '\n' ';')"
    echo "== Pin fallback (OpenWrt's busybox ip has no 'route get')"
    start_ctl block NB_NO_ROUTE_GET=1; wait_state healthy 20 && r=ok || r=bad; check "watchdog healthy using the default-route pin fallback" $r
    $ROUTER ip route | grep -q "^$PROXY_IP dev nbwan1" && r=ok || r=bad; check "proxy /32 pinned on-link via the default route's interface" $r "$($ROUTER ip route | grep "^$PROXY_IP ")"
    [ "$(nbstatus pin_src)" = default ] && r=ok || r=bad; check "status confirms the pin came from the default route" $r "pin_src=$(nbstatus pin_src)"
    c=$(http_code 15 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "traffic flows with the fallback pin" $r "http $c"
    stop_pidfile ctl; sleep 0.5
    echo "== Pin recovery: pin lost while the tun routes are active ('route get' then answers with the tun itself)"
    start_ctl block; wait_state healthy 20 && r=ok || r=bad; check "watchdog healthy (normal 'route get' pin)" $r "pin_src=$(nbstatus pin_src)"
    # lose the pin and the connected route: now 'ip route get <proxy>' resolves through 0/1 dev nbtun
    $ROUTER ip route del $PROXY_IP/32 2>/dev/null; $ROUTER ip route del 10.99.0.0/24 dev nbwan1 2>/dev/null
    $ROUTER ip route get $PROXY_IP 2>&1 | grep -q "dev nbtun" && r=bad || r=ok
    check "pin lost: traffic to the proxy is NOT routed into the tun (unreachable safety route)" $r "$($ROUTER ip route get $PROXY_IP 2>&1 | head -1)"
    for _ in $(seq 1 15); do [ "$(nbstatus pin_src)" = default ] && $ROUTER ip route | grep -q "^$PROXY_IP dev nbwan1" && break; sleep 1; done
    $ROUTER ip route | grep -q "^$PROXY_IP dev nbwan1" && [ "$(nbstatus pin_src)" = default ] && r=ok || r=bad
    check "watchdog re-pins the proxy via the default route" $r "$($ROUTER ip route | grep "^$PROXY_IP ") pin_src=$(nbstatus pin_src)"
    c=$(http_code 15 http://$TARGET_IP/); [ "$c" = 200 ] && r=ok || r=bad; check "traffic flows after the recovery" $r "http $c"
    $ROUTER ip route add 10.99.0.0/24 dev nbwan1 proto kernel scope link src $ROUTER_WAN 2>/dev/null
    real_stop_ctl
    l=$(leftovers); [ -z "$l" ] && r=ok || r=bad; check "a real stop (block) removes every route, guard included" $r "$(echo "$l" | tr '\n' ';')"
    echo "== The host was not disturbed"
    [ "$before" = "$(host_state)" ] && r=ok || r=bad; check "host routes (v4+v6) + rules + resolv.conf + iptables unchanged since before up" $r "$before -> $(host_state)"
    echo "== $PASS passed, $FAILN failed"; [ "$FAILN" = 0 ]
}

case "${1:-}" in up) up;; down) down;; status) status;; test) run_tests;; *) echo "usage: sudo $0 up|test|down|status"; exit 2;; esac
