#!/bin/bash
# Unit tests for the pure helpers in NetBridgeOpenWrt/setup-router.sh (CPU -> package mapping, address/port validation,
# shell quoting of values sent to the router). Runs anywhere bash runs, no router needed.
#   NetBridgeOpenWrt/test-rig/setup-router-unit.sh
set -u
cd "$(dirname "$0")/.." || exit 1
NB_SETUP_LIB=1 . ./setup-router.sh
p=0; f=0
t() { if [ "$2" = "$3" ]; then p=$((p+1)); else f=$((f+1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
t "aarch64"  "$(target_for aarch64 01)" aarch64-unknown-linux-musl
t "x86_64"   "$(target_for x86_64 01)"  x86_64-unknown-linux-musl
t "mips LE"  "$(target_for mips 01)"    mipsel-unknown-linux-musl
t "mips BE"  "$(target_for mips 02 || echo unsupported)" unsupported
t "armv7"    "$(target_for armv7l 01 || echo unsupported)" unsupported
for ip in 172.20.10.1 10.0.0.1; do valid_ip4 "$ip" && r=ok || r=bad; t "ip $ip" $r ok; done
for ip in 256.1.1.1 1.2.3 a.b.c.d "" 1..2.3; do valid_ip4 "$ip" && r=ok || r=bad; t "ip [$ip]" $r bad; done
for pt in 1 8081 65535; do valid_port "$pt" && r=ok || r=bad; t "port $pt" $r ok; done
for pt in 0 65536 x ""; do valid_port "$pt" && r=ok || r=bad; t "port [$pt]" $r bad; done
# a value with quotes, $, spaces and shell syntax must reach the router's shell unchanged and inert
v="it's a \$secret \"x\" ;rm -rf"
got=$(sh -c "printf %s $(sq "$v")"); t "sq round-trips quotes/\$/spaces through sh" "$got" "$v"
t "need_kb mips"    "$(need_kb mipsel-unknown-linux-musl)" 12000
t "need_kb aarch64" "$(need_kb aarch64-unknown-linux-musl)" 9000
echo "== $p passed, $f failed"; [ "$f" = 0 ]
