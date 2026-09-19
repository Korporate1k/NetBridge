# PROJECT HANDOFF — NetBridge (LocalProxy) Remote Config: Full QA Pass + Operator Manual

Written by the engineer who built this system, for whoever picks up the testing pass.
Read the whole thing before touching anything — the constraints section will save you
from repeating dead ends I already hit.

## What this project is

`~/Desktop/LocalProxy` is a from-scratch iOS app (Swift/SwiftUI, Network.framework —
no third-party networking libs except a small local `Socks5Client` SPM package). It's a
local HTTP CONNECT + SOCKS5 + UDP proxy, distributed via sideloading (not App
Store/TestFlight yet). Display name is "NetBridge" (CFBundleDisplayName only — the
Xcode target, bundle ID, and all source files are still named LocalProxy; this was a
deliberate cosmetic-only rebrand, not a functional change — don't "fix" this naming
mismatch, it's intentional).

It monetizes via Freemium + StoreKit2 non-consumable IAP, a 5GB/day free cap, and an
app-managed (not StoreKit-native) free trial. All of the monetization, trial, kill-switch,
and feature-visibility behavior is controlled by ONE remote JSON config file — a secret
GitHub Gist — fetched and applied at runtime with zero app updates required. That
mechanism (`RemoteConfig.swift`) is the entire subject of this QA pass.

## Architecture you need to understand before testing

- `LocalProxy/RemoteConfig.swift` — `RemotePromoConfig` (the Codable JSON shape, ~30
  fields) and `RemoteConfigManager` (an `ObservableObject` that fetches, caches in
  Keychain, and fans out every field to the relevant subsystem's own setter).
- Fetch behavior: on launch, applies last-known-good config from Keychain immediately
  (so the app isn't stuck in a bad state offline), then fetches the live Gist. It also
  now POLLS every 10 seconds while the app is running (added this session, per explicit
  request — "changes apply within 10 sec") — each request is cache-busted with a
  timestamp query param + `.reloadIgnoringLocalAndRemoteCacheData`, because
  gist.githubusercontent.com sits behind a CDN that otherwise caches raw content for a
  few minutes and would silently defeat a fast poll.
- The Gist: id `92817bcaa07f1fb621a903919d1574a9`, file `localproxy-config.json`, secret
  (unlisted, not access-controlled) — readable by anyone with the URL, no auth needed
  for the app's own fetches:
  `https://gist.githubusercontent.com/Korporate1k/92817bcaa07f1fb621a903919d1574a9/raw/localproxy-config.json`
- Writing to it requires a GitHub PAT with `gist` scope — **must be a classic token**,
  fine-grained tokens don't support the Gists API (this caused a real 403 bug earlier;
  already fixed in the admin tool).
- `gh` CLI is installed at `~/.local/bin/gh`, already authenticated as GitHub user
  `Korporate1k` with an OAuth token that has gist access (`gh gist edit
  92817bcaa07f1fb621a903919d1574a9 -f localproxy-config.json <file>` works).
- `FleetAdmin.html` (repo root) is a hand-built, LOCAL-ONLY admin GUI for editing the
  Gist — deliberately NOT a published Claude Artifact, because Artifacts can't make
  arbitrary fetch/XHR calls to api.github.com (CSP restriction). Open it with `open
  FleetAdmin.html`. It manages its own GitHub PAT in localStorage.
- Debug logging: the app writes to `Documents/localproxy.log` inside its own sandbox
  container, tagged `[remoteconfig]`, `[server]`, `[listener]`, `[location]`, etc. via
  `DebugLog.important(tag, message)`. This is your primary ground truth for anything
  that doesn't have a directly visible UI element — READ THE LOG, don't guess.

## Devices available to you

- Simulator: "iPhone 17 Pro", UDID `C61D09FC-8D16-4250-9F98-6D4D6113630F`. This is
  where almost all testing should happen.
  - Pull its log: `xcrun simctl get_app_container <UDID> com.example.LocalProxy data`
    then read `<that path>/Documents/localproxy.log`.
  - Screenshot: `xcrun simctl io <UDID> screenshot <path>.png`
  - GUI viewer: this Xcode install has NO standalone Simulator.app — open
    `/Applications/Xcode.app/Contents/Applications/DeviceHub.app` instead if the user
    wants to watch live.
- Physical device: iPhone 17 Pro Max, UDID `00008150-0012191422D0C01C`, connected via
  USB, visible to `xcrun devicectl`. **You cannot build+install to it directly** — there
  is no code-signing identity or development team configured in this environment
  (`xcodebuild -sdk iphoneos` fails with "Signing for LocalProxy requires a development
  team"). The user sideloads via a third-party tool ("SideInstaller") already on their
  phone. Your job is only to produce a fresh **unsigned** IPA for them:
  `bash scripts/build-ipa.sh` → outputs
  `build/Build/Products/Release-iphoneos/LocalProxy.ipa`, auto-stamped with a fresh
  build number every run. **Standing rule the user has explicitly set: rebuild this IPA
  after every change you verify in the simulator, without being asked** — this is
  memorialized in the auto-memory file `feedback_ipa_rebuild.md` if you have access to
  it; if not, just follow the rule anyway.
  - You CAN pull that device's log the same way as the simulator, via
    `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer
    --domain-identifier com.example.LocalProxy --source "/Documents/localproxy.log"
    --destination <path>`. Useful for confirming the phone and sim actually agree.
  - **Landmine**: this phone ALSO has a second, unrelated app installed —
    `com.example.NetBridge` v1.1 — which is a completely different, earlier project
    (`~/NetBridge`) with hotspot/carrier-tethering-hiding logic baked in that I
    (the original designer) explicitly refused to touch or ship. It shows on the home
    screen with the identical display name "NetBridge". Do not confuse the two. The
    one under test is bundle ID `com.example.LocalProxy`.

## Known environment constraints (don't waste time rediscovering these)

1. **No UI tap-automation is available.** `osascript`/System Events reports 0
   accessible windows for the DeviceHub process — Accessibility permission has not been
   granted to this environment's Terminal, and I could not grant it non-interactively.
   This means you CANNOT literally tap "Start", flip in-app toggles, or navigate tabs
   by simulated touch. Work around this by:
   - Seeding/reading `UserDefaults` via `xcrun simctl spawn <UDID> defaults
     write/read <bundle-id> <key> ...` — this goes through the real `cfprefsd`
     daemon properly, unlike hand-editing the container's `.plist` file directly on
     disk (I did that once, it silently desyncs from what `cfprefsd` actually serves
     to a running process — cost me a real debugging detour, don't repeat it).
   - Reading the debug log for anything state-related.
   - Screenshotting for anything visual.
   - Driving actual network traffic at the app's listening port directly from the Mac
     terminal (curl/nc) to test real proxy behavior, since Simulator networking is NOT
     virtualized — it shares the host Mac's network stack directly. The app's bound
     address is whatever the Mac's own primary interface IP is (check
     `ifconfig en0 | grep "inet "` — at last check this Mac was tethered to a phone
     hotspot giving it `172.20.10.8`, but that can change; don't hardcode it, look it
     up fresh). **The proxy must actually be in the "Started" state for this to work**,
     and since you can't tap Start, either ask the user to tap it once (30 seconds of
     their time) or find another activation path (a URL scheme, a
     `XCUITest`/`xcodebuild test` UI test target, or requesting the user grant
     Accessibility permission to Terminal in System Settings → Privacy & Security →
     Accessibility — any of these are fine, just don't silently skip Start-dependent
     tests without flagging that you skipped them and why).
   - If you determine you genuinely need tap automation, ask the user directly rather
     than guessing around it — they were mid-way through discussing exactly this
     limitation with me when this handoff was written.
2. **Writing to the live Gist may be blocked by this environment's auto-mode
   permission classifier** as a protected "Feature Flag Write" — this happened to me
   mid-session on an unprompted test write. If it happens to you: don't try to work
   around it. Either ask the user for explicit one-time authorization to write test
   values to the Gist (this session's whole point is testing every toggle, so they'll
   likely say yes), or ask the user to make the test edits themselves through
   `FleetAdmin.html` while you watch the log/screenshots — both are legitimate paths.
3. **The Gist is currently NOT in a safe production state** — it was left mid-test.
   Before you finish, you MUST restore it to sane values (see "Safe defaults" below),
   whether or not you were the one who changed it, because as of this handoff
   `relayEnabled`/several `show*` flags/etc. may be toggled off, which would block the
   proxy for any real user who opens the app while you're mid-test.
4. `xcodebuild`/`xcrun` are all present and working; a normal
   `xcodebuild -project LocalProxy.xcodeproj -scheme LocalProxy -sdk iphonesimulator
   -configuration Debug -derivedDataPath build build` succeeds cleanly. SourceKit may
   show stale "cannot find type in scope" diagnostics in the editor right after an edit
   — ignore those, trust the actual `xcodebuild` result, not the live diagnostics.
5. A stale system-wide SOCKS proxy (`~/.zshrc`, now commented out) was found and fixed
   this session — it was pointing `ALL_PROXY`/`HTTPS_PROXY`/`HTTP_PROXY` at a dead
   `172.20.10.1:8081` and breaking unrelated CLI tools. Just flagging that this
   environment had leftover cruft from prior testing sessions — check for more if
   something inexplicably can't reach the network.

## The full field list — what "thoroughly tested" means per field

For every boolean `show*`/kill-switch field: confirm (a) the Gist value is fetched and
logged in `[remoteconfig] applied — ...`, (b) the corresponding UI element is actually
present/absent or the corresponding subsystem actually starts/refuses, with a screenshot
or log line as evidence, (c) flipping it back live (within the 10s poll window) updates
the running app without a relaunch. For every numeric/string tuning field with no direct
UI element: confirm via log that the value reached the correct manager's property (grep
the relevant subsystem's own debug tag), and where cheaply feasible, exercise the actual
behavior (e.g. `maxConcurrentTunnels: 1` + two simultaneous `curl`/`nc` connections
through the proxy should show the second one refused in the `[listener]` log).

Full field list (current code defaults — i.e. what's used if the Gist is ever
unreachable — shown in parens):

- `relayEnabled` (true) — master kill switch. False ⇒ `ProxyServer.start()` refuses
  immediately with lastError "This service is temporarily unavailable...", AND
  force-stops an already-running proxy within one poll cycle via `stopIfDisallowed()`.
- `paywallEnabled` (false) — shows/hides the "Upgrade" prompt and daily-cap enforcement
  banner on the dashboard.
- `dailyCapGB` (5) — the free-tier daily data cap; also interpolated live into
  `UpgradeView`'s pitch copy — confirm the copy always matches the number, never says a
  stale hardcoded "5GB".
- `bandwidthPresetsMbps` ([1,5,10]) — the per-device bandwidth picker options in
  Devices → (any device) → Limits.
- `trialEnabled` (true) — whether a fresh install starts a trial at all.
- `trialDurationHours` (168) — trial length from first launch.
- `trialEndDate` ("") — an optional absolute ceiling date (`yyyy-MM-dd`), combined with
  duration via `min(...)` — NOT an override (the user explicitly rejected an
  absolute-only design earlier; both duration AND ceiling must be able to coexist).
- `trialForceEndAll` (false) — immediately ends every trial in progress, remotely,
  without touching the duration/ceiling settings.
- `bonusActive` / `bonusDays` / `campaignID` (false / 7 / "") — grants a one-time bonus
  extension; idempotent per distinct `campaignID` (changing the ID re-triggers it for
  everyone; reapplying the same ID is a no-op — test both).
- `maxRestartAttempts` (5) / `restartWindowSeconds` (60) — listener auto-restart budget
  after an unexpected drop.
- `maxConcurrentTunnels` (0 = unlimited) — hard cap on simultaneous tunnels.
- `outboundRetryAttempts` (3) / `outboundRetryBaseSeconds` (1) — outbound connection
  retry/backoff (exponential: `base * 2^attempt`).
- `doHDefaultUpstreamURL` (cloudflare-dns.com) / `doHTimeoutSeconds` (4) — DoH resolver
  tuning.
- `connectionHistoryLimit` (200) / `usageHistoryCapacity` (720) — in-memory history
  sizes, UI-visible in their respective screens/graphs.
- Feature visibility group (all default true/enabled): `showQRCode`,
  `showSocks5Tester`, `showProfiles`, `showAdditionalListeners`,
  `showDeviceBandwidthControls`, `autoRestartEnabled`, `doHEnabled`,
  `backgroundKeepAliveEnabled`. NOTE: the last three were moved into this group
  (both in `FleetAdmin.html` and in `RemoteConfig.swift`'s doc comment/struct field
  order) earlier this session at the user's request, to reflect that they're
  subsystem-visibility/circuit-breaker switches, not just UI-section toggles like the
  other five. Verify this grouping is still consistent between the two files.
- `minSupportedVersion` ("") — empty means no gate; otherwise a numeric-compared
  version string (`"1.10"` correctly beats `"1.9"` — verify this specifically, string
  comparison would get it backwards) below which the whole app is replaced by a
  blocking "Update Required" screen.
- `announcementActive` / `announcementMessage` (false / "") — a dismissible-looking
  (confirm whether it's actually dismissible or persistent — check) banner at the top
  of the Dashboard tab.

## Specific open item I did not finish — pick this up first

I was in the middle of checking whether the "Enable background keep-alive" button
(Settings → Proxy section, only shown when location authorization isn't already
`.authorizedAlways`) is properly hidden/disabled when the remote
`backgroundKeepAliveEnabled` flag is OFF. As written, `BackgroundKeeper.start()`
already refuses if `Self.remoteEnabled` is false — but that only stops the keep-alive
from actually engaging; it doesn't stop the button from *existing* and firing the
location permission system prompt when tapped. The user's explicit requirement was:
"be sure visual features do not prompt for access unless turned on." Check
`DashboardView.swift` around the `proxySection` (roughly line 485-514) and either
confirm the button is already conditionally hidden behind
`remoteConfig.backgroundKeepAliveEnabled`, or add that gating if it's missing — this is
a real, plausible gap, not a hypothetical. Also separately confirm: no `AVCaptureDevice`
usage exists anywhere (QR is generated/displayed only, never scanned, so no camera
permission risk) — I already grepped and found none, but re-verify after your own edits.

## Deliverable: PDF Operator Manual

Once every field above is verified, produce a polished PDF documenting all ~30 fields:
what each does, its default/safe value, and a screenshot showing the UI difference
on vs. off (for fields with a visible effect) or a log excerpt (for backend-only
fields). This PDF is the permanent reference the user (the Operator, i.e. the person
running FleetAdmin.html to manage the live app) will use going forward — write it for
that audience: assume they know nothing about the Swift code, only that they're editing
a form and want to know exactly what will happen to real users when they hit Save.

No PDF-generation CLI tool (`wkhtmltopdf`/`weasyprint`/`pandoc`) is installed, but
Google Chrome is, at `/Applications/Google Chrome.app`. Build the manual as a single
polished HTML file (embed screenshots as base64 data URIs so it's self-contained), then
render it with:
`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless
--disable-gpu --print-to-pdf="<output>.pdf" --no-pdf-header-footer
"file://<path-to-html>"`
Verify the resulting PDF actually opened/rendered correctly before calling this done —
don't just trust the command exited 0.

## Before you report done

1. Restore the Gist to safe production values. "Safe" here means the code defaults
   above, EXCEPT for two intentional standing product decisions the user made
   explicitly earlier this session — do not revert these two:
   - `dailyCapGB: 5` (the intended free-tier cap — matches default, just confirming)
   - `trialEndDate: "2027-01-01"` (an explicit standing decision: "set free trial to
     end for everyone jan 1 2027" — combined with duration, per their "customizable,
     not absolute" trial design; this is a real product decision, not test cruft —
     leave it in place unless the user tells you otherwise).
   Every other field should return to its code default as listed above (in particular:
   `relayEnabled: true`, `trialForceEndAll: false`, `paywallEnabled: false` unless the
   user says otherwise, all `show*`/feature-visibility flags `true`,
   `announcementActive: false`).
2. Rebuild the IPA one final time (`bash scripts/build-ipa.sh`) so the user's phone can
   be brought fully current in one sideload.
3. Report back: a punch list of every field, pass/fail, and the PDF's file path.
