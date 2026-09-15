# HANDOFF — LocalProxy

## What this is

LocalProxy is a general-purpose local HTTP CONNECT + SOCKS5 (TCP and UDP
ASSOCIATE) proxy for iOS. It listens on the phone, and any other device on
the same network can point its proxy settings at the phone's address to route
traffic through it — useful for testing, debugging, or general local-network
relaying.

## Where it came from

This project's relay engine was ported from a separate local project,
`~/NetBridge`, which was built for a narrower purpose: hiding a specific
console's tethered traffic from a mobile carrier's tethering detection. That
project's own source comments described it that way explicitly (hardcoded
Personal Hotspot subnet detection, a console-specific setup flow, and
domain-sniffing to auto-label one device as that console).

`NetBridge` itself was left untouched — this is a new, separate project. Only
the parts of it that were genuinely protocol-generic (HTTP CONNECT / SOCKS5
wire parsing, the NWListener-based relay engine, stats, diagnostics, logging)
were ported here, and every piece that was coupled to hotspot-subnet
targeting or console-specific behavior was either removed or rewritten to be
generic. Nothing in this project detects, targets, or is worded around any
specific console, carrier, or "hiding tethering" framing.

## What was ported as-is (mechanical rename only, `NetBridge`→`LocalProxy`)

- `ProxyStats.swift` — byte/connection counters.
- `Frontend.swift` — HTTP CONNECT / absolute-URI request parsing.
- `Socks5Handler.swift` — RFC 1928 wire parsing/reply building.
- `ProxyServer.swift` — `NWListener` accept loop, per-connection queues,
  local-network-permission trigger.
- `ConnectProxyHandler.swift` — the core `Tunnel` relay engine (sniff HTTP vs
  SOCKS5, parse, dial, pipe bytes with backpressure, heartbeat/stall
  diagnostics).
- `UDPRelay.swift` — the SOCKS5 UDP ASSOCIATE relay engine (one
  coupling point replaced — see below).
- `DebugLog.swift` — file-based logger, error formatting, iCloud log mirror.
- `ProxyServer.swift`'s and `NetworkDiagnostics.swift`'s diagnostics
  (`NWPathMonitor`, interface byte-delta table, `CoreTelephony` radio
  tracking, lifecycle/thermal/battery observers) — one small hotspot-logging
  block removed, see below.
- `BackgroundKeeper.swift` — the Always-location background keep-alive
  mechanism (a legitimate, common iOS pattern for any app hosting a local
  network service); only a doc comment naming an external tethering tool
  ("iproxy's `-l` trick") was reworded to describe the mechanism generically.
- `OutboundTransport.swift` — `NWParameters` TCP tuning (`TCP_NODELAY`,
  disabled ACK stretching, `.responsiveData` service class,
  `prohibitExpensivePaths = false` so the proxy doesn't refuse to use
  whatever network path the OS already chose); one comment that justified
  the last setting in carrier-bypass terms was reworded to a generic
  rationale — the setting itself is unchanged and is a reasonable default
  for any proxy.
- `LocalProxyApp.swift` (renamed from `NetBridgeApp.swift`) — `@main`
  bootstrap.
- The `Socks5Client` local Swift package — a generic SOCKS5 client library
  used by the built-in diagnostic test view; no coupling found, copied as-is
  (with its own doc comments' `NetBridge` mentions renamed).

## What was ported with edits (coupling stripped, generic machinery kept)

- **`DeviceRegistry.swift`** — kept per-client persistence, byte/rate
  tracking, rename/forget. Removed `isPlayStation`, `playStationName`,
  `playStationDomains`, and the `noteTarget` domain-sniffing function that
  auto-labeled a device based on which hostnames it talked to. Devices are
  now purely IP/custom-name based, no auto-detection.
- **`DevicesView.swift`** — kept the device list/detail UI and shared
  formatters (`formatBytes`, `formatRate`, `formatLastSeen`, `InfoRow`).
  Removed the console-specific description text and the console-vs-other
  icon branching in favor of one generic device icon/description.
- **`Socks5ClientTestView.swift`** — kept the built-in SOCKS5 client tester
  (a genuinely useful diagnostic tool). Reworded doc/footer strings that
  referenced a specific console running on "its own hotspot" to generic
  "the proxy's listener" language.
- **`DashboardView.swift`** — kept `SettingsView`, stat tiles, card
  components, and rate-sampling. Replaced the console-vs-other picker and
  its step-by-step console-specific setup instructions (which included an
  explicit "hides sign-in/Store/downloads... stays visible to the carrier"
  line) with one generic "point your client's proxy setting at
  `<address>:<port>`" card. Replaced every hardcoded `172.20.10.1`
  (Personal Hotspot gateway) fallback with the new `LocalAddress` helper.
- **`NetworkDiagnostics.swift`** — kept all path/interface/telephony/
  lifecycle diagnostics. Removed the `lastHotspot` state and the one-line
  "hotspot address changed" log block, which existed only to track the
  Personal Hotspot subnet specifically.
- **`ProxyServer.swift`** — removed the `tunnel.onTarget` hook wiring that
  fed the now-removed `noteTarget` domain-sniffing. The underlying
  `onTarget` extension point in `ConnectProxyHandler.swift`'s `Tunnel` class
  is harmless and left in place, just unused.

## What was not ported — replaced with a generic equivalent

- **`HotspotInfo.swift`** — dropped entirely. It matched the device's IP
  against a hardcoded `172.20.10.0/28` (the iOS Personal Hotspot subnet)
  specifically. Replaced by **`LocalAddress.swift`**: the same
  `getifaddrs`/`getnameinfo` interface scan, but it returns whatever local
  IPv4 address is actually active (Wi-Fi, hotspot, USB/Ethernet — anything
  up and non-loopback/non-link-local), with no subnet targeting. Used
  wherever an address needs to be shown or reported
  (`DashboardView.swift`, `UDPRelay.swift`'s UDP ASSOCIATE reply).

## Features added after the initial port

Eight features were added on top of the initial generic port (Mac Catalyst,
a Live Activity/widget, and proxy auth were explicitly descoped for this
pass):

- **Per-device bandwidth caps / block list** — `DeviceRegistry` gained
  `isBlocked`/`capBytesPerSecond` per device (persisted in `devices.json`).
  `ProxyServer.accept(_:)` refuses new connections from a blocked device
  outright; a capped device's `Tunnel` gets a `RateLimiter.swift` token
  bucket that delays sends to hold the long-run rate at the cap. UI in
  `DevicesView.DeviceDetailView`.
- **DoH resolver** — `DoHResolver.swift`, a minimal RFC 8484 client (hand-built
  DNS wire format over `URLSession`, no dependency). `Tunnel.open(_:)`
  resolves the destination host once via DoH (if enabled) before the first
  dial attempt and reuses that result across retries; falls back to system
  DNS on any failure or when disabled. Configurable in Settings (`doh.enabled`
  / `doh.upstreamURL` via `@AppStorage`).
- **Traffic logging/export** — `Tunnel.cleanup(_:)` already builds a rich
  per-connection close line for `DebugLog`; it now also fires `onSummary`
  with the same data, collected into `ConnectionHistory.swift` (a capped,
  most-recent-first list) and shown via a new "Recent Connections" card/list
  in `DashboardView.swift`. Export still goes through the existing Share
  Logs flow — no new export plumbing.
- **Multiple simultaneous listeners** — `ListenerConfig.swift` defines a
  port + `ListenerMode` (`.auto` / `.httpOnly` / `.socks5Only`).
  `ProxyServer.additionalListeners` holds extra listeners beyond the
  original primary `port` (unchanged, always `.auto`); each gets its own
  `NWListener` via the new `startOneListener`/`handleListenerState` helpers.
  `Tunnel` takes a `forcedProtocol` and skips its SOCKS5-sniff when a
  listener is dedicated to one protocol. Configured in Settings.
- **Auto-restart on unexpected drop** — `ProxyServer.maybeAutoRestart`
  retries a listener that fails while the user hasn't called `stop()`
  (skipping real port conflicts), capped at 5 attempts per rolling 60s
  window per port, reset once that listener is `.ready` again. Toggle in
  Settings (`autoRestartEnabled`, on by default).
- **Config profiles** — `ProxyProfile.swift`/`ProfileStore` persist named
  snapshots of the primary port, additional listeners, DoH settings, and
  keep-alive preference to `profiles.json` (same pattern as
  `DeviceRegistry`'s `devices.json`). `ProfilesView.swift` saves/applies
  them; applying is disabled while the proxy is running.
- **QR code** — `QRCodeView.swift` renders the address:port via CoreImage's
  built-in `CIQRCodeGenerator` (no dependency). A QR button on the dashboard
  opens it in a sheet.
- **Historical usage graph** — `UsageHistory.swift` samples throughput every
  5s into a capped, session-scoped array (owned by `ProxyServer`, reset on
  `stop()`). `UsageGraphView.swift` draws it as a hand-rolled `Path`-based
  line chart rather than the `Charts` framework, since `Charts` needs iOS
  16+ and this project's deployment target is iOS 15.0.

All of the above default to today's behavior when untouched (no caps, DoH
off, one auto-sniffing listener on the original port, auto-restart on but
inert unless something actually fails) — nothing here changes what a fresh
install does out of the box.

## Info.plist / build settings

Same permission usage strings as before, reworded to describe a generic
local proxy rather than "keep the proxy running for your console":
`NSLocalNetworkUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`,
`NSLocationWhenInUseUsageDescription`, `UIBackgroundModes: [location]`. Bundle
ID is the placeholder `com.example.LocalProxy` — change it and set a
development team in Xcode before running on a device. `scripts/build-ipa.sh`
is carried over unchanged (aside from naming) — an unsigned local build for
sideloading, not App Store/TestFlight tooling.

## Verified clean

`grep -ri "playstation\|172\.20\.10\|tethering\|carrier\|ps5\|iproxy"` across
every source file and doc in this project returns no matches. A few generic
mentions of "Personal Hotspot" remain (e.g. "join over Wi-Fi, Personal
Hotspot, or USB") — these are neutral references to one of several possible
networks a client might be on, not detection or targeting logic.

## Build instructions

Open `LocalProxy.xcodeproj` in Xcode, set your signing team, and run on a
device. See `README.md` for usage.
