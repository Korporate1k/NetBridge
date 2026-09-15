# LocalProxy

An iOS app that runs a local **HTTP CONNECT + SOCKS5 (TCP and UDP ASSOCIATE)
proxy** on your iPhone, so another device on the same network (Wi-Fi, Personal
Hotspot, or USB) can route its traffic through the phone.

Useful for routing a second device's traffic through your phone for testing,
debugging, or general local-network relaying — point any HTTP-CONNECT- or
SOCKS5-capable client at the phone's address and port.

## Prerequisites

- A Mac with Xcode (15+).
- An iPhone (any iOS 15+ device).
- A free Apple ID is enough — no Network Extension or restricted entitlement
  is used, so it runs via Xcode or sideloading (AltStore / SideStore /
  Sideloadly).

## Build

1. Open `LocalProxy.xcodeproj` in Xcode.
2. Select your device, set your team under Signing & Capabilities if needed.
3. Run.

## Using it

1. Launch LocalProxy and tap **Start Proxy**. The dashboard shows the
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
