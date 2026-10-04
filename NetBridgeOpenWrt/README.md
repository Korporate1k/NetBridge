# NetBridge router client (OpenWrt)

Makes an OpenWrt router send **everything on its Wi-Fi/LAN** through the NetBridge proxy running on an iPhone: the iPhone is
plugged into the router by USB and the router provides the Wi-Fi. TCP, UDP (SOCKS5 UDP ASSOCIATE) and DNS all go through the proxy.

> **Status:** built and tested on Linux (x86-64 namespace rig on a Linux box; the OpenWrt-specific parts inside the official
> OpenWrt 24.10.8 container). **Not yet run on a physical router or with a real iPhone over USB.** Steps marked *(check)*
> below are expectations to confirm on the real hardware.

## What you need
- An aarch64 OpenWrt router with a USB port. First-timer pick: **GL.iNet GL-MT3000** (it ships with an OpenWrt-based web UI,
  so you don't flash anything); **GL-MT6000** for more headroom. Avoid old 32-bit MIPS routers. *(Confirm current support and
  stock on openwrt.org's Table of Hardware / GL.iNet before buying.)*
- **GL.iNet GL-SFT1200 (Opal)** also works, with caveats: a 1 GHz 32-bit MIPS CPU (slower than the MT3000; fine for a
  phone uplink, not yet measured) and GL's OpenWrt **18.06** firmware. Build its package with
  `TARGET=mipsel-unknown-linux-musl scripts/build-openwrt-package.sh` (needs the nightly Rust toolchain with `rust-src` and
  zig 0.14.1, see `scripts/build-tun2proxy-openwrt.sh`). On 18.06 the DNS TTL cap goes into dnsmasq's conf-dir instead of
  UCI, automatically. Check on the device: `kmod-tun` is installed (`ls /dev/net/tun`), iPhone USB tethering works on its
  firmware, and GL's web UI does not undo the dnsmasq/firewall settings NetBridge applies. Tested so far under emulation
  (QEMU) and in an OpenWrt 18.06 container, not on an SFT1200.
- An iPhone running NetBridge (server side), its Lightning/USB-C cable, and a Mac to build and install from.

## 1. Router first-time setup (no proxy yet)
1. Power the router and connect to its Wi-Fi (or Ethernet). Open its admin page (GL.iNet: `http://192.168.8.1`; plain OpenWrt:
   `http://192.168.1.1`), set the admin password and Wi-Fi name/password.
2. Plug the iPhone into the router's USB port, tap **Trust**, and turn on **Personal Hotspot**. On GL.iNet use *Internet ->
   Tethering*; on plain OpenWrt install `kmod-usb-net-ipheth usbmuxd libimobiledevice`. *(check)*
3. Confirm a laptop on the router's Wi-Fi can browse the web. Do this before adding NetBridge.
4. Make sure you can SSH in: `ssh root@192.168.8.1` (GL.iNet uses the admin password) *(check)*.

## 2. Prepare the iPhone
In the NetBridge app: start the proxy listener, **turn on username + password** (the router is a LAN client, so don't leave the
proxy open), and note the port. Keep the app in the foreground with Auto-Lock off (Settings -> Display -> Auto-Lock -> Never;
Guided Access stops accidental exits). The app is suspended by iOS when it is not in the foreground, which stops the proxy;
the watchdog below detects that. Check the daily free-tier cap / Pro status: a cap that trips would cut off the whole LAN.

## 3. Install (one command, any supported router)
```
NetBridgeOpenWrt/setup-router.sh                 # router at 192.168.8.1; or: NetBridgeOpenWrt/setup-router.sh <router-ip>
```
It connects once over SSH (one router-password prompt at most), detects the CPU (aarch64, little-endian 32-bit MIPS such
as the GL-SFT1200, or x86-64) and firmware, checks the tun driver (offers to install `kmod-tun`) and free space, builds the
matching package if it is missing or out of date, installs it (keeping your existing settings), asks for the phone's address
(suggested from the router's default route; with USB tethering that is the phone), port, username, password (not echoed,
never put on a command line) and failure policy, starts NetBridge and waits until the proxy answers. If it doesn't, it says
why (wrong password, app not running, wrong port...).

Unattended: `NB_PASS=... NetBridgeOpenWrt/setup-router.sh <ip> --yes --phone 172.20.10.1 --port 8081 --user <name>`.
Other options: `--policy block|fallback`, `--package FILE`, `--rebuild`, `--uninstall`, `--help`. Re-running it is safe: it
upgrades in place and offers your current settings as defaults (Enter keeps the saved password).

Afterwards, on the router: `netbridge status` (`state=healthy udp=yes`), `netbridge probe` (health check now),
`netbridge log` (the watchdog's decisions). From a device on the router's Wi-Fi, browse the web and check its public IP is
your carrier's.

<details><summary>Manual steps (what the script does)</summary>

```
scripts/build-openwrt-package.sh                       # or TARGET=mipsel-unknown-linux-musl ... for the GL-SFT1200
NetBridgeOpenWrt/install.sh 192.168.8.1 [package]      # checks the CPU, runs the engine once on the router, keeps your config
ssh root@192.168.8.1 'netbridge setup 172.20.10.1 8081 <user> <password>; netbridge status'
```
</details>

## What it does
| Piece | Role |
|---|---|
| `tun2proxy-bin` | the patched engine (same as the iOS/macOS/Windows clients): turns LAN traffic into SOCKS5 connections, answers DNS with virtual addresses |
| `nb-probe` | real SOCKS5 health probe (greeting, sign-in, UDP ASSOCIATE under one deadline). A plain TCP check is fooled by a suspended iPhone, which still accepts connections |
| `ctl watch` | installs the routes, probes every 10 s, applies the failure policy |
| `/etc/init.d/netbridge` | procd: installs the guard first, then supervises the engine and the watchdog; makes the engine's virtual DNS dnsmasq's only upstream and adds the `lan -> nbtun` firewall zone. A restart keeps all of that in place; a real stop (or `enabled=0`) restores your DNS servers and firewall and removes every route |
| `/etc/init.d/netbridge-guard` | boot only (START=11, before dnsmasq and the network): installs the guard early so nothing leaves around the proxy while the router boots |

Routes (IPv4 only, the router's own default route is never changed): the proxy address is pinned to the interface that reaches
it, with an `unreachable` route underneath so that, if the pin is ever lost, the engine's own connection fails fast instead of
looping into the tunnel; `0.0.0.0/1` and `128.0.0.0/1` go into the tunnel; IPv6 is made unreachable so it can't bypass the proxy (devices get an immediate error and use IPv4).

DNS: the engine answers names with virtual addresses (198.18.0.0/15) that only it can map back, and it forgets them when it
restarts. To keep stale answers from breaking things: dnsmasq caps every TTL at 30 s; the engine alternates between the two
halves of the range on each start, so an address from the previous run can never point to a different site; the router's DNS
cache is flushed whenever the engine restarts or the routing changes; and while `fallback` sends traffic out the WAN, the
virtual range is made unreachable so a stale address fails at once and the device asks again. An app that keeps its own DNS
cache longer than the TTL can still hold an old address for a while; it then gets an error (never the wrong site) until it
looks the name up again.

## Failure policy (`option policy` in `/etc/config/netbridge`)
- **`block`** (default): if the proxy stops answering, LAN traffic is blocked until it answers again. Blackhole routes (the guard)
  keep winning whenever the tunnel routes are absent: during boot, start, restart, or if the engine process dies, so nothing is
  sent around the proxy. Only a real `stop` (or `enabled=0`) removes them.
- **`fallback`**: while the proxy is down, LAN traffic goes out the plain USB-tether link (NOT through the proxy) until it is back.
  Use this only if staying online matters more than keeping everything behind the proxy.

## Remove
`NetBridgeOpenWrt/setup-router.sh <router-ip> --uninstall` (asks whether to delete the saved settings too), or by hand:
```
/etc/init.d/netbridge stop; /etc/init.d/netbridge disable
/etc/init.d/netbridge-guard disable
rm -f /etc/init.d/netbridge /etc/init.d/netbridge-guard /usr/bin/netbridge /usr/bin/nb-probe /usr/bin/tun2proxy-bin /etc/config/netbridge
rm -rf /usr/libexec/netbridge
```
(`stop` restores your own dnsmasq servers/settings and the firewall, and removes every route.)

## Limits and notes
- IPv4 only; IPv6 is blocked by design.
- Sharing a phone's data this way may count as tethering under your carrier's terms. That is between you and your plan.
- The proxy password is on the router in `/etc/config/netbridge` (mode 600) and visible to root in the process list.
- OpenWrt's default busybox `ip` has no `route get`; the watchdog then pins the proxy via the default route, which is correct for
  the USB-tether layout (the phone is the gateway) and for any proxy reached through the default route.

## Tests (all in this folder / scripts/)
- `test-rig/setup-router-unit.sh`: the setup script's CPU mapping, address/port checks and value quoting (22 checks, runs
  anywhere).
- `test-rig/setup-router-test.sh`: the whole setup script against an OpenWrt 24.10.8 container as the router (fresh
  install, upgrade keeping settings, wrong password explained, uninstall restoring DNS/firewall; 15 checks).
- `test-rig/mips-qemu-test.sh`: the 32-bit MIPS (GL-SFT1200) engine and probe under QEMU user-mode emulation in a throwaway
  container (nothing installed on the host): probe suite, virtual DNS, TCP by hostname, real UDP through the proxy (8 checks).
- `OWRT_TAG=x86-64-18.06.9 test-rig/owrt-docker-test.sh ...`: the same container suite against OpenWrt 18.06 (the
  SFT1200's firmware generation); fw3 can't render rules inside that container, so that one check is reported as SKIP.
- `nb-probe/test_probe.py`: every probe verdict, incl. a silent server (10 checks, run on the Mac).
- `test-rig/rig.sh up|test|down`: three network namespaces (LAN client, router, phone) on any Linux box with root: TCP, DNS via
  dnsmasq + virtual DNS, TCP by name, real UDP, proxy-down, engine-dies and restart window (no leak), both policies, pin
  fallback, pin loss and recovery, stale virtual DNS (TTL cap, pool alternation after an engine restart, fast failure in
  fallback), complete cleanup on a real stop (50 checks).
- `test-rig/owrt-docker-test.sh`: inside the official OpenWrt rootfs container: procd supervision, UCI, dnsmasq + fw4 wiring,
  the guard sampled through a restart, the boot guard, `enabled=0` teardown, and exact restore of your own DNS servers and
  firewall, the 30 s DNS TTL cap and pool alternation when procd respawns the engine (42 checks).
