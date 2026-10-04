#!/bin/bash
# Runs the 32-bit MIPS (GL-SFT1200) binaries under QEMU user-mode emulation inside a throwaway Alpine container, so
# nothing is installed on the docker host. Checks: the engine and probe start; nb-probe's full test suite; and a data
# path through the MIPS engine (tun device, virtual DNS, TCP by hostname, real UDP through SOCKS5 UDP ASSOCIATE), with the
# proxy log as proof. Speed under emulation means nothing; this proves the code (incl. patch 0009) works on MIPS.
#
#   ./mips-qemu-test.sh tun2proxy-bin-mips nb-probe-mips socks5_test_server.py test_probe.py udp_echo.py
set -u
ENGINE="${1:?}"; PROBE="${2:?}"; SERVER="${3:?}"; TPROBE="${4:?}"; ECHO="${5:?}"
C=nbmips; IMG=alpine:latest
had_img=$(docker images -q "$IMG") || had_img=keep
cleanup() { docker rm -f "$C" >/dev/null 2>&1; [ -z "$had_img" ] && docker rmi "$IMG" >/dev/null 2>&1; echo "cleanup done"; }
trap cleanup EXIT
docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" --cap-add NET_ADMIN --device /dev/net/tun "$IMG" sleep 3600 >/dev/null || exit 1
docker exec "$C" sh -c 'apk add -q qemu-mipsel python3 iproute2 curl >/dev/null 2>&1 && echo deps-ok' | grep -q deps-ok || { echo "cannot install qemu-mipsel in the container"; exit 1; }
docker exec "$C" mkdir -p /w/NetBridgeOpenWrt/nb-probe /w/scripts
docker cp "$ENGINE" "$C:/w/tun2proxy-bin"; docker cp "$PROBE" "$C:/w/nb-probe.mips"
docker cp "$SERVER" "$C:/w/scripts/socks5_test_server.py"; docker cp "$TPROBE" "$C:/w/NetBridgeOpenWrt/nb-probe/test_probe.py"; docker cp "$ECHO" "$C:/w/udp_echo.py"
docker exec -i "$C" sh -s <<'IN'
cd /w; P=0; F=0
check() { if [ "$2" = ok ]; then echo "PASS - $1 ${3:+| $3}"; P=$((P+1)); else echo "FAIL - $1 ${3:+| $3}"; F=$((F+1)); fi; }
chmod +x tun2proxy-bin nb-probe.mips
printf '#!/bin/sh\nexec qemu-mipsel /w/nb-probe.mips "$@"\n' > nb-probe; chmod +x nb-probe
echo "== MIPS binaries under qemu-mipsel"
v=$(qemu-mipsel ./tun2proxy-bin --version 2>&1 | head -1); case "$v" in "tun2proxy 0.8.3"*) r=ok;; *) r=bad;; esac; check "engine runs (MIPS32 LSB, static-pie)" $r "$v"
echo "== nb-probe test suite against the MIPS probe"
out=$(python3 NetBridgeOpenWrt/nb-probe/test_probe.py /w/nb-probe 2>&1); echo "$out" | grep -E "^FAIL" | sed 's/^/   /'
echo "$out" | tail -1 | grep -q "0 failed" && r=ok || r=bad; check "test_probe.py on MIPS" $r "$(echo "$out" | tail -1)"
echo "== data path through the MIPS engine"
# targets live on loopback; the proxy reaches them by name (--host-map), so nothing loops back into the tun
python3 -m http.server 8080 --bind 127.0.0.1 --directory /w >/w/http.log 2>&1 &
echo NBMIPS-OK > /w/index.html
python3 udp_echo.py 127.0.0.1 9999 >/w/echo.log 2>&1 &
python3 scripts/socks5_test_server.py --bind 127.0.0.1 --port 1080 --user nb --password nbpass \
    --host-map example.test=127.0.0.1 --host-map echo.test=127.0.0.1 >/w/proxy.log 2>&1 &
sleep 1
qemu-mipsel ./tun2proxy-bin --tun nbtun --proxy socks5://nb:nbpass@127.0.0.1:1080 --dns virtual --dns-addr 8.8.8.8 \
    --virtual-dns-pool 198.18.0.0/16 --udp-timeout 120 --tcp-mss 1440 -v info >/w/engine.log 2>&1 &
for i in $(seq 1 30); do ip link show nbtun >/dev/null 2>&1 && break; sleep 0.5; done
ip link show nbtun >/dev/null 2>&1 && r=ok || r=bad; check "MIPS engine created the tun device" $r "$(tail -1 /w/engine.log)"
ip link set nbtun up; ip route add 198.18.0.0/15 dev nbtun; ip route add 8.8.8.8/32 dev nbtun
dns() { python3 - "$1" <<'PY'
import socket, struct, sys
q = struct.pack("!HHHHHH", 0x4e42, 0x0100, 1, 0, 0, 0)
for l in sys.argv[1].split("."): q += bytes([len(l)]) + l.encode()
q += b"\x00" + struct.pack("!HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(8); s.sendto(q, ("8.8.8.8", 53))
try: d, _ = s.recvfrom(512); print(socket.inet_ntoa(d[-4:]))
except Exception as e: print("no-reply:", e)
PY
}
f=$(dns example.test); case "$f" in 198.18.*) r=ok;; *) r=bad;; esac; check "virtual DNS answers from the MIPS engine" $r "$f"
c=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H "Host: example.test" "http://$f:8080/"); [ "$c" = 200 ] && r=ok || r=bad
check "TCP by hostname through the MIPS engine" $r "http $c"
e=$(dns echo.test)
u=$(python3 -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(8);s.sendto(b'NBMIPS-UDP',('$e',9999))
try: print(s.recvfrom(512)[0].decode())
except Exception as x: print('no-reply:',x)")
[ "$u" = "echo:NBMIPS-UDP" ] && r=ok || r=bad; check "real UDP through SOCKS5 UDP ASSOCIATE (MIPS engine)" $r "$u"
grep -q "CONNECT example.test:8080$" proxy.log && r=ok || r=bad; check "proxy log: CONNECT by hostname" $r
grep -q "UDP -> echo.test:9999" proxy.log && r=ok || r=bad; check "proxy log: UDP datagram" $r
echo "== $P passed, $F failed"
IN
