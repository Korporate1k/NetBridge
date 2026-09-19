# HANDOFF — Upload Throughput Test tool

Written during implementation of the "Upload Throughput Test" diagnostic tool (companion to
the existing SOCKS5 Client Test). Append-only from here — add new dated sections below,
don't edit/remove what's already written.

## What this is

A new Settings → Tools screen that dials a destination IP:port directly (TCP or UDP,
bypassing the proxy) and pushes a bounded amount of synthetic data, reporting achieved
throughput. Explicitly scoped as a bounded, single-connection measurement tool: a hard byte
cap (5 GB) and a hard duration cap (60 min) — whichever hits first wins — enforced
independently of whatever the user types into the (free-form, "variable with built-in
limits") transfer-cap/duration/rate-limit fields. Full design rationale and implementation
spec: `/Users/matthew/.claude/plans/on-the-topic-of-graceful-reddy.md`.

## Files touched (2026-09-16)

- **`LocalProxy/UploadThroughputTestView.swift`** (new) — the whole feature: destination
  host/port/protocol picker, transfer-cap/duration/rate-limit fields (each live-clamped to
  a hard ceiling), and the actual send loop. Reuses `DirectTCPTransport`/`NWParameters.udp`
  for dialing, `RateLimiter` (existing token-bucket, previously only used for per-device
  bandwidth caps) for optional pacing, and `ProxyStats` for byte counting — no new
  networking primitives invented.
- **`LocalProxy/RemoteConfig.swift`** — added `showUploadTest: Bool` (default `true`)
  following the exact existing four-touchpoint pattern used by every other `show*` flag:
  struct field + `CodingKeys`, memberwise `init` default, `init(from decoder:)` fallback,
  and `RemoteConfigManager`'s published property + `apply()`. Also added it to the big
  `[remoteconfig] applied — ...` debug log line for parity with every other field.
- **`LocalProxy/DashboardView.swift`**, `SettingsView.toolsSection` — added a second
  `NavigationLink` next to the SOCKS5 tester, independently gated by
  `remoteConfig.showUploadTest`. The section-level gate now reads
  `if remoteConfig.showSocks5Tester || remoteConfig.showUploadTest`. Also added a
  `#if DEBUG`-only automation hook (`qaPushUploadTest` + a `QA_PUSH_UPLOAD_TEST` env var
  read in `onAppear`, using the deprecated `NavigationLink(destination:isActive:)` form)
  since this view's inputs are pure local `@State` with no other way to drive them from
  Terminal without Mac Accessibility permissions. Compiled out of Release/IPA builds.
- **`FleetAdmin.html`** — new "Show Upload Throughput Test" checkbox (`id="showUploadTest"`)
  in the Feature Visibility card, added to the `BOOL_FIELDS` JS array.
- **`LocalProxy.xcodeproj/project.pbxproj`** — four-touchpoint addition for
  `UploadThroughputTestView.swift` (`PBXBuildFile`, `PBXFileReference`, `PBXGroup` entry,
  `PBXSourcesBuildPhase` entry), placed next to `Socks5ClientTestView.swift`'s own entries
  in all four sections.

## A real bug found and fixed during testing

`UploadThroughputTestView.swift`'s `finish()` originally called `connection.cancel()`
immediately after queuing the final TCP close message with a fire-and-forget
(`.idempotent`) completion. Verified empirically with a real receiver: the app reported
"Sent 10.0MB" successfully, but the receiver got **0 bytes** — the abrupt cancel was tearing
the connection down before already-buffered data actually reached the wire. Fixed by
waiting for the final message's own `.contentProcessed` completion before cancelling (UDP
doesn't have this problem — each send is already a complete, standalone datagram by the
time its own completion fires, so it cancels immediately). Re-verified after the fix with a
Python socket receiver (see below) — full byte count now arrives correctly.

## QA automation hooks added (env vars, `#if DEBUG` only)

Same rationale as this session's earlier QA pass: no Mac Accessibility permission available
to tap into a `NavigationLink` or type into text fields. Set via
`SIMCTL_CHILD_<VAR>=... xcrun simctl launch ...`:

- `QA_PUSH_UPLOAD_TEST=1` — auto-navigates into the Upload Throughput Test screen from
  Settings (requires `QA_TAB=2` to already be on the Settings tab).
- `QA_UPLOAD_HOST`, `QA_UPLOAD_PORT`, `QA_UPLOAD_PROTOCOL` (`TCP`/`UDP`), `QA_UPLOAD_CAP_MB`,
  `QA_UPLOAD_CAP_SEC`, `QA_UPLOAD_RATE_MBPS` — pre-fill the screen's fields.
- `QA_UPLOAD_AUTOSTART=1` — taps Start automatically ~0.5s after the fields are filled.

## Known collision with concurrent work on this same repo

Another session is actively building a separate "wire sniffer" feature in this same working
tree (no git commits as checkpoints on either side, so both sessions are editing shared
files live): `TLSClientHello.swift`, `TrafficSniffer.swift`, `GeoIPLookup.swift`,
`ClientConfiguration.swift`, `ClientTunnelManager.swift`, `ClientTabView.swift`,
`QRScannerView.swift`, plus their own edits to `DashboardView.swift` (a new "Inspect" tab,
`ClientTunnelManager`/`ClientConfiguration` state) and presumably `project.pbxproj`. Their
`DashboardView.swift` edits fully coexist with the `toolsSection`/`showUploadTest` changes
above (confirmed side-by-side in the file as of this writing) — nothing here was designed
to conflict with their work, and nothing of theirs was removed.

**To avoid stepping on their in-progress edits further**, verification of this feature
(build + simulator testing) is being done against an isolated copy at
`/private/tmp/claude-501/-Users-matthew/983649b5-0c8a-4abf-b1c6-b4bf96dc3860/scratchpad/LocalProxy_isolated`,
not the live working tree. That copy's `project.pbxproj` also had to gain entries for their
four not-yet-wired-in files (`ClientConfiguration.swift`, `ClientTabView.swift`,
`ClientTunnelManager.swift`, `QRScannerView.swift` — they exist on disk but weren't yet in
the live `project.pbxproj` as of this writing) purely so the isolated copy would compile;
**that pbxproj wiring was only applied to the throwaway isolated copy, not to the real
`LocalProxy.xcodeproj/project.pbxproj`** — the other session should still do that wiring
themselves in the real project when their feature is ready, the same four-touchpoint
mechanical step documented above and in the earlier QA-pass handoff.
