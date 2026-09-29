# NetBridge

An iOS app that runs a local **HTTP CONNECT + SOCKS5 (TCP and UDP ASSOCIATE)
proxy** on your iPhone, so another device on the same network (Wi-Fi, Personal
Hotspot, or USB) can route its traffic through the phone.

It also has **clients** that send a whole device's traffic (TCP and UDP) through
such a phone as a system-wide VPN:

- **iPhone/iPad**: the app's **Client** tab (a packet-tunnel VPN; pair by
  scanning the other phone's QR code).
- **macOS**: `NetBridgeMac.xcodeproj` (generated from `project-mac.yml` with
  XcodeGen), a menu-bar app with the same tunnel.
- **Windows**: `NetBridgeWindows/` (see below).

All three share one engine (tun2proxy with the local patches in
`LWIPTunnelEngine/patches/`) and the same `socks5://` / QR pairing format.

Useful for routing a second device's traffic through your phone for testing,
debugging, or general local-network relaying — point any HTTP-CONNECT- or
SOCKS5-capable client at the phone's address and port.

## Prerequisites

- A Mac with Xcode (15+).
- An iPhone (any iOS 15+ device).
- For the **proxy** alone, a free Apple ID is enough, so it runs via Xcode or
  sideloading (AltStore / SideStore / Sideloadly).
- The **Client** (VPN) tab and the macOS client use a Network Extension
  (packet tunnel), which needs a paid developer account's
  `packet-tunnel-provider` entitlement.
- The engine xcframework is rebuilt with `scripts/build-tun2proxy-apple.sh`.

## Build

1. Open `NetBridge.xcodeproj` in Xcode.
2. Select your device, set your team under Signing & Capabilities if needed.
3. Run.

## Using it

1. Launch NetBridge and tap **Start Proxy**. The dashboard shows the
   phone's current local IPv4 address and port.
2. On the other device, join the same network as the phone and set its HTTP
   or SOCKS5 proxy setting to that address and port.
3. Traffic sent through the proxy shows up in the dashboard's per-device
   stats.

## Features

- Multiple listeners (Settings → Additional Listeners), each auto-detecting,
  HTTP-only, or SOCKS5-only.
- Per-device block list and bandwidth caps (tap a device in Devices).
- Optional DNS-over-HTTPS resolution, upstream configurable in Settings.
- Recent-connections list, auto-restart on an unexpected listener drop,
  save/switch config profiles, a QR code for the address, and a live
  usage graph — all on the dashboard or in Settings.

## Windows client

`NetBridgeWindows/` is a Windows 10/11 (x64) client. Like the macOS app, it
sends all of the PC's TCP and UDP through the phone. Build it on a Mac with
`scripts/build-windows.sh`, which produces
`build/windows/NetBridge-win-x64.zip`. Unzip it on the PC, run
`NetBridge.exe` (it asks for administrator rights), and pair it by address,
`socks5://` link, or a QR code screenshot. See
`NetBridgeWindows/README-windows.txt`.

## Background survival

No Network Extension can host this listener on iOS (`NEAppProxyProvider` is
MDM-only; packet-tunnel providers can't host listeners), so the proxy lives in
the app process:

- **Reliable:** keep the app foreground / screen on.
- **Best-effort:** the "Background keep-alive" toggle (Always location)
  usually extends lifetime while backgrounded but can still be suspended by
  iOS.

## Architecture

See `HANDOFF.md` for a full breakdown of the relay engine, diagnostics, and
how this project relates to its predecessor.
