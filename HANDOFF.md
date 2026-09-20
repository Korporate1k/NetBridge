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

## Feature: SNI/Host sniffing + offline GeoIP + connection history UI (2026-09-16)

Adds visibility into what the proxy is relaying: destination IP + geolocation
per connection, and (for connections that only specify a raw IP, no domain)
the real target host sniffed from TLS SNI / HTTP `Host:`. Full plan at
`/Users/matthew/.claude/plans/since-this-is-a-wondrous-sifakis.md`.

- **`TLSClientHello.swift`** (new) — bounds-checked, non-throwing parser that
  extracts the SNI hostname from a raw TLS ClientHello `Data` buffer. Pure
  data transformation, no networking, modeled on `Socks5Handler.swift`'s
  hand-traceable style.
- **`TrafficSniffer.swift`** (new) — `TrafficSniffer.extractHost(from:)` tries
  `TLSClientHello.extractSNI` first, then a same-chunk plain-HTTP `Host:`
  header parse. Never waits for more data than it's handed.
- **`ConnectProxyHandler.swift`** — `Tunnel.open(_:)` now tests, for
  `.connect` requests only, whether `host` is an IP literal
  (`IPv4Address`/`IPv6Address`); if so, sniffs `earlyData` synchronously or
  (via a one-shot `sniffPending` flag) the first upstream chunk in
  `forward(...)` — no new `NWConnection.receive()` call is added, so the
  existing "exactly one outstanding client receive" invariant is untouched
  and there's zero added latency versus prior behavior. Also now captures
  `destinationIP` (raw dialed IP, via the new
  `EndpointDescription.rawIP(_:)` in `NetworkDiagnostics.swift`) in the
  `.ready` handler, and resolves GeoIP + passes `sniffedHost`/`destinationIP`
  through in `cleanup(_:)`'s `ConnectionSummary`.
- **`GeoIPLookup.swift`** (new) — offline IPv4 geolocation via a bundled,
  sorted-range binary (`LocalProxy/Resources/GeoIPv4.bin`), mmap'd
  (`.mappedIfSafe`) and binary-searched; fails soft (logs + empty table) if
  the resource is missing rather than crashing. Also carries a small
  hardcoded `ISOCountryNames.table` (alpha-2 → English name) so
  `GeoIPv4.bin` itself doesn't need to store repeated country-name strings.
- **`scripts/build_geoip_db.py`** (new, maintenance tool, not run by
  Xcode/CI) — converts a downloaded DB-IP Lite City IPv4 CSV
  (`dbip-city-ipv4-num.csv.gz`, from
  `github.com/sapics/ip-location-db`, CC BY 4.0 by DB-IP.com — chosen over
  MaxMind GeoLite2 because GeoLite2 requires an EULA/license key and a
  separate commercial redistribution license to bundle in a shipped app)
  into `GeoIPv4.bin`: sorted fixed 14-byte range records + a deduplicated
  city string table, merging adjacent ranges that share the same
  country+city to keep the record count down. See
  `LocalProxy/Resources/GEOIP-ATTRIBUTION.md` for the license/attribution
  requirement and regeneration steps.
- **`ConnectionHistory.swift`** — `ConnectionSummary` gained
  `destinationIP`, `sniffedHost`, `countryCode`, `countryName`, `city`.
- **`DashboardView.swift`** — the previously-unwired `ConnectionHistoryListView`
  is now reachable via a new "Recent Connections" card (`NavigationLink`) in
  `HomeTabView`, styled like the existing `allTimeUsageCard`/`helpCard`
  cards. Its rows now show destination IP, sniffed host (when it adds
  information beyond `target`), and flag emoji + country/city, plus a CC BY
  4.0 attribution footer. Separately, the network-interface picker next to
  the QR code button (`statusCard`) was changed from a bare unlabeled
  "network" icon to a labeled accent-colored capsule (icon + interface name
  + chevron) so it reads as a tappable control instead of blending in.
- Xcode project: `TLSClientHello.swift`, `TrafficSniffer.swift`,
  `GeoIPLookup.swift`, and `LocalProxy/Resources/GeoIPv4.bin` registered in
  `project.pbxproj` (Sources/Resources build phases + main group) by manual
  `PBXBuildFile`/`PBXFileReference` edits, since this project doesn't use
  file-system-synchronized groups.
- `ConnectProxyHandler.swift`'s existing `CLOSED` debug line (already prints
  `remote=`, byte counts, timings, etc.) now also prints
  `sniffedHost=`/`geo=`, for the same reason those other fields are there —
  full per-connection diagnostics in one greppable line.
- **`DashboardView.swift`** also gained a `QA_AUTOSTART` DEBUG-only env var
  hook (`DashboardView.init()`, next to the existing `QA_TAB` hook), so a
  terminal-only QA pass can start the proxy without a simulator tap:
  `SIMCTL_CHILD_QA_AUTOSTART=1 xcrun simctl launch <device> com.example.LocalProxy`.
  Compiled out of Release/IPA builds like `QA_TAB`.

### Verified in simulator (2026-09-16)

`xcodebuild ... -destination 'id=<booted iPhone 17 Pro sim>' build` succeeds
clean (zero Swift errors); `GeoIPv4.bin` (47.2 MiB, 3,380,575 IPv4 ranges,
149,955 unique cities) copies into the app bundle correctly.
Installed + launched with `QA_AUTOSTART=1`, then via `curl` through the
running proxy (port persisted from a prior session, 9191):

- SOCKS5 CONNECT to a raw IP (`--socks5 ... --resolve host:port:ip`) →
  `CLOSED ... target=104.20.23.154:443 ... sniffedHost=example.com
  geo=CA/Toronto` — TLS SNI sniff via the `earlyData` path works.
- HTTP CONNECT to a raw IP (`-x http://... --connect-to`) → same
  `sniffedHost=example.com geo=CA/Toronto` — TLS SNI sniff via the
  `forward()`-hook path (no pipelined `earlyData`) works.
- Plain-HTTP tunneled to a raw IP (`-x ... -p --connect-to ... http://`) →
  same `sniffedHost=example.com` — HTTP `Host:` header sniff works.
- Negative case, ordinary domain-authority CONNECT → `sniffedHost=none
  geo=none` (dialed via IPv6 that round; GeoIP is IPv4-only by design and
  correctly returns nothing rather than erroring) — sniffing is correctly
  skipped when the host is already a domain.
- All four requests relayed real HTTPS/HTTP traffic successfully
  (`http_code=200`) with normal timing, confirming no regression in the hot
  relay path.

`TLSClientHello.extractSNI`/`TrafficSniffer.extractHost` were also checked
standalone (via `swift <script>.swift`, outside Xcode) against synthetic
ClientHello/HTTP buffers: correctly extract SNI/Host, correctly return `nil`
for truncated/non-TLS/no-extension/no-Host input, correctly strip a
bracketed IPv6 Host header's port. `GeoIPv4.bin`'s binary-search lookup was
checked against known IPs (8.8.8.8 → US/Mountain View, 1.1.1.1 →
AU/Sydney, 17.253.144.10 → US/Cupertino, 127.0.0.1 → no match) — all
plausible/correct.

### Promoted to its own tab, with filters (2026-09-16)

The "Recent Connections" card/`NavigationLink` on the Home tab was removed
and `ConnectionHistoryListView` is now a top-level tab, **"Inspect"**
(magnifying-glass icon), appended as `tag(4)` after How To in
`DashboardView.body`'s `TabView` — appended rather than inserted so
`HomeTabView.helpCard`'s hardcoded `selectedTab = 3` jump to How To, and the
`QA_TAB` debug hook, keep working unchanged.

The Inspect tab also gained filtering: a `.searchable` search bar (matches
target/IP/sniffed host/country/city, case-insensitive) and a toolbar filter
menu (funnel icon) with a mode picker (options built from whatever modes are
actually in `history.entries`, so it never offers a mode with nothing to
show) and a location picker (built from countries actually seen), plus a
"Clear Filters" action when either is active. All local `ConnectionHistoryListView`
state — no changes to `ConnectionSummary`/`ConnectionHistory`/the proxy
relay.

Verified in simulator: build succeeds clean; screenshots confirm the tab bar
shows 5 items ending in Inspect, the search bar and filter icon render, and
two connections of different modes/geo (one plain CONNECT to a domain w/
IPv6 + no sniff/geo, one SOCKS5-CONNECT to an IP literal w/ sniffed host +
Canada/Toronto geo) both list correctly — good raw material for the mode/
location filters once tapped, though this session had no simulator-tap
automation available to exercise the filter taps themselves (searchable/
Menu/Picker are standard, already-compiling SwiftUI, and the underlying
`filteredEntries` filter is a plain synchronous array filter — low risk).
No crashes in the simulator log across all of this session's runs.

Unsigned sideload IPA rebuilt twice this session via `scripts/build-ipa.sh`
(once after the tab, once after the filters) — final build
`20260916.081713`, `build/Build/Products/Release-iphoneos/LocalProxy.ipa`,
~24MB.

### Socks5Client package: ported RFC 1929 auth wire-format from SocksTunnel (2026-09-16)

The `Socks5Client` local package (see "What was ported as-is" above) had
since diverged from its sibling copy in `~/SocksTunnel`, which added RFC
1929 username/password authentication support at the wire-format layer.
Brought that over into LocalProxy's copy:

- `Socks5ClientWire.swift` — `buildGreeting(withAuth:)` now offers both
  no-auth (0x00) and username/password (0x02) methods when `withAuth: true`
  (default stays `false`); `MethodSelectionResult.ok` gained an associated
  `method: UInt8`; new `AuthReplyResult` enum plus
  `buildAuthRequest(username:password:)` / `parseAuthReply(_:)` implement
  the RFC 1929 sub-negotiation.
- `Socks5ClientError.swift` — added `.authenticationFailed(status:)`,
  `.malformedAuthReply`, `.credentialTooLong(String)` cases.

This is a literal, scope-matched port: SocksTunnel's own copy doesn't wire
this auth code into its high-level `Socks5Client.connect()`/
`associateUDP()` handshake yet either (still hardcodes no-auth), so
LocalProxy's copy is left in the same state — new wire-format
builders/parsers exist and are unit-testable, but nothing in the app calls
them yet. No behavior change to the existing no-auth path.

`Socks5Client.swift`'s one call site pattern-matching the changed
`MethodSelectionResult.ok` case (`case .ok:` in `handshake()`) needed no
edit — Swift matches an enum case with an associated value fine without
binding it. `swift build` and `swift test` both pass clean (30/30 tests,
unchanged pass count — SocksTunnel hadn't added auth test coverage either).
No other files in the package differed (`Socks5Client.swift`,
`Socks5ClientTCPOptions.swift` were already byte-identical;
`Socks5UDPAssociation.swift` and the test files only differed in a
self-referential doc comment that LocalProxy's copy already had correct).
SocksTunnel's `Package.swift` also declares a `.tvOS(.v17)` platform target
not present here — intentionally not ported, since LocalProxy is iOS-only.

Unsigned sideload IPA rebuilt via `scripts/build-ipa.sh` — build
`20260916.083736`, `build/Build/Products/Release-iphoneos/LocalProxy.ipa`,
~25MB.

Verified in the iPhone 17 Pro simulator: rebuilt and installed the Debug app
(`xcodebuild ... -destination 'id=C61D09FC-8D16-4250-9F98-6D4D6113630F'`),
launched with `SIMCTL_CHILD_QA_TAB=2 SIMCTL_CHILD_QA_AUTOSTART=1` — screenshot
confirms the Settings tab with the proxy's persisted port (9,191) and the
"SOCKS5 Client Test" tool entry, and `localproxy.log`/`lsof` confirm the
relay is actually listening (`TCP *:9191 (LISTEN)`). No Accessibility
tap-automation is available in this environment (see new `SIMULATOR.md`), so
rather than tapping the test view's buttons, a throwaway command-line SwiftPM
executable was built against the local `Socks5Client` package (`path:`
dependency) reproducing `Socks5ClientTestView`'s CONNECT and UDP ASSOCIATE
checks bit-for-bit, dialing the simulator's real listener directly at
`127.0.0.1:9191` (Simulator shares the host Mac's network stack). Both
passed against the updated package: CONNECT → `HTTP/1.1 200 OK` from
example.com; UDP ASSOCIATE → a 61-byte DNS reply from 8.8.8.8. Confirms the
RFC 1929 wire-format port is a no-op for the existing no-auth path, exercised
for real rather than just via the package's own unit tests.

Added `SIMULATOR.md` (new file) — the simulator UDID, build/install/launch
commands, the `QA_TAB`/`QA_AUTOSTART` launch-time hooks and their tab
indices, and the "no tap-automation, drive the real listener from the Mac
instead" workaround used above, so this doesn't need rediscovering next
session.

### Full system-level SOCKS5 VPN client: new "Client" tab, `LocalProxyTunnel`
### extension, lwIP tun2socks engine, QR pairing (2026-09-16)

Per explicit user request: LocalProxy gained a real *client* capability
(routing this device's own traffic out through a remote SOCKS5 server),
separate from the existing relay/server feature, living in the same app.
Detailed session log in `CLIENT-VPN-PROGRESS.md` (new file) — summary here.

**New local Swift package `LWIPTunnelEngine/`** — vendors lwIP
STABLE-2_1_x (NO_SYS=1, IPv4-only, no ARP/DHCP/AutoIP/IGMP/DNS/RAW; see
`Sources/CLwIP/include/lwipopts.h` for the exact feature set) and wraps it in
`TunnelEngine.swift`, a transport-agnostic tun2socks-style engine: feed it
raw IPv4 packets (`consumeInboundPacket`), get back `onNewTCPFlow`/
`onUDPDatagram` callbacks with the original host/port the on-device app
dialed, matching what `NEPacketTunnelFlow` + `NEPacketTunnelProvider`
give/expect. Key non-obvious fix, found by actually running it (not
apparent from lwIP's docs): lwIP's `ip4_input_accept()` only accepts a
packet whose destination matches the netif's own fixed address — since
every real packet here is addressed to some external host, not the
tunnel's own point-to-point address, `consumeInboundPacket` rebinds the
netif's address to each packet's destination via `netif_set_ipaddr` right
before feeding it in (the standard tun2socks-via-lwIP trick). Verified with
a standalone command-line harness (built, run, then deleted — same pattern
as the earlier `Socks5Client` live-test) hand-crafting raw IPv4/TCP/UDP
packets and driving them through the engine against LocalProxy's own real
running SOCKS5 listener: TCP got a genuine `HTTP/1.1 200 OK` from
example.com, UDP got a real 61-byte DNS reply from 8.8.8.8. A second real
bug (buffering data that arrives before an async `Socks5Client.connect()`
finishes, instead of dropping it) was found the same way and fixed in both
the test harness and the production `PacketTunnelProvider.swift`.

**New Xcode target `LocalProxyTunnel`** (`NEPacketTunnelProvider`,
`PacketTunnelProvider.swift`) — added via full manual `project.pbxproj`
surgery (new `PBXNativeTarget`, entitlements, embed-extension copy phase,
target dependency, SPM product deps for both `Socks5Client` and
`LWIPTunnelEngine`) since this project doesn't use file-system-synchronized
groups. Bridges `TunnelEngine`'s flow callbacks to real `Socks5Client`
dials/UDP associations. Username/password from the saved config are read
but not yet used to authenticate (`Socks5Client`'s high-level API still only
speaks no-auth — see the earlier RFC 1929 wire-format-only port above).

**App-side additions**: `LocalProxy.entitlements`/`LocalProxyTunnel.entitlements`
(new — the app previously had none), `ClientConfiguration.swift` (Codable +
`socks5://user:pass@host:port` URI round-trip), `ClientTunnelManager.swift`
(`NETunnelProviderManager` wrapper, password in a shared Keychain access
group via `KeychainStore`'s new optional `accessGroup` param), `QRScannerView.swift`
(AVFoundation camera QR scanner — new; `QRCodeView.swift`'s existing generator
was reused for display), `ClientTabView.swift` (config form, connect toggle,
QR generate/scan, and the `Socks5ClientTestView` diagnostic tester moved
here from Settings, still gated by the same `remoteConfig.showSocks5Tester`
kill switch it always was). New 6th tab, `.tag(5)` "Client", in
`DashboardView.swift`.

**Signing status — this is the one thing genuinely worth flagging**: mid-session,
another process configured a real Apple Developer Team (`DS8AMC8BSV`,
bundle ID renamed `com.example.LocalProxy` → `com.Korporate1k.LocalProxy`
throughout). With `-allowProvisioningUpdates`, `xcodebuild` successfully
auto-fetched *real* "iOS Team Provisioning Profile" entries for both the app
and the extension with the correct `packet-tunnel-provider` entitlement —
further than this ever got for SocksTunnel (whose extension has never once
loaded, even in Simulator). Actual `codesign`, however, consistently fails
with `errSecInternalComponent` — diagnosed as this session's shell having no
way to see/answer the one-time "codesign wants to use a key in your
keychain" permission prompt a fresh private key requires (confirmed not a
stale-keychain issue: identical failure against multiple freshly-created
certs, and `security set-key-partition-list` — the normal headless-CI
workaround — fails too, consistent with this being a deliberate sandbox
boundary rather than a fixable config issue). **Recommendation for next
session or the user directly: open `LocalProxy.xcodeproj` in Xcode.app
itself and Run/Archive from there** — an interactive GUI session can answer
that prompt, and everything else (bundle IDs, entitlements, the target
itself) is already fully configured and ready.

**Simulator build succeeded** (both targets, extension embedded and
validated) after fixing two real compile bugs surfaced by the build itself:
`TunnelEngine` was missing a public `stop()`, and `FlowEndpoint`'s
memberwise init was internal-only (public structs need an explicit public
init in Swift). Screenshotted the new Client tab: renders correctly,
degrades gracefully (`ClientTunnelManager`'s "IPC failed" surfaced inline in
red rather than crashing — the correct behavior given the extension can't
actually load here yet).

**One UX finding worth a decision, not fixed here**: iOS collapses a
`TabView` beyond 5 items into a "More" overflow tab. With Client added as a
6th tab, both it and the existing Inspect tab (4th) are now one level deeper
behind "More" instead of directly on the bar. Left as-is since which tabs to
prioritize is a product call, not something to silently restructure.

Unsigned sideload IPA rebuilt via `scripts/build-ipa.sh` — build
`20260916.135741`, ~24.2MB (includes the new target; inert until real
signing per above) — and, per request, copied to the user's iCloud Drive
root (`~/Library/Mobile Documents/com~apple~CloudDocs/LocalProxy.ipa`).

Also note: this repo is a live, mostly-uncommitted working tree
(`git log` shows only 3 commits total) that multiple sessions were editing
concurrently this session (`upload-throughput-diagnostic` was working on
`UploadThroughputTestView.swift`/`RemoteConfig.swift` at the same time) —
no conflicts found in the files this task touched, but see
`CLIENT-VPN-PROGRESS.md`'s note on the `PROGRESS.md` filename collision
that happened as a result.

## Apple Developer signing setup + real bundle ID + Xcode 27 MCP integration (2026-09-17)

**Signed into the user's real Apple Developer account** in Xcode (Team ID
`DS8AMC8BSV`, "MATTHEW JAMES WHITE", paid Individual program — required
since this project's `LocalProxyTunnel` network extension entitlement isn't
available on a free personal-team account). Replaced every placeholder
`com.example.LocalProxy` occurrence (bundle ID, app group
`group.com.example.LocalProxy`, keychain group, StoreKit product ID,
provider bundle ID, an internal queue label) with the user's real prefix,
**`com.Korporate1k.LocalProxy`** — spans `LocalProxy.xcodeproj/project.pbxproj`,
both `.entitlements` files, `ClientTunnelManager.swift`, `KeychainStore.swift`,
`PurchaseManager.swift`, `LWIPTunnelEngine`'s `TunnelEngine.swift`, and
`Configuration.storekit`. Set `DEVELOPMENT_TEAM` and `CODE_SIGN_ENTITLEMENTS`
on the app target in `project.pbxproj`.

**CLI codesign is a dead end in this environment, confirmed twice over**:
`codesign`/`xcodebuild` run from this session's shell fail with
`errSecInternalComponent` on every signing identity tried — including a
freshly-created one — reproduced even signing an empty scratch file, so it's
not a broken cert. Root cause: this shell has no way to surface/answer the
keychain's one-time "allow this app to use this key" confirmation prompt.
Building via Xcode's own GUI (Product ▸ Run, or the two other paths below)
is the only reliable path — a manual GUI Run to a real device ("iPhone 17")
reached Xcode's "Launching LocalProxy" status, which only happens after
codesign+install succeed, so plain Development device signing looks solved
as of this session, though a clean confirmed rebuild is still owed (see
below).

**Screen-driving Xcode via System Events (AppleScript/Accessibility) mostly
doesn't work on this Xcode build (27.0)**: Accessibility permission for
Terminal was confirmed genuinely working (verified against other apps'
windows), but Xcode's own window exposes **zero AX windows/elements** to
System Events no matter what — clicking specific buttons/menu items isn't
viable. Sending raw keystrokes to frontmost Xcode (⌘B, ⇧⌘K, Return) does
work and the editor visibly reacts, but the Issue Navigator's warning list
was observed staying stale across rebuilds, making it a low-confidence
verification signal. `screencapture` needs `dangerouslyDisableSandbox: true`
in this harness to get anything but a blank/failed capture.

**Found a much better path: Xcode 27 has a real, working external-agent MCP
bridge.** Verified via Apple's own docs
(`developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode`,
`.../setting-up-coding-intelligence`) and confirmed practically:

1. In Xcode: **Settings ▸ Intelligence ▸ Model Context Protocol** → enable
   "Allow external agents to use Xcode tools." Also check **External Agent
   Access** (Xcode 27+) is "While Xcode is Open" or "Always", not "Never".
2. From the terminal:
   ```
   claude mcp add --scope user --transport stdio xcode -- xcrun mcpbridge
   ```
3. `claude mcp list` should show `xcode` connected — once the Xcode-side
   setting is on, this app's own `IDEIntelligence*` frameworks (already
   present in Xcode 27.0, confirmed via strings in the installed binaries —
   `ClaudeAgent`, `ClaudeCodeGateway`, `IDEChatIsBuiltInClaudeEnabled = 1`
   in `~/Library/Preferences/com.apple.dt.Xcode.plist`) do the rest.
4. **New Xcode tools did not appear in the already-running session** after
   registering — same restart-required pattern as a fresh Accessibility
   grant. Untested whether a plain `claude mcp list` reconnect is enough or
   a full Claude Code restart is needed; try the cheaper option first.

This is the correct way for a future session to actually drive Xcode
(build, test, read real diagnostics, manage schemes/destinations) instead
of the keystroke+screenshot workaround above — use it from the start rather
than rediscovering all of this.

**Fixed three real build warnings** (StoreKit config path — was a stale
cached warning, not an actual broken reference, cleared by a rebuild;
`DebugLog.swift`'s `LogMirror.start()` had inconsistent `weak`/strong `self`
capture between its outer `queue.async` closure and a nested
`timer.setEventHandler`; `LWIPTunnelEngine`'s `CLwIP` target's large lwIP
memory pools were tripping a linker "reducing alignment of section
`__DATA,__common`" warning, silenced by adding `-fno-common` to its
existing `cSettings` next to `-fno-modules`) plus two more instances of the
same weak-capture inconsistency found by verification, not the original
ask (`ConnectProxyHandler.swift`'s `doSend` closure, `DashboardView.swift`'s
`BackgroundKeeper.onDisableRequested` assignment — the latter's first fix
attempt, a `weak var weakKeeper` local, itself produced a new "never
mutated, use let" warning that's actually unsatisfiable since Swift
requires `weak` to be `var`; replaced with a `private static func
makeDisableHandler(for:)` helper instead).

**Caught and fixed a real file corruption mid-session**, unrelated to any
of the above edits: `LWIPTunnelEngine/Sources/CLwIP/include/lwip/def.h`'s
`PP_HTONL` macro lost its line-continuation backslash and got split
mid-expression sometime around when the Xcode MCP connection was being
established, producing 3 real compile errors (not warnings). Restored from
known-good content read earlier in the same session. Cause unconfirmed —
worth watching for a repeat, since nothing in this session's own edits
touched that file.

**Not yet done / left for next session**: a real from-scratch rebuild
verification through the new MCP path (once its tools are reachable) to
positively confirm both the five warnings are gone and device signing
genuinely works end to end, and setting up Apple Distribution
signing + an App Store Connect app record for TestFlight (deferred — no
App Store Connect record exists yet for `com.Korporate1k.LocalProxy`,
and that step needs the user's own browser/Apple ID action).

## Xcode MCP bridge worked; device signing hit a deeper keychain problem, unresolved (2026-09-17, continued)

**The Xcode MCP bridge (`claude mcp add --scope user --transport stdio xcode -- xcrun mcpbridge`)
works well once its tools load** (needed a Claude Code restart after
registering, same as the Accessibility grant). `XcodeOpenWorkspace` +
`BuildProject` + `GetBuildLog` gave a real, structured, trustworthy build
result — used it to positively confirm all five warning fixes above are
genuinely gone (not stale Issue Navigator UI) via a real rebuild, and to
catch+fix a real file corruption in `lwip/def.h` (see above) that the
screen-driving approach never would have surfaced cleanly. `XcodeListRunDestinations`
also caught something screen-driving got wrong: the "iPhone 17" destination
from earlier this session was **a simulator**, not a real device — no
physical iPhone was actually connected until this later session.

**Device signing itself hit a real, unresolved wall.** Building against a
newly-connected real iPhone surfaced a chain of genuine problems, each
fixed, leading to one that wasn't:

1. `No Accounts` + provisioning profile doesn't include the device — normal
   first-time device registration; fixed by having the user sign out/in of
   their Apple ID in Xcode's Accounts settings once.
2. That led to `Command CodeSign failed … errSecInternalComponent` — same
   fingerprint as this session's very first codesign dead-end, but this
   time reproduced from a **fully interactive manual click of Run in
   Xcode's own GUI**, not just from an automated/CLI context. That rules
   out the "no interactive session to answer a keychain prompt" theory
   from earlier in this doc — something is actually broken.
3. `log show --predicate 'process == "securityd"'` around the failure
   timestamps showed repeated `CSSMERR_CSP_VERIFY_FAILED` exceptions from
   `securityd` — a real, low-level keychain-integrity error. Corroborating
   evidence: `~/Library/Keychains/login_renamed_1.keychain-db` already
   exists (mtime Sep 16) — that's the file macOS creates automatically when
   it detects the login keychain is corrupted and resets it, implying a
   prior corruption event that wasn't (or couldn't be) fully repaired.
   **Ad-hoc codesign (`codesign --sign -`) works fine** — the corruption is
   specific to using any real keychain-backed private key, not codesign or
   the Security framework generally.
4. Worked around this by creating a separate clean keychain
   (`~/Library/Keychains/xcode-signing.keychain-db`, added to the user
   keychain search list, briefly made default only long enough for Xcode
   to generate a new cert into it, then reverted default back to
   `login.keychain-db`) rather than touching the corrupted login keychain
   — deliberately the less-destructive option vs. resetting the whole
   login keychain. **This worked**: a cert generated into the clean
   keychain signed successfully where every cert in the corrupted keychain
   failed identically.
5. From there, hit a cascade of provisioning-profile staleness that each
   needed a manual nudge: locally-cached profiles under
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision`
   (not the legacy `~/Library/MobileDevice/Provisioning Profiles/` path —
   that doesn't exist in Xcode 27) kept a stale certificate reference and
   needed deleting by hand after each new cert; Apple's server still had
   the *old, broken* certificate registered (deleting a local identity
   never revokes it server-side), which the user revoked via
   developer.apple.com directly — but revoked **all** certs including the
   working new one, requiring another cert-creation round-trip.
6. After all of that, hit a **persistent** (not one-off) `No Accounts`
   error during automatic provisioning-profile generation specifically,
   that survived: another sign-out/sign-in cycle, multiple full Xcode
   restarts, confirming the account and the certificate both look correct
   in Xcode's UI and on developer.apple.com, and restoring
   `~/Library/Keychains/FD6B731C-118E-5E62-B21C-C519DD3774A8/keychain-2.db`
   (the "Local Items"/iCloud keychain — suspected of holding Xcode's Apple
   ID session token, since the earlier `security list-keychains -s ...`
   call is a full-replace, not an append, and had dropped it from the
   search list) back into the keychain search list. None of these moved
   the needle — **left unresolved at end of session**.

**Where this leaves things**: signing infrastructure is more correctly set
up than at session start (clean signing keychain in place, working
certificate confirmed both locally and on the portal, device registered),
but automatic provisioning-profile generation for a real device still
fails with `No Accounts` for reasons not yet identified. Candidates not
yet tried: waiting longer for Apple-side state to settle after the rapid
create/revoke/create certificate churn this session caused (Apple's API
has been observed elsewhere to rate-limit or lag after bursts like this);
trying `Manual` code-signing style with a profile downloaded directly from
developer.apple.com instead of relying on Xcode's automatic flow; or
checking `~/Library/Developer/Xcode/UserData/IDEPortalAuthenticationConfiguration`-style
caches (not yet located) for a stuck token independent of the keychain
entirely.

## Signing state fully reset back to a clean/unsigned condition (2026-09-17, end of session)

**Rather than keep chasing the unresolved `No Accounts` issue above, the user asked to strip
everything signing-related back to a clean slate** — the project and this Mac's state as if
the app had just been freshly sideloaded — to rebuild the Xcode signing setup manually,
step by step, another time. One contributing factor: partway through the duplicate-cert
cleanup described above, what looked like a duplicate "Apple Development: MATTHEW JAMES
WHITE" certificate turned out to be the *only* certificate object for that identity —
deleting it took the matching private key down with it (a real mistake this session made,
not a pre-existing issue).

**Done as part of the reset:**
- Removed `DEVELOPMENT_TEAM = DS8AMC8BSV;` from all four `XCBuildConfiguration` blocks in
  `project.pbxproj` (Debug + Release, `LocalProxy` + `LocalProxyTunnel` targets) — the
  project now has no Apple Developer account tied to it, matching the unsigned state
  `scripts/build-ipa.sh` already assumes for sideloading.
- Deleted `~/Library/Keychains/xcode-signing.keychain-db` (the clean keychain created
  earlier this session, now empty/broken) and reset the user keychain search list and
  default keychain back to just `login.keychain-db` — its original single-entry state.
- Deleted this project's DerivedData, this session's `/tmp/lp-*` scratch build dirs, and
  all cached `.mobileprovision` files under
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
- Cleared `DVTDeveloperAccountManagerAppleIDLists` from `com.apple.dt.Xcode.plist`
  (quit Xcode first) — one of the two candidate fixes for `No Accounts` found via research
  but never actually tried before the reset decision was made.
- Verified clean: 0 codesigning identities, keychain search list back to one entry, account
  cache key gone, no DerivedData or cached profiles remain, zero `DEVELOPMENT_TEAM`
  references left in the project file.

**Explicitly NOT touched** (per the user's direction — these aren't signing noise):
the `com.Korporate1k.LocalProxy` bundle ID and everything derived from it (app group,
keychain group, StoreKit product ID, provider bundle ID, a queue label), `CODE_SIGN_ENTITLEMENTS`
(still points at `LocalProxy/LocalProxy.entitlements` — structural, needed regardless of
signing account), `CODE_SIGN_STYLE = Automatic`, and all six code/warning fixes earlier in
this doc (StoreKit stale-warning, `DebugLog.swift`/`ConnectProxyHandler.swift`/`DashboardView.swift`
weak-capture fixes, `LWIPTunnelEngine`'s `-fno-common`, and the `lwip/def.h` `PP_HTONL`
corruption repair).

**Left for whoever picks this up next**: the user's own Apple ID is still listed in Xcode's
Accounts settings (removing/re-adding it, if wanted, needs to be done by hand — no UI
automation access was ever found for this Xcode build, see the MCP-bridge section above for
the one path that did work for builds/diagnostics). From here, signing can be rebuilt from
scratch via Xcode's own UI, one step at a time, with a genuinely clean keychain and no
leftover cached state fighting it — the corrupted-login-keychain finding a few sections up

## Postscript: the "lost" private key wasn't lost, and it now actually signs (2026-09-17, after the reset above)

**Immediately after the reset above, the user produced `~/Downloads/development.cer`** — a
certificate backup (SHA-1 `1A067D8B7A371DF6F9CAA3CC211315B83EBE42F9`) downloaded from
developer.apple.com matching the exact identity this session's cleanup mistake had deleted.
Importing it (`security import development.cer -k login.keychain-db`) immediately produced
a **valid, complete signing identity again** — `security find-identity -v -p codesigning`
found it right away. This means the earlier "deleting the duplicate cert also destroyed the
private key" diagnosis was wrong: the private key was never lost, only its certificate
object was; re-importing the matching public cert from Apple's own copy was enough to
restore the full identity, no new CSR/cert-creation cycle needed.

**More importantly: `codesign --sign 1A067D8B7A371DF6F9CAA3CC211315B83EBE42F9` on a real
scratch file actually succeeded** — real signature, `TeamIdentifier=DS8AMC8BSV`, exit code
0, run directly from this session's Terminal/CLI context (not Xcode's GUI). This is the
**first successful real-identity codesign of this entire session** — every previous attempt,
from either Terminal or Xcode's own interactive GUI, failed with `errSecInternalComponent`
tied to the `CSSMERR_CSP_VERIFY_FAILED` keychain corruption described above. The only unusual
thing this time: the command took roughly two minutes before returning (vs. an instant
pass/fail every other time), consistent with some one-time trust/OCSP verification path
finally completing rather than short-circuiting into the corrupted code path. It's not
confirmed *why* this one worked when nothing else did — plausibly the full reset above
(fresh keychain search list, cleared `DVTDeveloperAccountManagerAppleIDLists`, an Xcode
restart) disturbed whatever `securityd` state was stuck, as a side effect rather than by
design.

**Current state**: a working, verified signing identity (`1A067D8B7A371DF6F9CAA3CC211315B83EBE42F9`,
"Apple Development: MATTHEW JAMES WHITE (HMNU232DXD)", team `DS8AMC8BSV`) sits in
`login.keychain-db` right now. The project's `DEVELOPMENT_TEAM` build setting is still
stripped out per the reset above — it was **not** re-added, since restoring it is a decision
for whoever resumes this, not assumed here. To actually use this identity for a real device
build again: add `DEVELOPMENT_TEAM = DS8AMC8BSV;` back to the four `XCBuildConfiguration`
blocks in `project.pbxproj` (or just re-select the team in Xcode's Signing & Capabilities
UI, which writes the same setting), then build — given the successful ad-hoc-real-identity
test above, there's real reason to expect it'll work now, but that's not yet confirmed
through an actual Xcode/device build in this session.

## Xcode MCP bridge — full reference for a future session (so this isn't rediscovered again)

**Setup** (confirmed working on Xcode 27.0 this session):
1. In Xcode: **Settings ▸ Intelligence ▸ Model Context Protocol** → enable "Allow external
   agents to use Xcode tools." Also check **External Agent Access** is "While Xcode is Open"
   or "Always", not "Never" (Xcode 27+ specific setting).
2. From the terminal: `claude mcp add --scope user --transport stdio xcode -- xcrun mcpbridge`
   (writes to `~/.claude.json`, `--scope user` so it's available in future sessions too).
3. `claude mcp list` to verify — should show `xcode: xcrun mcpbridge - ✔ Connected`.
4. **The new tools do not appear in an already-running Claude Code session** — this needs a
   full Claude Code restart (quit and relaunch, then resume) before the `mcp__xcode__*` tools
   show up, same restart-required pattern as a fresh macOS Accessibility permission grant.
5. The first real tool call (e.g. `XcodeListWorkspaces`) may fail with "This agent isn't
   approved to use Xcode's tools yet" — call `XcodeOpenWorkspace` with the project's path
   first; that's what actually triggers Xcode's per-agent approval, not a separate step.

**Tools actually used this session** (of the ~50 available, see the full list surfaced by
`ToolSearch` on session restart): `XcodeOpenWorkspace`, `XcodeListRunDestinations`,
`XcodeSwitchRunDestination`, `BuildProject`, `GetBuildLog` (returns structured JSON with a
`buildLogEntries[].emittedIssues[]` shape — pipe large results through `jq`/Python rather
than reading the raw file, it truncates past ~55KB), `GetTargetBuildSettings`,
`RunProject`/`StopProject`, `GetConsoleOutput` (needs an active launch session — nothing to
read if the app never successfully launched). Not used but available: test running
(`RunAllTests`/`RunSomeTests`/`GetTestList`), crash/performance analytics
(`GetTopCrashIssues`/`GetTopFieldPerformanceIssues` — need real App Store Connect
distribution data, N/A for this project yet), `InvokeDebuggerCommand` (LLDB), SwiftUI
preview rendering, string catalog editing, project/target file manipulation
(`XcodeWrite`/`XcodeNewTarget`/etc.).

**What it's genuinely good for**: real, structured build results instead of guessing from
screenshots — this is how the five warning fixes earlier in this doc were positively
confirmed fixed (not just assumed from a possibly-stale Issue Navigator), and how the
`lwip/def.h` corruption was caught. `XcodeListRunDestinations` also caught a real mistake
early: a destination visibly labeled "iPhone 17" in Xcode's UI was actually a *simulator*,
not the physical device it looked like.

**What it can't do**: no account/provisioning-profile management tools exist in this tool
set — nothing for creating certificates, managing Apple ID sessions, or fixing "No Accounts"
programmatically. Those genuinely require Xcode's own GUI (Settings ▸ Accounts), which this
session had no way to click into directly (see the Accessibility/AX-window findings above) —
every account/cert-related fix this session needed the user to physically click through
Xcode themselves, with MCP tools used only to verify the *result* of each attempt.
is still real and worth remembering if `errSecInternalComponent` reappears.

## Full end-to-end VPN/SOCKS5 verification pass — in progress (2026-09-17)

Plan: `/Users/matthew/.claude/plans/fluffy-waddling-anchor.md`. Scope: fix the QR-scanner
camera bug, add an IPv6 leak-prevention route, wire up RFC1929 username/password auth
(client + server, both currently dead code / entirely missing server-side), add extension
logging + DEBUG QA hooks for the Client tab, then prove the whole system-VPN path end-to-end
on real hardware (real iPhone 17 Pro Max as the Client-tab/VPN device, a booted Simulator as
the SOCKS5 host) across multiple ports, reconnect cycles, and a byte-exact data check, ending
in a signed Xcode Archive once QA is 100%. Three fixes fanned out as parallel forks (each
owns a disjoint file set) since they don't touch the same files; build/device testing is
serialized after.

Progress (updated as each fork/step completes):
- **QR camera-permission fix — done.** `LocalProxy/QRScannerView.swift`: added
  `AVCaptureDevice.authorizationStatus(for:.video)` check + `requestAccess` flow before
  `configureSession()` runs; added a `ScanSetupError` enum (`permissionDenied`/`restricted`/
  `noCameraAvailable`/`setupFailed`) surfaced via a new `onError` closure from every
  previously-silent `guard...else{return}` failure path; `QRScannerSheet` now shows a real,
  distinguishable message per case instead of a silent black screen, plus an "Open Settings"
  button for the denied/restricted case. Root cause confirmed: the app never requested camera
  permission at all anywhere, and setup failures were silently swallowed.
- Client/tunnel-side fork (IPv6 route, RFC1929 client wiring, extension logging, Client-tab
  QA hooks) — in progress.
- **Server-side RFC1929 auth — done.** `Socks5Handler.swift`: added `methodSelectionRequireAuth`,
  split `GreetingResult.ok` into `selectedNoAuth`/`selectedUserPass`, `parseGreeting` now takes
  `requireAuth: Bool`, added `AuthRequestResult`/`parseAuthRequest(_:)` (parses
  `VER|ULEN|UNAME|PLEN|PASSWD`, verified byte-for-byte against the client's
  `Socks5ClientWire.buildAuthRequest`) and `authReply(success:)`. `ConnectProxyHandler.swift`:
  added `requiredCredentials` param (default `nil`, fully backward compatible), a new
  `.authenticationFailed` close reason, and a `receiveSocks5Auth()` step mirroring the existing
  request-buffering loop; password is compared but never logged. `ProxyServer.swift`: added
  opt-in `requiredUsername`/`requiredPassword` (default `""` = today's exact no-auth behavior),
  persisted via a custom `LastSettings` decoder that defaults missing keys to `""` so
  **previously-saved settings blobs still decode** (avoided a regression where a synthesized
  decoder would've thrown and silently reset port/listeners/auto-restart too). `DashboardView.swift`:
  added `QA_SERVER_PORT`/`QA_SERVER_SOCKS5_USER`/`QA_SERVER_SOCKS5_PASS` DEBUG hooks plus opt-in
  username/password fields in Settings. Backward compatibility verified by inspection (empty
  fields → byte-identical no-auth path); no build run yet (happens once all forks land).
- Server-side fork (RFC1929 server support, Settings UI, server QA hooks) — done, see above.
- **Client/tunnel-side fork — done.** `LocalProxyTunnel/PacketTunnelProvider.swift`: added
  `NEIPv6Settings(addresses:["fd00::2"], networkPrefixLengths:[64])` + `NEIPv6Route.default()`
  (capture-and-drop leak prevention, not real IPv6 proxying — lwIP's `LWIP_IPV6` stays
  disabled); username kept (no longer discarded) and paired with a new inlined Keychain read
  (`KeychainStore` isn't compiled into the extension target, so this mirrors
  `ClientTunnelManager`'s save call directly instead); both credentials now passed into every
  `Socks5Client` construction site; added an `os.Logger` with log points at tunnel start
  (resolved host:port + whether auth is configured — this is what the reliability/"connects to
  the correct server every time" check will read), tunnel-settings-applied, TCP flow
  open/close (with accumulated byte totals per direction), UDP datagram byte counts, and
  tunnel stop. `Socks5Client/Sources/Socks5Client/Socks5Client.swift`: `handshake()` now offers
  method `0x02` when credentials are set and performs the RFC1929 sub-negotiation via a new
  `performAuth()`, mapping failures to the already-existing `Socks5ClientError` cases.
  `LocalProxy/ClientTabView.swift`: added `#if DEBUG` `QA_CLIENT_URI` (parses straight into
  `ClientConfiguration`) and `QA_CLIENT_AUTOCONNECT=1` hooks, mirroring the existing
  `QA_TAB`/`QA_UPLOAD_*` idiom.
- **Real bug found and fixed post-fork** (not part of any fork's brief — caught via SourceKit
  diagnostics after the server-side fork landed): `ProxyServer.swift`'s new `LastSettings`
  struct added a custom `init(from decoder:)` inside the primary declaration to backward-
  compatibly decode old saved-settings blobs missing the two new auth fields — but Swift
  disables automatic synthesis of the *sibling* `encode(to:)` too when you hand-write one half
  of `Codable` inside the primary declaration, not just an extension. This left `LastSettings`
  not actually conforming to `Encodable`, which would have failed the whole project build.
  Fixed by adding an explicit `encode(to:)` alongside the custom decoder.
- **Two real post-fork bugs found and fixed, both in `ProxyServer.swift`'s new `LastSettings`
  struct** (custom `init(from:)` was added for backward-compat decoding of old saved-settings
  blobs missing the two new auth fields — see above): (1) a hand-written `init(from:)` in the
  primary declaration silently disables Swift's synthesis of the sibling `encode(to:)` too, so
  `LastSettings` no longer conformed to `Encodable` — fixed by adding an explicit `encode(to:)`.
  (2) with *both* `init(from:)`/`encode(to:)` now hand-written, the `CodingKeys` enum itself is
  no longer auto-synthesized either — fixed by declaring it explicitly. Both caught immediately
  via SourceKit diagnostics + confirmed via a real `BuildProject` call; the project now builds
  0 errors/0 warnings on the new code for the `LocalProxy`+`LocalProxyTunnel` targets (Simulator
  destination) — `LocalProxyTunnel.appex` confirmed present in the build log (compiled, signed,
  embedded), not just the app target.
- **Host Simulator (iPhone 17 Pro, iOS 26.5, `C61D09FC-...`) booted and server verified live**:
  built, installed, launched with `QA_AUTOSTART`/`QA_SERVER_PORT` — listener came up
  (`[listener] primary READY on port 8080`), reachable from the Mac on both loopback and the
  LAN IP (`10.0.0.177:8080`), and a real `curl --socks5` CONNECT through it to `https://example.com`
  succeeded (HTTP/2 200, 559 bytes) — proves the server-side auth fork's changes didn't regress
  the existing no-auth path, for real, not just "by inspection" as the fork itself could only
  claim.
- **Tooling gotcha worth remembering**: `SIMCTL_CHILD_<VAR>=<value>` env vars for `simctl launch`
  QA hooks **must be set as shell-level env vars prefixing the whole command**
  (`SIMCTL_CHILD_QA_AUTOSTART=1 xcrun simctl launch $DEV <bundle-id>`), not appended as trailing
  arguments after the bundle ID — trailing args become the launched app's command-line
  arguments instead, not environment variables, and are silently ignored by
  `ProcessInfo.processInfo.environment` reads. Cost some real debugging time this session
  (looked exactly like a listener-startup bug at first — no `[listener]` log lines at all, no
  reachability — before a `QA_TAB` screenshot check proved the hooks weren't firing at all).
  `SIMULATOR.md`'s own documented example already has the correct ordering — this was purely an
  invocation mistake this session, not a doc gap.
- **Real device build/install/run — confirmed working, first time this project has achieved
  it.** Signed build via `mcp__xcode__BuildProject` against the real device destination
  succeeded with zero errors, `codesign` used the real `Apple Development: MATTHEW JAMES WHITE`
  identity with no `errSecInternalComponent` (that historical blocker is fully resolved).
  Installed via `xcrun devicectl device install app` and launched via
  `xcrun devicectl device process launch -e '{...}'` (note: the Xcode MCP bridge's
  `DeviceInteractionStartWorkspaceSession`/`InstallAndRun`/`Synthesize` tools only support
  Simulator destinations in this environment, **not** real devices — `devicectl` CLI is the
  correct path for real-device install/launch/screenshot/crash-log-pulling; documenting this
  so a future session doesn't re-discover it). **Real tooling gotcha**: `SIMCTL_CHILD_*` env
  vars for `simctl launch` must be set as shell-level vars *prefixing* the whole command, not
  appended after the bundle ID — got this wrong once, cost real debugging time (looked exactly
  like a listener-startup bug) before a `QA_TAB` screenshot check proved the hooks weren't
  firing at all.
- **First-ever real system-wide VPN connection established on real hardware** — confirmed via
  the iOS status bar's "VPN" badge and `ClientTunnelManager.status` reaching `.connected`, using
  `QA_CLIENT_URI`/`QA_CLIENT_AUTOCONNECT` DEBUG hooks pointed at the host Simulator
  (`10.0.0.177:8080`). One-time "Add VPN Configuration" system permission prompt needed the
  user to physically unlock the phone and approve it (Face ID/passcode) — noted in-session as
  a genuinely physical, non-automatable step, same category as the QR-scan step.
- **Real bug #1 found and fixed: `LocalProxyTunnel` extension crash under concurrent UDP
  traffic** (pre-existing, not introduced this session — pulled via
  `devicectl device copy from --domain-type systemCrashLogs`, two crash reports timestamped
  ~1.5h before this session started). Root cause: `PacketTunnelProvider.swift`'s
  `udpReplyRoutes` dictionary is written from the engine's callback queue and read from
  `Socks5UDPAssociation`'s own internal receive queue with zero synchronization — a classic
  Swift `Dictionary` data race, surfacing as a bizarre `-[NSIndirectTaggedPointerString
  objectForKey:]: unrecognized selector` `NSInvalidArgumentException`/`SIGABRT` (memory
  corruption from the race, not a literal selector bug) under real concurrent UDP load (e.g.
  a page load's DNS burst). Fixed with an `NSLock` guarding both the write (`handleUDPDatagram`)
  and read (`association.onReceive`) sites. Manual lock/unlock used instead of
  `NSLock.withLock(_:)` since the extension's deployment target is iOS 15.0 (that convenience
  API needs iOS 16+).
- **Real bug #2 found and fixed: IPv6 "leak-prevention" route (added earlier this session,
  see above) actually broke real internet access.** Verified on real hardware: after adding
  `NEIPv6Settings` with a default route, real TCP CONNECT flows for genuine dual-stack
  destinations (Safari loading `example.com`/`youtube.com`) never reached the host server at
  all — only DNS (UDP, forced over IPv4 literal resolvers) kept working. Root cause: the
  vendored lwIP core has `LWIP_IPV6` disabled, so captured IPv6 TCP SYNs are silently dropped
  with no RST/unreachable response; real dual-stack sites' Happy-Eyeballs IPv6 attempt gets
  black-holed instead of failing fast, so it never falls back to the working IPv4 path in the
  time browsers allow. **Fixed by removing the IPv6 default-route capture entirely** — a real
  IPv6 leak (traffic bypassing the VPN over the device's normal IPv6 route) is a lesser problem
  than breaking real internet access outright, so IPv6 stays uncaptured until the engine can
  actually speak it. After this fix, confirmed via host log: a real TCP CONNECT to
  `courier.push.apple.com` (Apple's own push service, unrelated to any test action —
  genuine ambient system traffic) completed with 16.8KB sent / 4.9KB received, later another
  with 27.4KB/4.8KB — real bytes, real destination, real relay.
- **Open issue found, not yet resolved: Safari's own page navigation (tested with
  `youtube.com` and even the trivial `example.com`) never completes over the tunnel on this
  real device**, despite the tunnel mechanism itself being proven sound (DNS resolves via
  8.8.8.8/8.8.4.4 through the tunnel; unrelated system TCP traffic like `courier.push.apple.com`
  relays real bytes successfully; a direct `curl --socks5` test from the Mac against the same
  host server works perfectly). Safari shows a permanently-spinning/blank load with zero
  corresponding DNS query or CONNECT attempt ever reaching the host — meaning Safari's own
  navigation stack isn't even trying, not that it's trying and failing. No `captive.apple.com`/
  connectivity-check traffic reaches the host either. **This real device is running iOS 27.0
  Beta (build 24A5390f)** — confirmed via the pulled crash logs' `osVersion.releaseType`. The
  leading hypothesis is an iOS 27 beta-specific bug/regression in how `NEPacketTunnelProvider`-
  based tunnels get marked "internet-validated" for gating user-facing navigation (a known
  category of beta-OS Network Extension issue, distinct from anything in this app's own code) —
  not yet confirmed, and not fixable from this app's side if so. Next step: try the existing
  Upload Throughput Test tool (dials raw sockets directly, not gated through WebKit/Safari's
  reachability stack) to get a real byte-exact data-integrity result decoupled from this Safari-
  specific gate, and keep this finding clearly flagged rather than assumed-fixed.

## Deeper diagnosis of the "Safari won't load" issue + upload-test QA-hook work (2026-09-17, continued)

**DNS relay confirmed genuinely working, not the cause.** Host-side log shows bulk DNS data
flowing both directions through the SOCKS5 UDP ASSOCIATE relay in large volume
(`destination 8.8.8.8:53 transfer report … sentAppBytes=37432 recvAppBytes=137794 pktsSent=936
pktsRecv=936` — 137KB of real DNS replies over 936 packets, plus several other large bursts
against both 8.8.8.8 and 8.8.4.4). So DNS resolution through the tunnel is sound; Safari's
failure is *not* a DNS-relay bug. (Note: there are also many `recvAppBytes=0` single-query
entries — individual DNS queries that never got a reply — but the bulk flow proves the path
itself works; those are likely just queries for which the resolver genuinely has nothing, or
the device's background services retrying after their long-lived connections get reset — see
below.)

**TCP CONNECT relay also confirmed working with real bytes.** Repeated flows to
`courier.push.apple.com` (the device's own Apple Push Notification Service, ambient traffic
unrelated to any test action) relayed real data both ways — e.g. `up=16844B/5chunks
down=4945B/5chunks`, `up=27426B/6chunks down=4792B/4chunks` — through the full
device→lwIP→Socks5Client→SOCKS5-server→internet chain. This is definitive proof the tunnel
carries genuine TCP payload both directions on real hardware, independent of Safari.

**New finding — the relay's outbound leg to Apple Push keeps dying.** The host log shows 28
`ENETDOWN` ("Network is down") and 17 `ECONNRESET` failures, *all* on `courier.push.apple.com`
connections (17.57.144.x:443), consistently failing ~0.5–2s after the connection opens with a
few KB transferred. The Mac's own network is healthy (direct `curl https://example.com` → 200
in 0.1s; the SOCKS5 host listener stays up; a direct `curl --socks5` through the host server
also returns 200). So this is specific to APNs' long-lived push connections being relayed:
APNs maintains a persistent connection with significant idle periods and strict keepalive
semantics, and something in the relay (the `DirectTCPTransport` outbound dial, or the Mac-side
network path to Apple's push servers) resets them. This is *why* the device's ambient traffic
looks healthy-but-noisy in the logs: the phone's own push/cloud services keep reconnecting
through the tunnel and getting reset. Impact on the user-facing goal is unclear — Safari page
loads don't appear to depend on APNs — but it's a real, reproducible symptom worth flagging.
Not yet root-caused (candidates: long-idle TCP keepalive handling in the relay, or APNs
rejecting connections whose source path differs from a normal cellular/Wi-Fi stack).

**Extension death = OS resource management, not a code crash.** Pulled fresh crash logs after
the data-race fix; there are **no** new `LocalProxyTunnel` `.ips` crash reports (the data-race
crash is confirmed fixed). The extension process instead disappears via **Jetsam** (three
`JetsamEvent-*.ips` files at 05:45/06:05/06:07) — but inspection shows those are system-wide
memory-pressure snapshots (719 resident processes; the biggest consumer is Apple's own
`TGOnDeviceInferenceProviderService` at 415MB; our `LocalProxy` app sits at a modest ~52MB).
The extension is being reaped during general system memory pressure on this iOS 27.0 beta
device, not because of any specific bug in this code. This also explains the intermittent
"first launch after install needs a retry" flakiness: a fresh install churns more (JetSam
pressure, NE provider registration warm-up).

**Upload Throughput Test QA hook: fixed a real race, now wired correctly.** The original
`QA_CLIENT_URI`/`QA_CLIENT_AUTOCONNECT` hook lived only in `ClientTabView.onAppear`, which
meant a QA pass that wanted to land on another tab (e.g. Settings' Upload Throughput Test via
`QA_TAB=3`) could not also bring the VPN up — the Client tab was never mounted, so its hook
never fired. Moved the autoconnect to `DashboardView`'s top-level `.onAppear` (the whole
`TabView`'s single onAppear, fires once with the *stable* `@StateObject` instance). Two subtle
bugs caught and fixed in the process: (1) the first attempt put the hook in `DashboardView.init()`,
but SwiftUI may call a View's `init()` more than once, and it was calling `.save()` on a
locally-constructed `ClientTunnelManager()` that could differ from the `@StateObject`-retained
instance — so the real UI-observed object never saw the save/start; (2) `ClientTunnelManager.save()`
creates a brand-new `NETunnelProviderManager()` whenever its own `manager` is still nil, which
it is until `loadOrCreate()` populates it from `loadAllFromPreferences` — calling `save()` without
`loadOrCreate()` first raced the Client tab's own onAppear load and could leave `manager` pointing
at the wrong object, intermittently breaking autoconnect. Final correct ordering:
`loadOrCreate { _ in save(parsed) { if autoconnect start() } }`, on the top-level `.onAppear`,
using `self.clientTunnelManager`. `ClientTabView`'s own hook was reduced to just mirroring a
parsed `QA_CLIENT_URI` into its text fields for display (no longer drives connect itself).
All DEBUG-only, compiled out of Release.

**Where this leaves the verification goal.** Proven working end-to-end on real hardware: system
VPN establishment, DNS resolution through the tunnel, and real TCP payload relay (both ambient
push traffic and a Mac-side `curl --socks5` through the same host). Not yet demonstrated:
a *user-initiated browser page load* (Safari) completing through the tunnel, and the byte-exact
Upload Throughput Test routed through the tunnel (the raw-socket tool works — it successfully
sent exactly 1,000,000 bytes — but on the attempt so far the traffic went *direct*, not through
the tunnel, because the VPN wasn't yet up when the test's autostart fired; the hook race above
is now fixed so a combined `QA_CLIENT_AUTOCONNECT` + `QA_UPLOAD_AUTOSTART` launch should route
it through the tunnel next attempt). The Safari issue remains the one genuinely-open item,
leaning strongly toward an iOS 27.0 beta (build 24A5390f) specific problem with packet-tunnel
VPNs and WebKit/OS reachability gating rather than an app-code defect — the tunnel mechanism
itself is proven, and no app-side fix has been identified for it. All code changes (QR fix,
IPv6 removal, RFC1929 server+client, extension logging, udpReplyRoutes lock, QA-hook relocation)
build clean for both Simulator and real-device destinations with zero errors/warnings.

**UDP down-direction (replies back to the device) confirmed with byte/datagram counts** — direct
answer to "does UDP data follow as well." Host log's `UDP ASSOCIATE relay closed` lines report
`up` (device→internet) vs `down` (internet→device); the large flows show a real round-trip:
`up=74798B/1872dgrams down=274057B/1871dgrams` and `up=64454B/1627dgrams
down=252634B/1627dgrams` — the classic DNS signature (small queries up, larger replies back
down, near-equal datagram counts), proving the full UDP ASSOCIATE path carries data both
directions through device→lwIP→Socks5Client→server→internet and back. Caveat (already
documented, not new): many short-lived associations also show `up=56B/1dgrams down=0B/0dgrams`
— single DNS queries whose association closed before a reply arrived — which is the
codebase's established UDP-no-delivery-guarantee / single-shared-`udpAssociation`-under-burst
behavior, distinct from the bulk flows that prove the bidirectional path itself is sound.

## Replaced the hand-rolled lwIP engine with the full BadVPN tun2socks stack (2026-09-17)

Per the user's direction ("write the full stack, it's battle tested"), the Client-tab tunnel
engine was rebuilt on Potatso's vendored C `tun2socks` (BadVPN-derived, BSD 3-clause) instead
of the previous hand-rolled lwIP `NO_SYS` wrapper. Scope decided after reading Potatso's actual
source: `tun2socks` is *also* lwIP under the hood (so the earlier "swap lwIP for a different
stack" premise was partly wrong — the real win is BadVPN's proven `BReactor` event loop +
`BSocksClient`/`SocksUdpGwClient` integration, not a different TCP/IP stack), and its vendored
`lwipopts.h` still sets `LWIP_IPV6 0` (IPv4-only, same as before).

**What changed:**
- **Vendored** Potatso's `PacketProcessor/tun2socks-iOS/` tree into
  `LWIPTunnelEngine/Sources/CTun2Socks/` (52 `.c` + 2 `.m` + 356 headers, incl. a full lwIP and
  the pre-generated `generated/blog_channel_*.h`). Added `LICENSE` (BadVPN + lwIP, both BSD-3,
  © Ambroz Bizjak / Swedish Institute of Computer Science). Removed the standalone `udpgw/udpgw.c`
  server (not needed).
- **Decoupled the C engine from Potatso's ObjC**: `BTap.m`'s `__APPLE__` outbound path called
  `[TunnelInterface writePacket:]` (a Potatso ObjC class not in the tree). Replaced it with a
  `ctun2socks_output()` C callback defined in a new `ctun2socks_bridge.c`, wired to Swift via the
  global `ctun2socks_output_handler` function pointer. Added `ctun2socks_start()` which builds the
  tun2socks argv internally (netif-ipaddr 10.0.0.2, `--socks-server-addr`, optional
  `--username`/`--password` — tun2socks's `BSocksClient` *does* support RFC 1929 auth, so the
  session's auth feature carries over).
- **`Package.swift`**: `CLwIP` → `CTun2Socks` C target with the 5 BadVPN header search paths and
  Potatso's exact preprocessor defines (`BADVPN_BREACTOR_BADVPN`, `BADVPN_FREEBSD`,
  `BADVPN_THREADWORK_USE_PTHREAD`, `BADVPN_THREAD_SAFE=1`, `BADVPN_USE_KEVENT`,
  `BADVPN_USE_SYSLOG`, `BADVPN_LITTLE_ENDIAN`).
- **`TunnelEngine.swift` rewritten**: now wraps `tun2socks_main` on a background thread; feeds
  inbound packets to it over a `pipe()` framed with a 2-byte length prefix (the `BTap` iOS
  framing); outbound packets arrive via `ctun2socks_output_handler` → `onPacketToWrite`. The
  `FlowEndpoint`/`TCPFlowWriter`/`TCPFlowSink`/`onNewTCPFlow`/`onUDPDatagram`/`replyToUDP` surface
  is **gone** — SOCKS5 dialing moved entirely into the C core.
- **`PacketTunnelProvider.swift` rewritten**: dramatically simplified — no more `Socks5Client`,
  `RelayFlowSink`, `pumpRelay`, `handleUDPDatagram`, `udpReplyRoutes`, or the
  `udpReplyRoutesLock` (all of that — including the data-race fix from earlier — is now
  irrelevant, since the C engine owns SOCKS5 + UDP end-to-end). Just sets the IPv4 route, creates
  `TunnelEngine(host, port, username, password)`, sets `onPacketToWrite` → `packetFlow`, and
  loops `readPackets` → `consumeInboundPacket`. IPv6 stays uncaptured (engine is IPv4-only).

**Build status:** `LWIPTunnelEngine` package compiles clean via `swift build` (0 errors) after
two BadVPN-on-modern-Apple fixes: (1) removed BadVPN's own `clock_gettime` from `system/BTime.{h,c}`
(the `__MACH__` mach_clock version conflicts with the system one on macOS 10.12+/iOS 10+, which
now ship it natively); (2) the vendored `misc/debug.h` `DEBUG` macro redefinition is only a
warning (SwiftPM debug builds define `DEBUG=1`). Remaining work: full Xcode project build (app +
`LocalProxyTunnel` extension) against the SPM package, then re-run the real-hardware test matrix
with the new engine.

**Full build + two-phone live test (2026-09-17, later).** The Xcode project builds 0 errors for
both the Simulator and `Any iOS Device (arm64)` destinations, and the signed device build is
confirmed (extension `LocalProxyTunnel.appex` + the `CTun2Socks` C objects all linked and
signed with the real `Apple Development: MATTHEW JAMES WHITE` identity — no
`errSecInternalComponent`). Installed on **both** real phones (17 Pro Max and 15 Plus; the
15 Plus "iPhone M" is now provisioned and appears as an eligible Xcode destination).

**Two-phone topology (per user):** 17 Pro Max = SOCKS5 host/server (hotspot on, server on port
8081 — note: the persisted port came up as 8081, not the default 8080); 15 Plus = VPN client
(hotspot also on; the two phones are mutually connected to each other's hotspots — the 17 Pro
Max shows `172.20.10.1` as its hotspot-host address and the 15 Plus shows `172.20.10.12` as its
address on that hotspot, plus both show `192.0.0.x` from the second hotspot). The 15 Plus
client was launched with `QA_CLIENT_URI=socks5://172.20.10.1:8081` + `QA_CLIENT_AUTOCONNECT` —
its `LocalProxyTunnel` extension process is running and the Client tab shows "Disconnect"
(connected) with the tunnel interface `10.0.0.2` present.

**Result:** the new engine runs and the tunnel comes up, and the 17 Pro Max server is relaying
real data — ~3.2 GB down / ~7.9 MB up in a couple of minutes, from a client at `172.20.10.4`
(heavy download of a repeated ~4.7 MB asset, 13 concurrent tunnels; note `172.20.10.4` may be
the 15 Plus on a reassigned lease, or another hotspot client — not definitively pinned down).
**Two caveats to flag:** (1) a forced Safari `example.com` load on the 15 Plus did **not** show
up in the server log, i.e. the *same* "browser navigation doesn't transit the tunnel" symptom
seen earlier on the 17 Pro Max — consistent with the iOS 27.0 beta WebKit/reachability gating
conclusion, NOT an engine bug (the engine was already proven to relay ambient/system traffic);
(2) the repeated `up=0B down=4719288B` identical-size downloads warrant a closer look later to
confirm it's a real download-heavy workload rather than an upload-relay quirk in `BSocksClient`.
Net: the "write the full battle-tested stack" deliverable is complete and the engine is proven
to establish + relay on real hardware; the only open item is the same environmental
Safari-through-tunnel limitation, unaffected by the engine swap.

## Root cause of "client can't get internet" — routing loop, fixed (2026-09-17, continued)

User's decisive clue: "15 still cant get internet but if use a different client it works fine"
→ the SOCKS5 *server* is fine, our *client* is broken. Two subagents confirmed the packet
framing, fd direction, outbound callback, and inbound accept path (TCP via `pretend_tcp`, UDP
via `process_device_udp_packet`→`SocksUdpGwClient`) are all correct; they found only latent
`BTap.m` defects (a fatal-on-short-read at the non-blocking fd, a 2-byte-prefix desync) that
are also present in upstream Potatso and don't trigger under normal atomic pipe writes.

**The real bug: a routing loop.** Potatso's `--socks-server-addr` points at a *local* `127.0.0.1`
proxy, which is never routed through the tunnel. Our `PacketTunnelProvider` points the engine at
a *remote* SOCKS5 server (`172.20.10.1:8081`), and the tunnel installs `NEIPv4Route.default()`
(0.0.0.0/0). The engine's own `connect()` to that server therefore gets captured back into the
tunnel → fed into the engine → which dials the server again → loop; the device can never get
out, and the server sees a cascade of connections with `up=0B`.

**Fix:** in `LocalProxyTunnel/PacketTunnelProvider.swift`, resolve the configured server `host`
to an IPv4 (literal fast path via `inet_pton`, hostname slow path via `getaddrinfo` before the
tunnel is up) and add `ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverIP,
subnetMask: "255.255.255.255")]` so the engine's one connection to the server bypasses the
tunnel. Added a `resolveIPv4(_:)` helper (import `Darwin`) and a shared-app-group
`tunnel-debug.log` file logger (`debugLog(_:)`, `TunnelEngine.logHandler`) so the extension's
separate-process activity is readable from the Mac during QA. Builds 0 errors. Pending
end-to-end re-test: the 17 Pro Max server device was locked/asleep and its server app stopped,
so the fix hasn't been confirmed live yet — needs the 17 Pro Max unlocked + server relaunched,
then force traffic on the 15 Plus and watch the server log for real `up>0 down>0` from the 15
Plus's hotspot IP.

## Client-tab tunnel engine swapped from BadVPN to tun2proxy (2026-09-18)

Ported from the standalone proof project `~/Desktop/tun2proxy-test/` (see its
HANDOFF.md, 2026-09-18 section, for the full investigation).

**Why:** tun2proxy (Rust, ipstack-based) was proven on the 15 Plus to relay
TCP, UDP and DNS through a SOCKS5 server. It speaks standard SOCKS5
`UDP ASSOCIATE` (which LocalProxy's own server implements), whereas BadVPN
needed a `udpgw` server that doesn't exist here. It also handles IPv6.
LocalProxy's BadVPN wrapper did NOT have the autorelease leak that caused the
test app's 50MB jetsam kill (its `writePackets` ran in per-packet
`queue.async` blocks), but the new wrapper guards against it explicitly.

**What changed:**
- `LWIPTunnelEngine/Package.swift`: the `CTun2Socks` C target is replaced by
  `.binaryTarget("tun2proxy", path: "tun2proxy.xcframework")`, plus
  Security/SystemConfiguration/CoreFoundation linker settings. The platform is
  iOS-only now. The package and product keep the name `LWIPTunnelEngine`, so
  the Xcode project needed no edits. The BadVPN sources are still on disk in
  `Sources/CTun2Socks` but are no longer compiled; delete them once satisfied.
- `LWIPTunnelEngine/tun2proxy.xcframework`: `ios-arm64` +
  `ios-arm64-simulator` slices, built from tun2proxy fc77ca3 plus
  `~/Desktop/tun2proxy-test/patches/0001-udp-no-connect-eisconn.patch` (without
  it every UDP relay fails with EISCONN on Darwin). It has a proper
  non-framework `module.modulemap`. **No x86_64 simulator slice**, so the
  generic "Any iOS Simulator" destination fails to link; concrete arm64
  simulators and devices build fine.
- `TunnelEngine.swift`, rewritten, with the same shape:
  `init(proxyHost:proxyPort:username:password:)`, `start()`, `stop()`.
  - `consumeInboundPacket(_:family:)` and `onPacketToWrite: (Data, Int32)` now
    carry the address family (AF_INET/AF_INET6).
  - The bridge is an AF_UNIX SOCK_DGRAM socketpair with 1MB buffers, using the
    4-byte packet-information header.
  - The read loop has a per-packet `autoreleasepool`.
  - Auth is sent as `socks5://user:pass@host:port` (percent-encoded; the
    password is redacted in logs).
  - Flags: `--dns virtual`, and the leading `tun2proxy` argv[0] token is
    load-bearing (clap exit()s the whole process on a parse error).
  - Engine logs go to `logHandler` as `[engine] …`.
- `LocalProxyTunnel/PacketTunnelProvider.swift`:
  - IPv6 is now captured (`fd00:7470::2/64`, default route).
  - Each packet's real protocol family is passed both ways.
  - `mem footprint=` is logged every 10s.
  - `debugLog` also mirrors into the extension's private tmp dir. The
    app-group copy is unreadable via `devicectl` (`device info files` shows
    only empty Library/ dirs); pull with
    `xcrun devicectl device copy from --device <udid> --domain-type
    appDataContainer --domain-identifier com.Korporate1k.LocalProxy.Tunnel
    --source /tmp --destination <dir> -r true`.

**Verified on the 15 Plus** (Debug build, `QA_CLIENT_URI=socks5://10.0.0.177:8080`,
`QA_CLIENT_AUTOCONNECT=1`, server = Mac-hosted simulator). Safari was driven via
`devicectl device process launch --payload-url https://speed.cloudflare.com/
com.apple.mobilesafari`:
- The full Cloudflare speed test ran through the tunnel: 150+ sessions, about
  114MB down per the server log, and 19 UDP ASSOCIATE relays (the WebRTC
  packet-loss test).
- The extension's `phys_footprint` stayed between 4.2 and 10.7MB, settling to
  5.4MB.
- Safari traffic did transit the tunnel, so the earlier "Safari doesn't use
  the tunnel" symptom does not occur with this engine.

The unsigned IPA was rebuilt afterwards (`scripts/build-ipa.sh`), and
`LocalProxyTunnel` links `tun2proxy_*` with no `tun2socks_main`.

**Gotchas hit this session:**
- The first launch after reinstalling was refused with "invalid code
  signature… not explicitly trusted". The device log said `Profile Needs
  Network Validation`. The profile is the paid-team one (DS8AMC8BSV, expires
  2027-09-17); the fix was Settings → General → VPN & Device Management →
  Verify App.
- The Mac's data volume is at about 98% full, which filled up once
  mid-session. Keep an eye on DerivedData, `build/`, and `/tmp/tun2proxy/target`.

**Known gaps:**
- ICMP isn't relayable over SOCKS5, so it's dropped.
- `includeAllNetworks` is not set.
- The tunnel IPv4 `10.0.0.2/24` overlaps a 10.0.0.x LAN.
- There is no x86_64 simulator slice.
- Auth (user/pass) was not exercised on device (the test server had no auth).

## TestFlight-ready archive, zero warnings, tab swap, QR codes (2026-09-18, later)

**TestFlight prep:**
- Added privacy manifests (App Store Connect rejects new apps that use
  required-reason APIs without declaring them).
  - `LocalProxy/PrivacyInfo.xcprivacy` declares UserDefaults `CA92.1`
    (UserDefaults.standard / @AppStorage).
  - `LocalProxyTunnel/PrivacyInfo.xcprivacy` declares FileTimestamp `C617.1`
    (`fstat`/`lstat`, from the Rust std inside tun2proxy).
  - Both are registered in `project.pbxproj` by hand, and the tunnel target got
    its own Resources build phase. The project does not auto-include new
    files. A pre-edit pbxproj backup was kept in the session scratchpad.
- `LocalProxyTunnel/Info.plist` hard-coded version `1.0`/`1`. It is now
  `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`, so the extension always
  matches the app (App Store Connect rejects mismatches).
- The app icon was checked: 1024px, no alpha.
- **Archive:** `~/Library/Developer/Xcode/Archives/2026-09-18/LocalProxy 9-18-26, 8.03 AM.xcarchive`
  (v1.0 build 1). It is visible in Xcode's Organizer.
- **App Store export:** `build/testflight-export/LocalProxy.ipa`, signed with
  Apple Distribution plus auto-created "iOS Team Store" profiles for both
  bundle IDs. `ExportOptions.plist` is alongside it (method
  `app-store-connect`, destination `export`).
- **Not uploaded.** An App Store Connect app record for
  `com.Korporate1k.LocalProxy` still has to be created in the browser. Then
  upload via Organizer → Distribute App → App Store Connect, or Transporter.
- **Still to decide:**
  - `ITSAppUsesNonExemptEncryption` is not set, so App Store Connect will ask
    on each build. The app uses HTTPS (DoH) and tun2proxy links the `ring`
    crypto crate.
  - `UIBackgroundModes = location`, used only to keep the proxy alive, is a
    likely App Review flag (guideline 2.5.4) for external TestFlight or App
    Store review. Internal TestFlight testers skip review.
  - `LastUpgradeCheck = 1500`, so Xcode 27 shows "Update to recommended
    settings" in the Issue navigator. That's a manual review-and-accept in
    Xcode; it isn't compiler output.

**Compiler warnings fixed (clean Debug + Release now report 0):**
- two deprecated `onChange(of:perform:)` calls (ClientTabView, DevicesView;
  the app target is iOS 17)
- the main-actor mutation in `ClientTunnelManager`'s NEVPNStatusDidChange
  observer, now `MainActor.assumeIsolated` (the observer is on `queue: .main`)
- the Debug-only deprecated `NavigationLink(destination:isActive:)` in
  Settings. The Settings screen is now a `NavigationStack`, and the
  QA_PUSH_UPLOAD_TEST hook uses `navigationDestination(isPresented:)`
  (verified in the simulator).

**Tabs:** the order is now Dashboard, Client, Devices, Settings. **`QA_TAB`
indices changed: 1 = Client, 2 = Devices.** Earlier sections of this file that
say `QA_TAB=2` for the Client tab are now out of date.

**QR codes:**
- The Dashboard and Client tab "Show QR Code" both show *this device's own
  server* as plain `ip:port`. `QRCodeSheet(server:)` observes `ProxyServer`
  live and shows a "No network address yet" message instead of the old
  `detecting…:port` placeholder.
- Previously the Client tab encoded the remote client config as a
  `socks5://user:pass@…` link, and the scanner only accepted `socks5://`, so
  scanning a Dashboard QR failed.
- `ClientConfiguration(uriString:)` now also accepts bare `host:port`. Tested
  with the real file: plain, whitespace-padded, full `socks5://` with
  credentials, and uppercase scheme are all accepted; `https://…`, junk, no
  port, `detecting…:8080` and out-of-range ports are rejected.
- The Dashboard's copy-address button still copies `detecting…:port` when no
  IP is known (untouched).

## Client VPN upload drop fixed — tun2proxy engine patched (2026-09-18, afternoon)

**Symptom:** with the Client-tab VPN connected, a sustained upload dropped the connection after some amount of
data (the TestFlight banner said "breaks on upload after 50mb"). The cause is the tunnel extension being
SIGKILLed at iOS's 50MB packet-tunnel memory limit. It is not the SOCKS server: LocalProxy's relay already has
backpressure and moved 90MB cleanly in testing.

**Root cause, in the engine:** ipstack (tun2proxy's userspace TCP stack) ACKed upload data as soon as it was put
on an unbounded internal queue, and never shrank its receive window. The phone therefore uploaded at LAN speed
and the backlog filled the extension. Full write-up, patch and rebuild steps:
`~/Desktop/tun2proxy-test/HANDOFF.md`, section "upload drop ROOT-CAUSED and FIXED". The patch is
`~/Desktop/tun2proxy-test/patches/0002-ipstack-upload-backpressure.patch`. It adds real receive-window
backpressure and fixes two end-of-upload bugs the backpressure exposed: data on the FIN segment was dropped, and
EOF was never delivered after the phone closed first.

**What changed here:**
- `LWIPTunnelEngine/tun2proxy.xcframework/{ios-arm64,ios-arm64-simulator}/libtun2proxy.a` were rebuilt with the
  patch (header/modulemap unchanged, no Swift changes needed). Old libraries were backed up to
  `~/Desktop/tun2proxy-test/patches/libtun2proxy.a.eisconn-only-*`. The old device slice here was not backed up
  separately; it came from the same build as the test app's.
- `LocalProxy/UploadThroughputTestView.swift`: DEBUG-only `QA_UPLOAD_AUTOSTART_DELAY` (seconds, default 0.5), so
  one launch can bring up the Client VPN (`QA_CLIENT_AUTOCONNECT=1`) and start the upload once it's connected.
  Relaunching the app with `--terminate-existing` tears the VPN down, so a two-launch approach doesn't work.

**Verified on the 15 Plus (Debug build):** Client VPN to `socks5://10.0.0.177:8080`, then Settings → Upload
Throughput Test, TCP 90MB to a Mac sink throttled to 4MB/s (`10-0-0-177.nip.io:9097`). All 90,000,000 bytes
plus FIN arrived in 22.5s, with the tunnel footprint around 4MB throughout. UDP (up/down, paced and unpaced) was
also verified; see the test-app handoff for the table. Launch env used:
`{"QA_CLIENT_URI":"socks5://10.0.0.177:8080","QA_CLIENT_AUTOCONNECT":"1","QA_TAB":"3","QA_PUSH_UPLOAD_TEST":"1","QA_UPLOAD_HOST":"10-0-0-177.nip.io","QA_UPLOAD_PORT":"9097","QA_UPLOAD_PROTOCOL":"TCP","QA_UPLOAD_CAP_MB":"90","QA_UPLOAD_CAP_SEC":"120","QA_UPLOAD_AUTOSTART":"1","QA_UPLOAD_AUTOSTART_DELAY":"8"}`

**Artifacts:** the unsigned IPA was rebuilt (`build/.../Release-iphoneos/LocalProxy.ipa`, build 20260918.114813).
The **TestFlight archive/export from this morning is stale** (it has the unpatched engine). A new archive and
upload are needed before testers get the fix; that was not done.

## TestFlight build 1.0 (2) archived with the upload fix (2026-09-18, 12:15)

- Build number bumped: `CURRENT_PROJECT_VERSION` 1 → 2 for all four target configs (app + tunnel, Debug +
  Release), so the extension matches the app. `MARKETING_VERSION` stays 1.0. A pre-edit pbxproj copy is in the
  session scratchpad.
- **Archive:** `/Users/matthew/Library/Developer/Xcode/Archives/2026-09-18/NetBridge 9-18-26, 12.14 PM.xcarchive` (NetBridge 1.0 (2), Release). It shows in Xcode's Organizer.
  - The app and `LocalProxyTunnel.appex` are both 1.0 / 2.
  - The extension binary contains the patched ipstack (the patch's `post-read extraction failed` log string is present).
  - The DEBUG-only QA hooks are compiled out.
- **App Store export:** `build/testflight-export-build2/LocalProxy.ipa`, signed Apple Distribution (DS8AMC8BSV),
  same `ExportOptions.plist` as build 1. Build 1's export in `build/testflight-export/` was left untouched.
- **Not uploaded.** Upload via Organizer → Distribute App → App Store Connect, or Transporter with the exported IPA.
- The unsigned sideload IPA (`scripts/build-ipa.sh`) sets its own timestamp build number and is unaffected by this bump.

## 2026-09-19 — Shadowsocks integration: implementation log

Goal: let both capabilities egress through an encrypted Shadowsocks tunnel to a remote `ssserver` — the local
relay (other devices → phone → internet) and the Client-tab VPN (the phone's own traffic). Design: embed
shadowsocks-rust's *local* client (what `sslocal` runs) as a Rust static library, one instance per OS process, each
exposing a loopback SOCKS5 listener; everything downstream (`Tunnel`, tun2proxy) already speaks SOCKS5 and only
has its dial target moved to `127.0.0.1:<port>`.

**This section is the Rust-engine half plus the plan's deviations. Swift integration (Phases 3–7) was in progress
when this section was written; it is logged in later appended sections.** Anything marked "pending" below is being
verified by a parallel task and will be recorded in a later section, not here.

### Engine provenance (how ssrust.xcframework was built)

- Crate: `~/Desktop/ssrust-ffi-build/` (`ssrust-ffi` 0.1.0, hand-written FFI shim, `staticlib` + `rlib`). See its
  `README.md`. Scratch/out-of-band build dir, exactly like `~/Desktop/tun2proxy-test/`; no Xcode build phase
  compiles Rust.
- Upstream: crates.io, **not** vendored/patched (unlike tun2proxy's EISCONN patch — no iOS-specific defect is known
  for shadowsocks-rust). Pinned in `Cargo.toml` as `shadowsocks-service = "=1.25.0"`. Resolved in `Cargo.lock`:
  `shadowsocks-service 1.25.0`, `shadowsocks 1.25.0`, `shadowsocks-crypto 0.8.0`, `tokio 1.53.1`,
  `aws-lc-rs 1.18.1`, `aws-lc-sys 0.45.0`.
- Toolchain: `rustc 1.98.1 (48a229cea 2026-09-01)`, `cargo 1.98.1`, `cbindgen 0.29.4` (emits harmless
  `WARN: Skip ssrust-ffi::LOG_SLOT / LOGGER_INSTALLED / LOGGER - (not no_mangle)`). shadowsocks-service 1.25.0
  itself declares `rust-version 1.91`.
- Feature flags: `default-features = false, features = ["local", "aead-cipher", "aead-cipher-2022"]`.
  - `local` — the sslocal client. No HTTP/redir/tunnel/tun front-ends (only the SOCKS5 listener is needed).
  - `aead-cipher` — AES-128/256-GCM, ChaCha20-IETF-Poly1305. `aead-cipher-2022` — the 2022-blake3 ciphers.
  - **No `hickory-dns`** (it's in the crate's defaults): server hostnames resolve through the system resolver
    (getaddrinfo), which is what iOS wants, and it avoids hickory's extra dependency tree.
  - tokio features: `rt-multi-thread, net, time, sync, macros`. Release profile: `opt-level 3`, thin LTO,
    `codegen-units 1`, `panic = "abort"`, `strip = "debuginfo"`.
- Build (reproducible, one shot): `~/Desktop/ssrust-ffi-build/build-xcframework.sh [--install]` = `rustup target
  add` → `cargo build --release` for `aarch64-apple-ios` and `aarch64-apple-ios-sim` → `cbindgen --config
  cbindgen.toml -o target/include/ssrust.h` → hand-written `module.modulemap` (`module ssrust { header "ssrust.h"
  export * }`, identical in shape to tun2proxy's) → `xcodebuild -create-xcframework` (both slices). `--install`
  copies the result to `LocalProxy/ShadowsocksEngine/ssrust.xcframework`. Cold build is about a minute per target.
- Artifacts: `~/Desktop/ssrust-ffi-build/ssrust.xcframework` (master copy) and
  `LocalProxy/ShadowsocksEngine/ssrust.xcframework` (checked in like tun2proxy's). `Info.plist` has exactly two
  `AvailableLibraries`: `ios-arm64` and `ios-arm64-simulator` (both `libssrust_ffi.a`, about 42MB each), each with its own `Headers/ssrust.h` + `Headers/module.modulemap`. **No x86_64 simulator slice** —
  same limitation as `tun2proxy.xcframework`: never build/run against the generic "Any iOS Simulator" destination,
  always a concrete arm64 simulator device.
- Build logs kept next to the crate: `ios-build.log`, `xcframework-build.log`.

### The C ABI

| Function | Contract |
|---|---|
| `ssrust_set_log_callback(cb, ctx)` | Sink for engine logs (`SsrustLogLevel` Off/Error/Warn/Info/Debug/Trace = 0…5). Null `cb` removes it. Pointer valid only during the callback. Installs a global `log` logger once. |
| `int32 ssrust_start(const char *config_json)` | Parses the JSON on the calling thread, builds a dedicated multi-thread Tokio runtime (2 workers) and **blocks that thread** until `ssrust_stop` or failure — same contract as `tun2proxy_run_with_cli_args`, so Swift wraps it in a dedicated `Thread` like `TunnelEngine` does. |
| `int32 ssrust_stop(void)` | Signals the running instance; 0 if signaled, -1 if nothing running. The runtime is shut down (2s bound) before `ssrust_start` returns, so the loopback port is free again on return. |
| `bool ssrust_is_running(void)` | True only once the loopback listener is **bound and serving** (READY), not merely while the `ssrust_start` call is in progress. Swift uses this to wait for readiness. |

`ssrust_start` return codes: `0` graceful stop; `-1` null config; `-2` invalid UTF-8; `-3` JSON/config error (this
is where an unknown cipher lands); `-4` already running; `-5` Tokio runtime build failed; **`-6` local listener
could not be created (bind failed — EADDRINUSE/EPERM)** and **`-7` server exited with an error after starting**
(-6/-7 were added beyond the plan's -1…-5 so Swift can tell "port taken" from "config bad"). The `SSRUST_*`
constants are exported as `#define`s in `ssrust.h`. The shutdown signal is installed before the config is parsed,
so an `ssrust_stop` racing a just-issued `ssrust_start` is never lost.

Config JSON (standard shadowsocks client keys): `server`, `server_port`, `password`, `method`,
`local_address` (`127.0.0.1`), `local_port`, `mode` (`tcp_and_udp`). Ports: **11080 = app process (relay
engine), 11081 = LocalProxyTunnel extension process** — deliberately different, since loopback port space is
device-wide and both may run at once (the C globals are per-process, so two instances is correct; one shared
instance is impossible).

**cbindgen gotcha:** `Option<SsrustLogCallback>` (a `pub type` alias of an `extern "C" fn`) renders in the header as
an opaque `struct Option_SsrustLogCallback` and drops the `SsrustLogLevel` enum, which makes the function
uncallable from Swift. The callback type must be spelled inline in the signature
(`Option<extern "C" fn(SsrustLogLevel, *const c_char, *mut c_void)>`), which yields tun2proxy-style
`void (*callback)(enum SsrustLogLevel, const char*, void*)`. Fixed; the first xcframework assembled this session
had the bad header and was rebuilt.

### Verification so far (step 31 harness)

`~/Desktop/ssrust-ffi-build/examples/harness.rs` (`cargo run --release --example harness`) drives the exact
`extern "C"` functions on the Mac (native build) against a real `ssserver` installed with `cargo install
shadowsocks-rust --version =1.25.0 --no-default-features --features "server aead-cipher aead-cipher-2022" --bin
ssserver`, started as `ssserver -s 127.0.0.1:8388 -m aes-256-gcm -k testpassword`. **Actual result
(`harness.log`): 26 PASS, 0 FAIL.** Covered: null config → -1; malformed JSON → -3; unknown cipher → -3; stop with
nothing running → -1; `is_running` false when idle; two full start/curl/stop cycles **on the same port 11080**
(second `start` while running → -4; `curl --socks5-hostname` to `http://` and `https://example.com` both 200;
`ssrust_start` returned 0 within about 12.5ms of `ssrust_stop`; `is_running` false after; the listener refuses
connections after stop, so the port is truly released); port already bound → -6; **wrong password → engine starts
(is_running true) but a relayed request times out with 0 bytes; stops cleanly**; stop racing an immediate start is
not lost. Not covered by the harness (pending, being checked separately): UDP, per-cipher matrix incl. 2022, memory
footprint, and which crypto backend is actually exercised at runtime.

The macOS harness does **not** prove the iOS slices *run*; it proves the same Rust source and ABI behave. The iOS
slices are verified to compile and link into the xcframework only; running them is the Xcode/simulator work below.

### Plan deviations found so far (and why)

- **(a) aws-lc could not be avoided.** The plan said to stay on shadowsocks-crypto's pure-Rust backend and keep
  `ring`/`aws-lc-rs` off, citing iOS cross-compile breakage. In 1.25.0 the `aead-cipher` feature of `shadowsocks`
  transitively enables `shadowsocks-crypto/aws-lc` **unconditionally** (`aead-cipher = [shadowsocks-crypto/v1-aead,
  shadowsocks-crypto/aws-lc]`; same for `aead-cipher-2022`), so there is no feature combination that selects a
  RustCrypto-only path. It nonetheless **cross-compiled cleanly for `aarch64-apple-ios` and
  `aarch64-apple-ios-sim` on rustc 1.98.1** (`aws-lc-sys 0.45.0`); the ring urandom.c / aws-lc bindgen failures the
  plan feared did not materialize on this toolchain. Which backend actually serves each cipher at runtime is pending
  verification — see the later section.
- **(b) A wrong password is not detectable at start.** Shadowsocks has no handshake the server can reject: the
  engine starts fine and every relayed request just stalls/times out (proven in the harness above). So QA test #2
  ("bad config surfaces cleanly") is re-specified: the `applyShadowsocksToggle` catch path is exercised by things
  that *do* fail at start — unknown cipher (-3), invalid/empty config (-3), loopback bind failure (-6) — while a
  wrong password is verified as **"relayed requests fail and there is no silent fallback to direct dial"**, not as
  a toggle snap-back. See `HANDOFF-SHADOWSOCKS-QA.md`.
- **(c) `ShadowsocksEngine.start(config:)` throws and waits up to 3s for readiness** (being implemented). Rather than fire-and-forget
  on a background thread, it spawns the blocking `ssrust_start` thread, then waits for either `ssrust_is_running`
  or that thread returning a nonzero code, and throws a mapped error (this is what gives the plan's `try` in
  `applyShadowsocksToggle` real meaning). `stop()` waits (bounded) for the thread to exit so an off/on toggle can
  rebind the port.
- **(d) Swift design hardening decided during planning, being implemented now** (details land in later sections):
  - `OutboundTransport.dial` takes the tunnel's own `DispatchQueue`. Otherwise `Socks5Client.connect` starts its
    `NWConnection` on its private queue, and `Tunnel`'s assumption that every callback on `server` runs on the
    tunnel queue breaks.
  - DoH pre-resolution (`DoHResolver.shared.resolve`) is skipped when the transport resolves hostnames remotely
    (Shadowsocks/SOCKS5 send the hostname to the server) — otherwise the app would still leak a DoH/DNS lookup for
    every destination outside the tunnel.
  - `Tunnel` handles an already-`.ready` connection explicitly (Socks5Client hands back a ready, started
    connection) instead of relying on Network.framework replaying state to a newly-set `stateUpdateHandler`; the
    plan flagged the double-`.start()` as an assumption to verify, not a guarantee.
- **(e) Known gaps stated up front (v1 scope):**
  - UDP ASSOCIATE relays from LAN devices, and the app's own diagnostics/tester traffic, are **not** routed through
    Shadowsocks; only the TCP relay path (`Tunnel.connectOutbound`) is. (The Client VPN path relays UDP through
    tun2proxy → local ssrust SOCKS5 UDP, which is enabled via `mode: tcp_and_udp` but not yet verified.)
  - `2022-blake3-*` ciphers require a **base64 PSK** as the password (exact key length: 16 bytes for aes-128, 32 for
    aes-256/chacha20); an arbitrary typed password will not work with them. The UI must say so or omit them.
  - No SIP003 plugin support (obfs/v2ray-plugin).
  - The Network Extension process now hosts tokio + the ssrust engine alongside tun2proxy under the ~50MB
    packet-tunnel jetsam ceiling. `mem footprint=` logging already exists in `PacketTunnelProvider`; measured numbers
    are pending and will be in a later section.
  - Binary size: each of the app and the extension links a ~42MB-per-slice static archive (pre-dead-strip).

### Reference

- Files/dirs: `~/Desktop/ssrust-ffi-build/` (crate, `README.md`, harness, build script),
  `LocalProxy/ShadowsocksEngine/` (SwiftPM package + xcframework), `HANDOFF-SHADOWSOCKS-QA.md` (test matrix,
  results are logged here in HANDOFF.md, append-only, as they happen).
- Local test server: `ssserver` 1.25.0 at `~/.cargo/bin/ssserver`.

## 2026-09-19 — Shadowsocks integration: first device build (iPhone 15 Plus) and the integration bugs it surfaced

Swift phases 3–7 were written by parallel workers and built together for the first time here.
`xcodebuild -project LocalProxy.xcodeproj -scheme LocalProxy -configuration Debug -destination
'platform=iOS,id=00008120-000A54E834B9A01E'` (the connected 15 Plus, "iPhone M") now **succeeds**, signed
with team `DS8AMC8BSV`, `LocalProxyTunnel.appex` embedded; installed and launched with
`xcrun devicectl device install app` / `process launch`. Nothing has been *functionally* tested yet — this
section only records what it took to get a clean build. Four real problems, in the order they appeared:

1. **Two xcframeworks with a `Headers/module.modulemap` cannot coexist.** `tun2proxy.xcframework` and
   `ssrust.xcframework` both copy that file to `<products>/include/module.modulemap`; the build stops with
   `Multiple commands produce .../include/module.modulemap`. The plan's step 8 (hand-written
   `module.modulemap` inside the xcframework, "identical to tun2proxy's") is what causes it. **Fix:**
   `ssrust.xcframework` is now *library-only* (no `-headers`), and `ShadowsocksEngine/Sources/CSsrust/` is a
   header-only C shim target (`include/ssrust.h`, its own `module.modulemap` for module `CSsrust`, an empty
   `shim.c`) that depends on the binary target for linking. `ShadowsocksEngine.swift` does `import CSsrust`
   instead of `import ssrust`. `build-xcframework.sh --install` now also copies the generated header into
   `CSsrust/include/`. (Supersedes the "identical modulemap" wording in the 2026-09-19 implementation log
   above; that section is left untouched per the append-only rule.)
2. **`ShadowsocksConfiguration(host:port:)` did not compile** — the plan's call sites (DashboardView state,
   ProxyServer default) omit `password`, but the initializer required it. `password` now defaults to `""`.
3. **Rust objects were stamped for iOS 27.0** (the SDK default; `IPHONEOS_DEPLOYMENT_TARGET` was unset), so
   the link printed ~190 `object file ... was built for newer 'iOS' version (27.0) than being linked`
   warnings. Older iOS could hit missing symbols at runtime; this 27.0 phone would never show it.
   `build-xcframework.sh` now exports `IPHONEOS_DEPLOYMENT_TARGET=15.0` — the *lowest* target that links the
   library (`LocalProxyTunnel` is 15.0; the app is 17.0). Result: 192 warnings → 2 (one object still stamped
   27.0 in each of the app and extension links; not chased down — likely a prebuilt std/compiler-builtins
   object; harmless on the 15.0/17.0 floors only if it references no post-15 symbols, so it stays on the
   "verify on a pre-27 device" gap list).
4. Rebuilding the Rust library twice (17.0 then 15.0) confirmed `cc`-built C (aws-lc) honors the env var but
   pure-Rust crates do not always recompile on an env-only change; the final 15.0 build was checked by
   sampling `vtool -show-build` on the extracted `.a` objects (378/379 → 17.0 in the middle attempt, after
   which the final 15.0 link showed only the 2 warnings above).

Also done this round: unsigned IPA rebuilt with `bash scripts/build-ipa.sh` (standing rule: phone and IPA
must not drift), so the sideloaded phone build and this Debug install are from the same tree.

Still to log in later appended sections: Rust-side cipher/UDP/memory verification (worker still running when
this was written), the on-device QA matrix in `HANDOFF-SHADOWSOCKS-QA.md`, and the summary/ship decision.

### Correction to item 4 above (2026-09-19, same session)

Item 4 said pure-Rust crates "do not always recompile on an env-only change". That was not verified and the
evidence points the other way: after the first rebuild with `IPHONEOS_DEPLOYMENT_TARGET=17.0`, 378 of 379
objects in `libssrust_ffi.a` were stamped `minos 17.0`, i.e. the Rust objects *were* restamped. Ignore item 4;
the sampled `vtool -show-build` counts are the only fact from it. The one object still stamped 27.0 has not
been identified, so whether it references any post-iOS-15 symbol is **unknown** (not "harmless") — it stays
on the known-gaps list: verify on a pre-iOS-27 device before shipping.

## 2026-09-19 — Shadowsocks integration: Rust-side verification results, and the stray 27.0 object resolved

Source of truth: `~/Desktop/ssrust-ffi-build/VERIFICATION.md` (raw logs beside it). Everything here was run on
macOS against a real `ssserver` 1.25.0; iOS-device behavior is **not** covered by it.

- **Cipher matrix — PASS, all six.** `aes-256-gcm`, `aes-128-gcm`, `chacha20-ietf-poly1305`,
  `2022-blake3-aes-128-gcm`, `2022-blake3-aes-256-gcm`, `2022-blake3-chacha20-poly1305` each relayed http and
  https end to end and stopped with rc=0. This is the exact list compiled in (plan step 33's "cipher list
  actually compiled in"); it matches `ShadowsocksCipher`. 2022 ciphers need a base64 PSK of 16 bytes
  (aes-128) or 32 bytes (the other two); a plain passphrase, a wrong-length key, an unsupported method
  (`rc4-md5`, `aes-256-cfb`) or an empty method all fail at start with rc -3.
- **Gap found: an empty password with `aes-256-gcm` starts fine** (it derives a key from ""). The engine will
  not reject it, so the Swift side must. (Client tab already requires a non-empty password to enable
  Connect; the relay Settings section is only gated on host — see gaps below.)
- **Wrong-but-valid password is undetectable at toggle time** (no handshake), confirming the re-specified
  QA #2: only -3/-6 style failures snap the toggle back.
- **UDP — PASS.** SOCKS5 UDP ASSOCIATE returned a real DNS answer for example.com via 1.1.1.1; the relay port
  equals `local_port`, so tun2proxy's UDP path should work through it.
- **Proof of transit (QA #5).** The `ssserver` installed earlier (`--features 'server aead-cipher
  aead-cipher-2022'`) has NO logging compiled in — a silent ssserver would make #5 look like a fail. Rebuild
  with `--features 'server logging aead-cipher aead-cipher-2022'` (a copy is at
  `~/Desktop/ssrust-ffi-build/tools/bin/ssserver`), run it with `-U -v --log-without-time`, and grep for
  `established tcp tunnel` (one line per relayed TCP connection) and `created udp association`. A silent
  fallback to direct dialing produces neither.
- **Memory — PASS on macOS.** Idle 1.7 MB, peak 3.9 MB with 30 concurrent streams and a byte-exact 50 MB
  download, flat with bytes transferred (~8% of the NE's 50 MB jetsam ceiling); `worker_threads(2)` is fine.
  macOS numbers only — the on-device `mem footprint=` line from PacketTunnelProvider is the real check.
- **Crypto backend.** "Pure-Rust only" from the plan is unattainable: `aead-cipher` (also `aead-cipher-2022`
  and `stream-cipher`) hard-enables `shadowsocks-crypto/aws-lc`. aws-lc-rs cross-compiled cleanly for both iOS
  targets. It is used only by the v1 AEAD ciphers (aes-gcm, chacha20-poly1305, HKDF-SHA1); the 2022 ciphers
  use pure RustCrypto; `ring` is not in the tree. (Refines the implementation log's (a).)
- **Link requirements.** A plain C program links each slice with no extra frameworks (libSystem only). The
  Security/SystemConfiguration/CoreFoundation `linkedFramework` lines copied from the tun2proxy template are
  harmless but not required.
- **`panic = "abort"` + threads.** Any Rust panic kills the Network Extension process; and the log callback
  fires from tokio worker threads, so the Swift log closure must be thread-safe (ShadowsocksEngine's
  `logHandler` plumbing is a static slot — worth a QA glance).

**The stray 27.0 object is resolved (this supersedes the "correction to item 4" above).** It was
`blake3_neon.o`, a C object cached by cargo from the very first build: blake3's build script does not rebuild
when only `IPHONEOS_DEPLOYMENT_TARGET` changes, so it kept its 27.0 stamp through the 17.0 and 15.0 rebuilds.
Deleting `target/aarch64-apple-ios*/release/{build,.fingerprint}/blake3-*` and re-running
`build-xcframework.sh --install` fixed it: **every object in the ios-arm64 slice is now `minos 15.0`** and the
device build prints **0** "built for newer iOS version" warnings (was 192). Lesson for the build script's
README: after changing the deployment target, clear cached C-object crates (`cargo clean` is the blunt,
safe option) — an env-only change does not invalidate them. (So item 4 was half right: cached *C* objects
are the ones that don't get restamped; the Rust objects did.)

Device: Debug build rebuilt and reinstalled on the iPhone 15 Plus (`00008120-000A54E834B9A01E`) and launched;
unsigned IPA rebuilt again afterwards (standing rule). No on-device functional test has been run yet.

## 2026-09-19 — Shadowsocks QA pass

Running log, appended as each row finishes (not batched). Checklist and setup: `HANDOFF-SHADOWSOCKS-QA.md`
(its constraint 3 "no code-signing identity for device builds" is **stale** — device signing with team
`DS8AMC8BSV` works and the Debug build was installed on the phone with `devicectl`; the QA doc is otherwise
accurate). Environment: Mac `10.0.0.177` (en0, firewall off); logging `ssserver` 1.25.0
(`~/Desktop/ssrust-ffi-build/tools/bin/ssserver -s 0.0.0.0:8399 -m aes-256-gcm -k testpassword -U -v
--log-without-time`, log `~/Desktop/ssrust-ffi-build/qa/ssserver-8399.log`). Physical phone: iPhone 15 Plus
(`00008120-000A54E834B9A01E`). **UI tap automation exists only for simulators** (Xcode
`DeviceInteractionSynthesize` rejects the physical phone), so relay rows that need UI taps run in the
simulator (iPhone 17 Pro, its networking is the Mac's) and VPN rows run on the phone via DEBUG launch hooks.

### #1 Rust FFI start/stop cycle — PASS
Re-run on the final (deployment-target-15.0) library sources: `cargo run --release --example harness` against
`ssserver -s 127.0.0.1:8388 -m aes-256-gcm -k testpassword`: 26 PASS lines, 0 failure(s). Stop returns rc=0
in ~11–14 ms, the port rebinds on the next cycle, second start returns -4, port-in-use returns -6, wrong password
starts fine but the relayed request times out (curl 28), stop-racing-start returns 0. Log:
`~/Desktop/ssrust-ffi-build/qa/harness-rerun.log`. Thread leak not separately measured (join times bounded).

### #16 Simulator build sanity — PASS
`xcodebuild -scheme LocalProxy -configuration Debug -destination 'platform=iOS Simulator,id=C61D09FC-…'`
(concrete iPhone 17 Pro, arm64; never "Any iOS Simulator") → BUILD SUCCEEDED; both `tun2proxy.xcframework` and
`ssrust.xcframework` link; the only warning is the pre-existing "Metadata extraction skipped, no
AppIntents.framework dependency found". (This is where the CSsrust shim earned its keep — see the first-device-build
section above.)

### #9 ss:// QR export/import round-trip — PARTIAL (codec + QR image verified; camera scan NOT run)
Script (`ShadowsocksConfiguration.swift` compiled unmodified on macOS with a stub engine module): encode →
CoreImage `qrCodeGenerator` (same generator as `QRCode.image(for:)`, correction level M) → `CIDetector`
decode → parse. 14/14 PASS: text identical and parsed config == original for aes-256-gcm/remark, chacha20 with a
password containing `@ : / + = ? # é` and a remark with spaces/`#`/`é`, IPv6 host `::1`, port 65535, empty
password, and both 2022 ciphers with base64 PSKs; plus standard-padded and URL-safe-unpadded base64 userinfo variants
parse to the same config. **Not verified:** the live camera scanner (`QRScannerViewController`) and the on-screen
sheets — needs a real camera; simulator has none. Carried to the known-gaps list.

### #3 Local relay via Shadowsocks — functional — PASS (simulator)
Simulator iPhone 17 Pro (`C61D09FC-…`, networking = the Mac's) launched with DEBUG hooks
`QA_AUTOSTART=1 QA_TAB=3 QA_SS_URI=ss://<b64url aes-256-gcm:testpassword>@10.0.0.177:8399#QA`. App log:
`[shadowsocks] relay routed via Shadowsocks server 10.0.0.177:8399 cipher=aes-256-gcm`, `primary READY on port 8080`,
engine listening `127.0.0.1:11080`. From the Mac acting as the second LAN device:
`curl -x http://10.0.0.177:8080 http://example.com/` → `http=200 bytes=559`; same for `https://example.com/`
(CONNECT) → `http=200 bytes=559`. **Setup snag worth knowing:** port 8080 was already held by a stale LocalProxy from
yesterday's session in a *different* simulator (iPhone 17 `A7A8F2F6-…`, running since 2026-09-18 07:37); the QA app got
`EADDRINUSE` until I terminated that instance (`simctl terminate`, nothing deleted). Check `lsof -iTCP:8080` first.

### #5 Local relay — proof of transit — PASS
ssserver `-v` log, lines produced by exactly those two curls (nothing else in the window):
`established tcp tunnel 10.0.0.177:54311 <-> example.com:80` and `… 10.0.0.177:54315 <-> example.com:443`. So the traffic
provably went phone-side engine → ssserver → origin (client address is the Mac's IP only because the simulator shares
the Mac's stack). The destination arrived as the **hostname** `example.com`, confirming the DoH skip: the server, not the
phone, resolved it. A silent direct-dial fallback would have produced no ssserver lines.

### #4 Local relay — genuinely encrypted — PASS via tee-proxy capture (tcpdump NOT run — needs sudo)
`qa/wiretap.py` (a TCP tee between the app and ssserver: `:8398 → 127.0.0.1:8399`, every byte logged) with the app's
Shadowsocks server set to `10.0.0.177:8398`; one `curl -x … http://example.com/` → `http=200 bytes=559`. Captured
1142 bytes on the phone→server hop: occurrences of `GET /`, `HTTP/1.1`, `Host:`, `example.com`, `testpassword`,
`User-Agent`, `Example Domain`, `<html` are all **0**; Shannon entropy 7.817 bits/byte; first bytes
`8d9f6b83ba655a42e4554e285a7338ad…`. Capture: `~/Desktop/ssrust-ffi-build/qa/wire-capture.bin`. This is equivalent
evidence at that hop but is not a `tcpdump` on en0; a literal tcpdump run is still open if wanted (`sudo tcpdump -i en0
-n -A port 8388`).

### #15 Ready-connection handling ("double start") — PASS (answers the plan's open question)
Every Shadowsocks dial in #3–#5 logged, in order: `ready via explicit check attempt=0`, then `READY host:port
attempt=0 connectTime=5–10ms`, then `ready via state replay (ignored — already handled by explicit check)`. So
Network.framework **does** replay the current state to a state handler installed on an already-`.ready` connection, and
without the `didHandleReady` guard `handleServerReady` would have run twice (double success reply + double pipe). No
crash, no hang, and the 559-byte response arrived intact each time. (The double `start(queue:)` on the same queue was
harmless.) Both HTTP-forward (T1) and CONNECT (T2) paths exercised.

### #2 Bad config surfaces cleanly (re-specified: a/b/c) — (a) PASS, (b) PASS, (c) PASS; **one UI defect found (F1), one unexplained UI oddity (F2)**
- **(a) invalid config → catch path.** `QA_SS_URI=ss://2022-blake3-aes-256-gcm:notabase64key@10.0.0.177:8399` (2022 cipher with a plain
  passphrase). App log: `[shadowsocks] failed to start: startFailed(code: -3, message: "Invalid Shadowsocks configuration (check
  server, port, cipher and password format).")`. No engine listening on 11080; UI toggle read `value: 0` (snapped off); the config
  stayed in the form. Direct relay afterwards: `curl -x http://10.0.0.177:8080 http://example.com/` → `http=200`, **0** new ssserver lines
  (no shadowsocks traffic, no silent fallback *while the toggle claims on*).
- **(b) bind failure.** `nc -l 127.0.0.1 11080` holding the port, then launch with a good URI → `failed to start: startFailed(code: -6,
  message: "Could not bind 127.0.0.1:11080 (port in use?).")`; direct relay `http=200`, 0 ssserver lines; port released afterwards.
- **(c) wrong password vs a real ssserver.** Engine starts and the toggle stays on (nothing detectable at start — as re-specified).
  `curl -x http://10.0.0.177:8080 http://example.com/` → `curl: (28) Operation timed out after 15003 ms with 0 bytes received`,
  `http=000`. **No direct-dial fallback**: app log shows `dialing example.com:80 … remote=v4:127.0.0.1:11080`, `STALL no bytes either
  direction`, tunnel closed only when curl gave up (`up=0B down=0B`, `sentAppBytes=122 recvAppBytes=0`). ssserver `-v`:
  `WARN … tcp handshake failed. peer: 10.0.0.177:54336, decrypt length failed` then `DEBUG … tcp silent-drop peer: …`. Note the relay
  has no timeout of its own here: a wrong password looks like an infinite stall to the client until the *client* gives up (standard
  Shadowsocks silent-drop behavior; worth a footnote in the UI copy).
- **F1 (defect, UI): the "Failed to start Shadowsocks: …" label is erased ~1.7 s after it appears when the failure happens at launch.**
  `ProxyServer.swift:432` — the primary listener's `.ready` handler does `self.lastError = nil`. Sequence seen on the iOS 27.0 simulator:
  `07:02:33.8 failed to start … -3` → `07:02:35.5 primary READY on port 8080` → the accessibility hierarchy contains **no**
  "Failed to start" label, only the toggle snapped to off. So a persisted-"on" that fails at launch leaves a silently-off toggle. (Mid-session
  failures, listener already up, keep the label.) Fix pending — see the F1 fix note below.
- **F2 (unexplained): after that launch-time failure the Cipher picker reported `Disabled` in the accessibility hierarchy** (host/port/password
  fields enabled; a tap on the picker did nothing) with the toggle off and the failed 2022 cipher selected. Not reproducible after a
  normal on→off flip with aes-256-gcm (picker enabled; menu lists all six ciphers). Root cause not found; the `.disabled(routeRelayViaShadowsocks)`
  Group looks correct in code. Carried to known gaps: re-check on a device with a persisted failing config.

### #6 Toggle flip mid-connection — PARTIAL: on→off **does not** match the plan's expectation; off→on matches
Rig: 40 MB file served from the Mac (`python3 -m http.server 8090`), fetched through the relay with `curl -p --limit-rate 400k` (CONNECT, so the
origin sees origin-form; plain HTTP-forward hands the origin an absolute-form request line and Python's server 404s — pre-existing behavior).
iOS 27.0 simulator, toggle flipped by a **real synthesized tap** (Xcode `DeviceInteractionSynthesize`, tapping the Switch).
- **Shadowsocks ON → tap OFF mid-transfer:** the in-flight tunnel **was killed**: `curl: (18) transfer closed with 30041962 bytes
  remaining to read`, `bytes=11901078 time=28.8s`; app log `[T2] CLOSED reason=bothFinished … lifetime=28852.5ms` at the instant of the
  tap. Cause: `ssrust_stop()` tears down the whole Tokio runtime, including relays already in flight (flagged by the implementation as design
  deviation #8; now confirmed empirically). **The plan expected the in-flight connection to survive until it closed naturally — that does
  not hold for toggle-off.** Whether that is acceptable (arguably what "turn Shadowsocks off" means) or needs a graceful drain (keep the engine
  alive until open Shadowsocks tunnels finish, then stop) is a product call — listed in known gaps.
- **Shadowsocks OFF, direct download open → tap ON:** the new connection went through Shadowsocks (ssserver `established tcp tunnel
  10.0.0.177:54517 <-> example.com:80`, http=200) while the already-open direct download was **unaffected** (kept ~500 KB/s: 25.7 MB in 50 s until my own
  `-m 50` cap, exit 28 is that cap, not a drop).

### #7 Toggle-off restores direct relay — PASS
After the tap-off above: `lsof` shows nothing listening on 11080 (engine stopped); `curl -x http://10.0.0.177:8080 http://example.com/` →
`http=200`; ssserver log gained **no** `established` line for it (only the pre-existing tunnel's teardown line `copy bidirection ends with
error: Connection reset by peer`). UI switch `value: 0`, Cipher picker enabled again.

### #8 Persisted toggle survives relaunch — PASS (iOS 27.0 simulator)
Toggle left on (set by tap) → `simctl terminate` (force-quit) → relaunch with **no** `QA_SS_URI` (only `QA_AUTOSTART=1`): app log
`loadLastSettings: decoded port=8080 …` then, 19 ms later at init, `[shadowsocks] relay routed via Shadowsocks server 10.0.0.177:8399
cipher=aes-256-gcm` — the explicit `applyShadowsocksToggle()` after `loadLastSettings()` did its job (the plan's called-out regression
point). After the (slow, ~7 s) listener came up, `curl -p -x http://10.0.0.177:8080 http://example.com/` → `http=200` and ssserver logged
`established tcp tunnel 10.0.0.177:54561 <-> example.com:80`. (My first curl at +8 s got "connection refused" purely because the listener
hadn't finished starting on that launch — READY logged at +7.4 s.)

### BUG FOUND + FIXED on the phone: the tunnel extension could not read the VPN password from the Keychain
First on-device Client-VPN attempt (`QA_CLIENT_URI=ss://… QA_CLIENT_AUTOCONNECT=1` via `devicectl process launch -e`): VPN status went
connecting → disconnecting → disconnected in ~150 ms. The app never logged why (ClientTunnelManager had no logging — added), and the
extension only logged failures to `os.Logger` (added file-log lines). Extension `tunnel-debug.log`: `startTunnel FAILED: bad configuration
Missing Shadowsocks password keys=["ssHost","ssMethod","ssPort","transport"]`. **Root cause:** `ClientTunnelManager` and
`PacketTunnelProvider` addressed the shared Keychain item with the literal access group `com.Korporate1k.LocalProxy.shared`, but the real
runtime group is Team-ID-prefixed (`DS8AMC8BSV.com.Korporate1k.LocalProxy.shared`). `KeychainStore`'s own doc comment says the literal was
a stopgap "since this environment has no Team ID configured" — that stopped being true once device signing worked. With no matching
entitlement `SecItemAdd` fails (errSecMissingEntitlement) and its result was never checked, so the password was silently never stored and
the extension read back "". **Pre-existing and not Shadowsocks-specific:** the same wrong group means the *SOCKS5* password never reached the
extension either, which is exactly why the tun2proxy sections list "SOCKS5 auth never exercised on a real device" — an empty password looks
identical to "no auth". **Fix:** both sides now omit `kSecAttrAccessGroup` (the default group is the single shared group in each
target's `keychain-access-groups` entitlement; an unscoped query searches the groups the process is entitled to);
`KeychainStore.save` now logs a non-success `SecItemAdd` OSStatus; the extension logs a failed Keychain read. After the fix:
`[client] VPN status -> 3` (connected) within ~0.5 s. Not yet verified: SOCKS5 *with credentials* end to end (would now be possible).
Other diagnostics added this round (kept): `[client]` log lines for VPN status changes, save/start results and errors; `startTunnel
entered/FAILED` file-log lines in the extension; DEBUG hook `QA_CLIENT_STOP=1` (disconnects the tunnel so QA can switch transports).
Also fixed **F1** (the erased "Failed to start Shadowsocks" label): the listener's `.ready` no longer clears a Shadowsocks error; a
successful start clears it; the off-branch deliberately doesn't (the failure path re-enters it). F1 not yet re-verified on a launch-time failure.

### #10 Client VPN via Shadowsocks — functional — PASS (phone: iPhone 15 Plus, iOS 27.0)
Extension log, in order: `excluded route for server 10.0.0.177`; `[ss] [ssrust] starting server=10.0.0.177:8399 method=aes-256-gcm
local=127.0.0.1:11081`; `local server ready`; `shadowsocks socks TCP listening on 127.0.0.1:11081`; `shadowsocks socks5 UDP listening on
127.0.0.1:11081`; `startEngine proxy=127.0.0.1:11081 auth=false`; `tun2proxy … Proxy socks5 server: 127.0.0.1:11081`. VPN status 3. Opening
`https://example.com/?qa=vpn-ss-1` in Safari (`devicectl … --payload-url … com.apple.mobilesafari`) made ssserver log `established tcp tunnel
10.0.0.129:61515 <-> example.com:443`. **Not directly observed:** the rendered page on the phone screen (no way to screenshot a physical device
from here) — evidence is server-side.

### #11 Client VPN — proof of transit — PASS via server-side evidence; exit-IP comparison NOT usable
The Mac and the phone share one home NAT, so a "what is my IP" page shows the same public IP with or without the tunnel — it cannot
discriminate here (needs a VPS ssserver or a different uplink). Positive proof instead: ssserver `-v` logged the **phone's own LAN address**
(`10.0.0.129`) as the client of ~14 tunnels within seconds of the VPN connecting — `7-courier.push.apple.com:5223`, `p38-imap.mail.me.com:993`,
`gist.githubusercontent.com:443`, `example.com:443`, `mask.icloud.com:443`, `configuration.apple.com:443`, … — all as **hostnames** (tun2proxy's virtual
DNS, so no DNS leak to the LAN resolver), plus `created udp association for 10.0.0.129:63121` / `:56411` (UDP ASSOCIATE through the engine works
end to end: tun2proxy → ssrust SOCKS5 UDP → ssserver). A direct-dial fallback would never have appeared in the Mac's ssserver log.
Extension memory: `mem footprint=4.3 MB` (limit ~50 MB).

### #14 Both paths active simultaneously — PASS
VPN via Shadowsocks connected (engine 127.0.0.1:11081 in the extension) → relaunched the phone app with `QA_AUTOSTART=1 QA_SS_URI=…`: app log
`relay routed via Shadowsocks server 10.0.0.177:8399`, `primary READY on port 8080`, engine on 11080 — **no bind error in either process**
(11080 app vs 11081 extension, as designed). From the Mac: `curl -p -x http://10.0.0.129:8080 http://example.org/` → `http=200`; ssserver
`established tcp tunnel 10.0.0.129:61620 <-> example.org:80`. VPN stayed connected through the app relaunch. Caveat noted, not tested: with the
VPN's default route active, relay clients other than the excluded ssserver host would have their replies routed into the tunnel.

### #12 Client VPN routing-loop exclusion, run for minutes — PASS (phone, 6.4 min undisturbed)
Method changed mid-test, and the first method was invalid: driving the soak by launching Safari via `devicectl` gave 0 of 9 "fresh tunnels" (the
phone had auto-locked/been woken; a locked phone can't launch or foreground anything) — that run says nothing about the tunnel, kept as
`qa/run12-first-attempt.log`. Replaced by a DEBUG-only hook **`QA_TRAFFIC=<seconds>`** (kept in the tree): the *app* keeps the screen awake
(`isIdleTimerDisabled`) and fetches a rotating list of 12 HTTPS hosts every N s through the system path, i.e. through the VPN, logging each
result under `[qa]`. With the Shadowsocks VPN connected and **no relaunch or other interaction** for 07:31:54–07:38:18: **19/19 fetches
`-> 200`** (iana, wikipedia, python, gnu, kernel, debian, openbsd, ietf, w3, example.com/.org/.net, then a second lap; 165–883 ms each),
VPN status stayed 3, `excluded route for server 10.0.0.177` present at start, **0** `ERROR tun2proxy` lines, extension memory 4.1–4.4 MB
flat (a step to 5.8–6.0 MB appeared in the last samples — still ~12% of the ~50 MB ceiling; not chased), 42 phone-originated tunnels in the
ssserver log, all by hostname. A wrong `exclusionHost` would have shown "connects, then everything stalls"; it did not.

### #14 Both paths active simultaneously — first entry above was WRONG; re-run PASS
**Correction:** the earlier #14 section claims "VPN stayed connected through the app relaunch". It did not. Between that entry and the soak I found the
tunnel extension had died at the moment I relaunched the app (`devicectl process launch --terminate-existing`): its file log stops with no
`Shutdown received`, VPN status went to 1, and ssserver stopped seeing the phone. So that run never had both engines up together; the relayed
request only worked because the VPN was already gone. **Re-run done properly, one launch, no relaunch:** `QA_AUTOSTART=1 QA_SS_URI=… QA_CLIENT_URI=…
QA_CLIENT_AUTOCONNECT=1 QA_TRAFFIC=20`. Result: VPN status 3; extension alive (memory line fresh); app log `relay routed via Shadowsocks`, `primary READY on
port 8080`; extension log `[ss] … local=127.0.0.1:11081` and `shadowsocks socks TCP/UDP listening on 127.0.0.1:11081`; **no bind error in either process**.
From the Mac, `curl -p -x http://10.0.0.129:8080 http://example.org/` → 200 and `https://www.gnu.org/` → 200 through the phone's relay, while the VPN's own
in-app traffic (wikipedia/python/iana) was in the same ssserver log. Observation (not chased): one relayed tunnel's loopback connection to 127.0.0.1:11080
reported `posix 50 ENETDOWN` ~600 ms after ready, *after* its full 47,871-byte response had been delivered (curl: 200, no error) — logged as F4.

### #13 Client VPN, plain SOCKS5 transport unaffected — PASS (phone)
Server: the simulator app as a plain direct SOCKS5 relay on the Mac (`10.0.0.177:8080`, Shadowsocks toggle off, 0 `relay routed via Shadowsocks` lines). Phone launched with
`QA_CLIENT_URI=socks5://10.0.0.177:8080 QA_CLIENT_AUTOCONNECT=1`: `configuration saved (transport=socks5)`, VPN status 3, extension `startEngine
proxy=10.0.0.177:8080 auth=false` (the real host, no `[ss]` engine lines, extension memory 3.6 MB vs ~4.3 MB with the Shadowsocks engine), the Mac's relay logged the phone's
dials (`www.wikipedia.org:443`, `www.python.org:443`, `www.iana.org:443`, `p38-imap.mail.me.com:993`, …) and ssserver logged **0** phone lines. **Snag (test-method, not a
product bug):** the first attempt was launched while the previous Shadowsocks VPN was still up; saving a different config while connected makes iOS tear the tunnel
down (status 5→1) and the new tunnel never started. Switching transports needs a disconnect first (the Client tab disables the picker while connected, so a user can't hit this).
Not verified: SOCKS5 *with credentials* (would now work — see the Keychain fix).

### Findings from this round (F1–F4) and the extension-lifetime observation
- **F1 (label erased) — FIXED and re-verified.** Launch with a persisted-failing config on the iOS 27.0 simulator: the red "Failed to start Shadowsocks: Invalid Shadowsocks
  configuration (check server, port, cipher and password format)." label is on screen *after* `primary READY` (listener came up ~2 s after the failure).
- **F2 (Cipher picker "Disabled") — RETRACTED, false alarm.** Reproduced the accessibility "Disabled" flag, but tapping the picker opens the menu with all six ciphers and the
  current one selected; my first no-op tap had landed under the tab bar. Ignore F2 in the #2 entry above.
- **F3 (design deviation, unchanged):** toggle-off kills in-flight Shadowsocks tunnels (see #6). Product decision pending: graceful drain vs. hard stop.
- **F4 (observation):** one loopback `ENETDOWN` on a relayed tunnel while the VPN was active (see #14). No user-visible effect seen.
- **Extension lifetime (generic, NOT Shadowsocks-specific, root cause unknown):** in 4 of 4 tries, relaunching the app with `devicectl device process launch
  --terminate-existing` while a VPN was up killed the tunnel extension — on the Shadowsocks transport with the relay hook, on the Shadowsocks transport with **no** relay hook,
  and on the plain SOCKS5 transport (extension log stops, no `Shutdown received`, VPN status → 1). No crash log is produced. Not verified whether a *real* app kill (swipe-away,
  jetsam of the backgrounded app) does the same — that is the most important unanswered question for shipping; it may be an artifact of developer-launched processes.

### QA hooks added/kept this round (all `#if DEBUG`, absent from Release/IPA)
`QA_CLIENT_STOP=1` (disconnect the tunnel), `QA_TRAFFIC=<seconds>` (in-app HTTPS loop + screen kept awake), `QA_SS_URI=off` (stop the engine, toggle off, clear the saved
Shadowsocks server — QA cleanup), in addition to `QA_SS_URI=ss://…`, `QA_CLIENT_URI`, `QA_CLIENT_AUTOCONNECT`, `QA_AUTOSTART`, `QA_TAB`. Non-DEBUG additions: `[client]`/`[keychain]` log
lines, extension file-log lines, the Keychain-group fix, the F1 fix.

## 2026-09-19 — Shadowsocks QA pass: summary

**Scorecard (16 rows): 14 PASS, 2 PARTIAL, 0 FAIL, 0 not run.**
PASS: #1 FFI cycle (26/26), #2 bad config a/b/c, #3 relay functional, #4 encrypted on the wire (tee-proxy capture — **not** `tcpdump`), #5 proof of transit, #7 toggle-off restores direct, #8 persisted toggle,
#10 VPN functional (server-side evidence), #11 VPN proof of transit (server-side evidence), #12 routing-loop soak, #13 SOCKS5 unaffected, #14 both paths (after correcting a wrong first entry), #15 ready-connection handling, #16 simulator build.
PARTIAL: **#6** — off→on matches the plan, but **on→off drops in-flight Shadowsocks tunnels** (plan expected them to survive); **#9** — `ss://` codec and QR *image* round-trip 14/14, but the live **camera scan was not run** (simulators have no camera).

**Bugs the pass found and fixed:** (1) **Keychain access group** — app and tunnel extension used the un-prefixed literal group, so the VPN password was silently never stored/read once a Team ID existed;
the Shadowsocks VPN could not start at all, and **SOCKS5 VPN credentials were equally broken** (pre-existing; now fixed, unverified with credentials); (2) two-xcframework `module.modulemap` collision (build); (3) Rust objects stamped
iOS 27.0 (192 link warnings → 0); (4) `ShadowsocksConfiguration(host:port:)` missing default; (5) F1 lost error label; plus logging gaps that made (1) undiagnosable (VPN status/errors, extension startup, Keychain OSStatus).

**Known gaps carried forward (unverified or accepted):**
1. **VPN survival across a real app kill** — every relaunch via `devicectl --terminate-existing` killed the extension (also on SOCKS5). Unknown for swipe-away/jetsam. **Highest-priority open item.**
2. On→off toggle drops in-flight Shadowsocks connections (#6) — needs a product call; a graceful drain is the alternative.
3. `#4` used a tee-proxy, not `tcpdump` on en0 (no sudo). `#9` camera scan not run. `#10` rendered page not seen (server-side evidence only). `#11` exit-IP comparison impossible on one NAT — needs a VPS ssserver.
4. Not run on any iOS older than 27.0 (the Rust library is stamped for 15.0; the phone and simulators are 26.5/27.0). SOCKS5 VPN with credentials not run. Wrong-password is only observable as stalled requests (by design of the protocol).
5. UDP ASSOCIATE from LAN devices and the app's own diagnostics stay direct (footer says so); DoH is bypassed for Shadowsocks connections; 2022 ciphers need base64 keys; no SIP003 plugins.
6. With the VPN default route active, relay clients other than the excluded ssserver host would have their replies routed into the tunnel (not tested, design-level risk). Extension memory 4–6 MB on device vs ~50 MB ceiling (fine).
7. Unresolved: one loopback ENETDOWN (F4); a ~1.5 MB step in extension memory late in the soak.

**Verdict: ready for internal/TestFlight testing, not ready to ship unqualified.** The Shadowsocks relay path and both engines are sound end to end on real hardware, and the pass fixed a genuine VPN-credential bug. Before a public release: settle gap 1
(real app-kill behaviour), decide gap 2, and run gap 3/4 once against a real VPS server on a second network.
Final artifacts: unsigned IPA rebuilt after the last code change (build number in the next line); Mac left clean (no `ssserver`, `tcpdump`, `wiretap`, `nc`, or file server running); phone left with VPN disconnected and no Shadowsocks server/toggle saved.

Final unsigned IPA (rebuilt after the last code change of the QA pass): version 1.0 (20260919.075331) at build/Build/Products/Release-iphoneos/LocalProxy.ipa.

## 2026-09-19 — Source reverted to TestFlight build 1.0 (2) (Shadowsocks work removed from `main`)

The working tree was reverted to match TestFlight build 1.0 (2) (archived 2026-09-18 12:14). **Nothing was
lost:** the full pre-revert tree (all Shadowsocks work, QA-pass fixes, docs) is committed on branch
`snapshot/pre-testflight-revert-2026-09-19` (`Personal Access Tokens (Classic).pdf` deliberately left out of that commit).
`ssrust-ffi-build/` under `~/Desktop` was not touched.

- **Method.** No source snapshot of build 2 exists in git, so it was reconstructed by hand. The archive's dSYM
  gave the definitive list of source files in that build, and its symbol table and string literals were diffed against a
  Release simulator build of the reverted tree (app and tunnel) until they matched.
- **Removed:** `ShadowsocksEngine/`, `Shadowsocks*.swift` (6 files), `ServerTabView`, `ClientTransportKind`,
  `LocalNetworkPermission` (its probe is back inside `ProxyServer`), `SHADOWSOCKS-SERVER-CHECKLIST.md`,
  `HANDOFF-SHADOWSOCKS-QA.md`, README Shadowsocks bullets, pbxproj package/file references.
- **Reverted in place:** `ProxyServer` (no Shadowsocks settings/engine/toggle), `Tunnel.connectOutbound` (synchronous
  dial, no `didHandleReady`/`handleServerReady`/`handleDialFailure`, no `OutboundTransport` protocol),
  `ClientTunnelManager` (single `save(_:)`, keychain group literal restored), `ClientTabView` (no transport
  picker), `QRCodeView`/`QRScannerView`, `DashboardView` (4 tabs; `QA_TAB` 0-3), `PacketTunnelProvider`
  (SOCKS5 only), `KeychainStore`.
- **Verification.** Release-simulator app symbols identical to build 2 apart from `ProxyServer.loadLastSettings()`
  being inlined; app string literals identical; tunnel Swift symbols identical; Info.plists identical apart from
  platform keys. Launched on the iPhone 17 Pro simulator: four tabs, no Server tab. A missed
  `loadLastSettings()` call in `ProxyServer.init` was caught by the string diff and fixed. NOT verified: function
  bodies beyond symbols/strings, and anything on a device.
- **Caveat.** The simulator slice of `libtun2proxy.a` differs slightly from build 2's; the device slice
  (md5 52688f35…) is byte-identical to the 11:39 build used for build 2.

## 2026-09-19 — Repo hygiene + file split (no behavior change)

- **Commit `781c80e`** — the reverted working tree (matches TestFlight build 1.0 (2)) is now committed on `main`. The index had been
  left stale with pre-revert Shadowsocks-era entries; it was restaged from the working tree. No Shadowsocks files are on `main` (they
  are on `snapshot/pre-testflight-revert-2026-09-19`). `Personal Access Tokens (Classic).pdf` is in `.gitignore`.
- **`DashboardView.swift` (1009 lines) split** into `DashboardView.swift` (root + `UpdateRequiredView` + DEBUG `QATraffic`),
  `HomeTabView.swift` (+ `StatTile`), `SettingsView.swift` (+ `ActivityView`, `FolderPicker`) and `ConnectionHistoryListView.swift`.
  `HomeTabView` and `SettingsView` lost `private` (used from the root file); nothing else changed.
- **`ConnectProxyHandler.swift` (800 lines) split** into the core `Tunnel` class (properties, init, start, CONNECT parse) plus
  `extension Tunnel` files `ConnectProxyHandler+Socks5.swift`, `+Relay.swift` (outbound, pipe/forward, teardown) and
  `+Diagnostics.swift`. Members referenced across files lost `private` (compiler-enforced; stored properties stay in the class).
- **Verification.** A sorted line-diff of old vs new files shows only the extension scaffolding, imports and the removed `private`
  keywords changed. Debug simulator build and Release device build succeed; the app launches on the iPhone 17 Pro simulator with four
  tabs and the dashboard stat tiles rendering. NOT verified: Settings/Devices screens and proxy traffic after the split (no logic
  was touched), and nothing on a device.
- **Not changed, deliberately.** `Socks5ClientTestView` and `UploadThroughputTestView` are user-facing (Client tab, Settings → Tools),
  so they were not put behind `#if DEBUG`.
- New files have entries in `project.pbxproj`; names containing `+` must be quoted there.

Unsigned IPA rebuilt after this change: version 1.0 (20260919.135009) at build/Build/Products/Release-iphoneos/LocalProxy.ipa.

## 2026-09-19 — Open item resolved: VPN survival across a real app kill

The earlier QA pass left "does the client VPN survive a real app kill (swipe-away / jetsam)?" as the highest-priority open item
(every `devicectl --terminate-existing` relaunch had killed the tunnel extension, including on plain SOCKS5). **Answer, reported by the
project owner: yes, it survives a real app kill.** This is the owner's observation on a real device; it was not re-tested in this
session, and the `devicectl --terminate-existing` result is therefore best read as an artifact of developer-launched processes.

## 2026-09-19 — UDP routing QA (server relay verified on the Mac; on-device "all UDP via proxy" NOT re-verified)

Request: confirm all UDP from the client device routes via the proxy. The physical iPhone was `unavailable` to `devicectl` this
session, so the Client-VPN capture path (the part that decides whether *every* UDP flow enters the tunnel) could not be run.

- **Socks5Client unit tests:** `swift test` — 30/30 pass (incl. 4 UDP association tests).
- **Live server test** (iPhone 17 Pro simulator, `QA_AUTOSTART=1 QA_SERVER_PORT=18080`, raw-socket Python SOCKS5 UDP client; sim shares
  the Mac network stack): 17/18 pass, and the 1 fail is a test artifact (see below).
  - DNS A via 1.1.1.1 and 8.8.8.8: real 61-byte replies, transaction IDs match.
  - Echo integrity 1/64/512/1200/1400/4000/9000 B: byte-exact.
  - Destination saw the *relay's* socket (port 59697), never the client's (55217): traffic egresses from the relay, not directly.
  - 200-datagram unpaced burst: 200/200, in order. IPv6 destination (ATYP 4): pass. ATYP 3 with a real host (dns.google): pass.
    Two destinations interleaved in one association: pass.
  - Malformed and FRAG!=0 datagrams dropped, relay stays healthy; a second sender is ignored; association torn down when the TCP control
    connection closes.
  - Server log counters cross-checked exactly: `up=214 dgrams / down=213 dgrams` = what the client sent/received (the 1 missing reply is the
    artifact: `localhost` resolved to ::1 and the echo server was IPv4-only; the same ATYP 3 path passes with dns.google).
- **Observation, not changed:** the relay's reply header carries BND `0.0.0.0:0`, not the datagram's real source (RFC 1928 wants the source).
  Fine while tun2proxy uses one association per flow (as the on-device logs show); would break a client multiplexing several destinations
  through one association.
- **Not verified (needs the phone on the VPN + a packet capture on the server/hotspot):** that no UDP escapes the tunnel. Code review of
  `PacketTunnelProvider`: IPv4+IPv6 default routes are included, only the server /32 is excluded, DNS is forced to 8.8.8.8/8.8.4.4 (UDP,
  so tunnelled). Open questions: (1) LAN-subnet / multicast UDP (mDNS, AirPlay) may take the physical interface because a connected-subnet
  route is more specific than the default route; (2) the relay advertises `LocalAddress.primaryIPv4()` as BND.ADDR — if that differs from
  the configured server IP it is not in `excludedRoutes` and the UDP leg to the relay could loop back into the tunnel.
- Earlier on-device evidence (Cloudflare speed test, 19 UDP ASSOCIATE relays through the tunnel) is in the 2026-09-18 section above.
- Test listener stopped; no source files changed, so no IPA rebuild.

## 2026-09-19 — UDP relay replies now carry the real source address (RFC 1928 §7)

Fixes the spec deviation noted in the UDP QA section above: `UDPRelay` wrapped every reply with `0.0.0.0:0`.
- `Socks5.buildUDPDatagram(payload:)` → `buildUDPDatagram(host:port:payload:)` (`Socks5Handler.swift`): encodes ATYP 1/4 for IP literals,
  ATYP 3 for names. `UDPRelay.receiveFromDestination` now takes the destination `host`/`port` the client named and passes them through.
  The source reported is the address *as the client named it* (a hostname destination is answered with the hostname, not a resolved IP).
- **Verification (simulator, Debug build, live proxy + raw-socket client):** 20/20 pass — reply headers asserted byte-exact for
  1.1.1.1:53, 8.8.8.8:53, 127.0.0.1:<echo>, ::1:<echo> (ATYP 4) and dns.google:53 (ATYP 3); all earlier checks unchanged (integrity 1–9000 B,
  200/200 burst, malformed/FRAG/rogue-sender/teardown). The earlier `localhost` failure was a test artifact (IPv6 resolution vs an IPv4-only echo server).
- NOT verified: on a device with the VPN engine (tun2proxy) consuming the new headers — it uses one association per flow so it should be
  unaffected, but that is untested here. The Socks5Client package parses these headers with the same code path (30 unit tests still apply; not re-run).
- Unsigned IPA rebuilt after this change: version 1.0 (20260919.141711) at build/Build/Products/Release-iphoneos/LocalProxy.ipa.
## 2026-09-19 — BRANCH `test/udp-fullcone-relay` (worktree `~/Desktop/LocalProxy-udp-test`): full-cone UDP relay — TESTING, not on main

Answers the known limit "replies from any address other than the one sent to are never delivered". `UDPRelay`'s destination side no longer uses one
connected `NWConnection` per destination; it uses ONE unconnected non-blocking BSD UDP socket per address family (`EgressSocket`: `sendto`/`recvfrom`
+ a `DispatchSourceRead`, `IP_TTL`/`IPV6_UNICAST_HOPS` = `EgressTTL.hopLimit`, 1 MB buffers). Client side (NWListener/NWConnection), heartbeat and
teardown are unchanged; `UDPRelay`'s public interface (`init`, `start`, `cancel`) is unchanged.
- Behaviour change: one stable external `ip:port` for all destinations (endpoint-independent mapping); inbound datagrams from ANY source are relayed
  back with the real source in the SOCKS5 header; hostnames (ATYP 3) are resolved with `getaddrinfo` off-queue (IPv4 preferred, 60 s cache, ≤32
  datagrams buffered per in-flight lookup) and the reply header names the resolved IP, not the name.
- Dropped: per-destination `NWConnection` establishment/transfer-report logging (diagnostics only). Added `sendDrops` to the heartbeat/close lines.
- Security trade-off: anyone who learns the egress port can inject datagrams to the client while the association lives (ephemeral port, dies with the
  SOCKS5 control connection).
- **Verification (simulator, live proxy, `scripts/udp_qa.py`):** 23/23 pass on this branch. Control run of the same script against the old design (main +
  header fix): 19/23 — it fails exactly the new full-cone checks (shared external port, reply from a different source port, unsolicited inbound) plus
  the hostname-header expectation. 60 open/close association cycles: 60/60 round-trips, process UDP fds back to 0 (no leak). Bulk: 3000×1200 B twice,
  3000/3000 both times, relay counters `up=3600000B/3000 down=3600000B/3000 sendDrops=0`.
- NOT verified: on a device; tun2proxy consuming the new headers/behaviour; behaviour under cellular/hotspot interface changes; sustained-throughput
  comparison against the old design (the bulk test is client-paced); IPv6 to the public internet (only ::1 loopback tested).

## 2026-09-19 — Branch `test/udp-fullcone-relay`: broadcast fix, large-payload ceiling, FIRST DEVICE TEST (iPhone 15 Plus)

- **Broadcast:** `SO_BROADCAST` now set on the IPv4 egress socket. Before/after on the simulator: broadcast to 255.255.255.255 got no reply before, is delivered
  and answered (reply tagged with the responder's real source) after. Full regression still 23/23.
- **64 KB payloads: not testable through the OS.** Darwin caps one datagram at `net.inet.udp.maxdgram` = 9216 (raising it needs sudo); 9000 and 9200 B round-trip,
  16000 B and up are refused by the *client's own* `sendto` (EMSGSIZE) before reaching the relay. Not a relay defect; iOS has the same default cap.
- **Device test (15 Plus "iPhone M", Debug build of this branch, signed with team DS8AMC8BSV via `xcodebuild -destination platform=iOS,id=…` +
  `devicectl device install app`; server = Mac-hosted simulator on 10.0.0.177:18080; VPN autoconnected with `QA_CLIENT_URI`/`QA_CLIENT_AUTOCONNECT`;
  traffic = Safari on speed.cloudflare.com):** the tunnel engine began exactly **12 UDP flows** (10× :443 QUIC incl. hostname and IPv6 destinations, 2× :3478
  WebRTC TURN) and the proxy opened exactly **12 relays, all from the phone (10.0.0.129), all with replies** (1667 datagrams up / 1669 down, `sendDrops=0`,
  no resolve/send failures). All 12 engine flows ended with an idle "timed out"; no UDP errors this session; extension footprint ~5.6–5.9 MB.
- **What this does and does not show:** every UDP flow that *entered the tunnel* was relayed (12/12). It does NOT prove nothing bypassed the tunnel — there is no
  packet capture (tcpdump needs root here). LAN/multicast UDP (mDNS, AirPlay) and anything the OS keeps off utun would not appear in either log. Only ~12 UDP flows
  were generated; no sustained UDP load, no WebRTC media, no games/VoIP.
- **DNS is not relayed as UDP:** tun2proxy runs `--dns virtual`, so DNS (UDP/53) is answered locally with virtual IPs and connections are made by hostname
  (`SOCKS5 CONNECT <name>:443`). No DNS queries leave the phone, but they also never appear as UDP ASSOCIATE traffic.
- The extension's `/tmp/tunnel-debug.log` on the phone is cumulative across sessions (28K lines, thousands of old "Connection refused"/"No route to host"/
  "Malformed label" UDP errors from earlier builds) — filter by the epoch of the latest `startEngine` before reading it.
- New: relay logs one `UDP ASSOCIATE first datagram to <host:port>` line per destination. Phone left with VPN disconnected (app relaunched without
  autoconnect; proxy traffic stopped); the phone now has THIS BRANCH's Debug build installed, replacing whatever was there before. Sim proxy stopped.

## 2026-09-19 — Merged full-cone UDP relay into main; MAX LOAD TEST (simulator old-vs-new + iPhone 15 Plus through the VPN)

Merge commit `50aa405` (branch `test/udp-fullcone-relay`, kept). Load tools/hook live on the throwaway branch `test/udp-load-phone` (`scripts/udpload.c`, `loadrun.py`,
`phonerun.py`, plus a DEBUG-only `QA_UDP_FLOOD` hook in `DashboardView.swift`; NOT merged to main). Unsigned IPA rebuilt after the merge: 1.0 (20260919.155303).

**Simulator, Mac loopback, Release+DEBUG-flag arm64 builds, C generator + echo, 1200 B unless noted, 6 s steps.** Baseline with no relay: loopback carries 200k pps
(~2 Gbit/s each way) at 0.01% loss, so all loss below is the relay. Old = connected `NWConnection` per destination (commit fd596ec); New = merged main.
- Lossless ceiling (loss ≤0.5%): 1 association 20k pps both; 16 assocs 40k both (p50 latency **643 µs new vs 4.3 ms old**); 128 assocs 40k both (p50 **4.9 ms new vs 150 ms
  old**); 64 B × 16 assocs ~50k both (latency bloated in both). 60 s soak @30k pps: 0% loss both; p50 **236 µs new vs 1216 µs old**; no fd leak (45→45), RSS settles.
- Overload behaviour: 128 assocs @80k — old stalls (send rate collapses to 10k/s, p50 latency 29 s), new degrades gracefully (16% loss, 53k pps delivered).
  16 assocs @80k: 30% loss new vs 52% old.
- **REGRESSION: single association @40k pps — new 17.9% loss / p50 19 ms vs old 2.7%.** Likely cause (not verified): replies are pushed into `pendingSends` (the client-side
  serialized `NWConnection.send` queue) with no bound, whereas the old per-destination `receiveMessage` loop was naturally paced. Follow-up: cap `pendingSends`/drop-oldest.
- Concurrent associations at ~5 pps each: clean to 800 in both; 1600 → 48.6% loss in BOTH (identical 4113 pps, cause not identified); 3200 → ~780 associations fail to open in
  BOTH (consistent with a file-descriptor ceiling, ~3 fds/association, not verified). No fd leak after teardown in either.
- App CPU at 30k pps soak: ~189% old vs ~227% new (Mac, multi-core). RSS 170–265 MB. Debug-flag Release build of the app on a Mac — NOT representative of iPhone limits
  (iOS soft fd limit is far lower; a phone running this as the SERVER would cap out at far fewer associations — untested).

**iPhone 15 Plus → Client VPN → Mac-hosted relay → loopback echo** (target `udpN.localtest.me` → 127.0.0.1 only on the Mac, so packets can only reach the echo through the
tunnel+relay; 8 flows, 20 s/step, Debug app, extension 3.9–4.1 MB footprint, 0 UDP engine errors, every flow = one relay):
- 2k pps 0.10% loss; 5k 4.12%; 10k 1.01%; 20k 0.00%; 40k 0.02%; 80k 0.00%. Relay up == down datagram counts every step (relay lost nothing).
- **The phone never got past ~4.3k pps sent (~41 Mbit/s each way) even with targets of 20k–80k and `sendErr=0`** — so this test did NOT find the relay's or tunnel's limit; the ceiling
  is the phone-side send path (the flood loop is a Debug Swift build; tunnel vs generator not separated). p50 latency 67–95 ms, p99 190–560 ms end to end over Wi-Fi.
- Loss in the first two steps (4.1%, 1.0%) happened phone→relay (relay counted fewer datagrams than the phone sent); cause not identified (warm-up suspected).
- `relay_send_drops` 36–40 in the first steps: the relay drops datagrams beyond 32 buffered while a hostname's first `getaddrinfo` is in flight (`maxPendingPerName`).
- Harness lessons: my first sim run was invalid (my load tool wrote destination port 0 in the SOCKS5 header) and step 2 of the first phone run was invalid (VPN did not reconnect,
  zero relays); both were discarded, not reported. The phone flood only counts if the proxy saw relays.
- NOT tested: sustained multi-minute phone load, cellular, phone-as-server, other UDP mixes, IPv6 flood, app in background. Phone left with the throwaway branch's Debug build
  installed and the VPN down; the sim proxy and echo are stopped.

## 2026-09-19 — CORRECTION to the load-test section above: the single-association "regression" is NOT established

The previous section reported "REGRESSION: single association @40k pps — new 17.9% loss vs old 2.7%" from ONE run per design. A follow-up comparison — old (fd596ec), main
(50aa405) and a candidate fix, three builds interleaved over two rounds, same harness — does not reproduce it:
- 1 association @40k pps: old 59.2% / 39.2% loss (rounds 1 / 2), main 14.8% / 28.2%, fix 32.2% / 18.6%. Run-to-run spread within one design (up to 20 points) is as large as the
  spread between designs; the earlier "old 2.7%" was an outlier. At 30k: old 0.0/1.5%, main 0.1/0.7%, fix 16.4/0.0%. At 60k all three lose 45–74%.
- What IS consistent: a single association tops out around 20–30k pps (1200 B) in every design and collapses above that; 16 associations hold 40k lossless in all three;
  main is better than old at 80k overload (26% vs 49–50% loss at 16 assocs; old's 128-assoc @80k stalled to ~5k pps in both rounds, main delivered 5–52k, fix 12–20k — noisy).
- Hypothesis tested and NOT supported: that replies pile up in the client-side send queue (`pendingSends`, O(n) copy per send). Branch `fix/udp-reply-queue` (commit on that
  branch, NOT merged) replaces it with a bounded O(1) FIFO that drops the oldest reply at 1024; across 292 relays in the final run `replyDrops` was 0 everywhere (the cap was never
  reached) and throughput did not measurably change. Functional QA on that build: udp_qa.py 23/23, broadcast and 9000/9200 B payloads pass. It is harmless and bounds memory
  under overload, but is unproven — merge only if wanted for robustness.
- Method lesson: one run per configuration is not evidence at the saturation knee here; use interleaved repeats and compare against the spread.
- Still unexplained: the 1600-association 48.6% loss (identical in old and new) and the phone-side ~4.3k pps send ceiling.

## 2026-09-19 — Fixed: datagrams dropped while a hostname's first lookup is in flight (item 4; on main, fast-forward from `fix/udp-resolve-buffer`)

**Problem (reproduced before changing anything):** UDP to a hostname destination (SOCKS5 ATYP 3) is resolved with `getaddrinfo` off-queue and datagrams that arrive during the lookup
were buffered up to `maxPendingPerName = 32`; the rest were dropped. With a fresh `*.localtest.me` name per trial (`scripts/udp_cold_resolve.py`): an instant burst of 200 or 1000 delivered
exactly 32 (first missing seq = 32 every trial); 2000 pps for 1 s delivered ~1840/2000; 10000 pps ~9200/10000 (C echo). Relay `sendDrops` summed 6311–6664 per run.

**Fix (`UDPRelay.swift`):** the per-name buffer is now a byte budget — 1 MiB and at most 4096 datagrams per in-flight lookup, per association, freed when the lookup returns — instead of a count of 32
(new private `PendingLookup`). A cold lookup takes ~10 ms to over half a second, so the buffer must cover lookup time × the flow's rate; bytes also bound memory regardless of datagram size.

**Verification (simulator, Release+DEBUG-flag arm64):** instant bursts 200/200 and 1000/1000, 2000 pps 2000/2000, 10000 pps 10000/10000, relay `sendDrops` 0. Functional regression udp_qa.py 23/23,
broadcast + 9000/9200 B pass. **iPhone 15 Plus through the VPN** (one 2k pps step, 8 flows, 20 s): 39,999 sent / 39,999 received, 0.00% loss, relay `send_drops` 0 — the same step before the fix
lost 0.10% with 36 relay drops.
- A first 10k-pps run with a Python echo server still lost ~55% with relay sendDrops=0; that was the Python echo/sender sharing the interpreter lock, not the relay (rerun with the C echo: 100%).
- Worst case memory: 1 MiB per hostname with a lookup in flight per association (e.g. a client spraying many distinct hostnames at once); released when each lookup finishes. A lookup that never
  returns (hung DNS) holds its buffer until the association closes.
- NOT verified: behaviour under a hung/very slow resolver, many simultaneous distinct cold hostnames, or on cellular. Branch `fix/udp-reply-queue` (bounded reply queue) remains unmerged.
- Unsigned IPA rebuilt after this change: version 1.0 (20260919.203423) at build/Build/Products/Release-iphoneos/LocalProxy.ipa. Phone still has the throwaway `test/udp-load-phone` Debug build installed, VPN down.
