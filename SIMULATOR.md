# Simulator quick reference — LocalProxy

Consolidated so "which simulator, what's its ID, how do I drive it" doesn't
need rediscovering each session. Bundle ID throughout: `com.Korporate1k.LocalProxy`
(display name is "NetBridge" — cosmetic only, see `HANDOFF-QA-PASS.md`).

## Find the simulator

```bash
xcrun simctl list devices booted
```

As of this writing there's one persistent simulator used for all testing:
**iPhone 17 Pro**, UDID `C61D09FC-8D16-4250-9F98-6D4D6113630F` (iOS 26.5). If
`booted` comes back empty, boot it: `xcrun simctl boot C61D09FC-8D16-4250-9F98-6D4D6113630F`.
Don't hardcode the UDID in scripts that outlive one session — re-run the
`list` command above first, since a new/renamed simulator changes it.

There's no standalone Simulator.app on this Xcode install — for a live GUI
view, open `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`.

## Build, install, launch

```bash
DEV=C61D09FC-8D16-4250-9F98-6D4D6113630F
cd /Users/matthew/Desktop/LocalProxy
xcodebuild -project LocalProxy.xcodeproj -scheme LocalProxy \
  -destination "id=$DEV" -configuration Debug build

APP=$(find /Users/matthew/Library/Developer/Xcode/DerivedData/LocalProxy-*/Build/Products/Debug-iphonesimulator/LocalProxy.app -maxdepth 0 | head -1)
xcrun simctl install $DEV "$APP"
xcrun simctl launch $DEV com.Korporate1k.LocalProxy
```

### QA launch hooks (DEBUG-only, compiled out of Release/IPA)

Set via `SIMCTL_CHILD_<VAR>=<value>` on the `simctl launch` line (the
`SIMCTL_CHILD_` prefix is simctl's own convention for passing environment
into the launched process):

- `QA_TAB=<0-3>` — jumps straight to a tab, skipping the need to tap:
  `0` Dashboard, `1` Devices, `2` Client, `3` Settings.
- `QA_AUTOSTART=1` — starts the proxy relay ~2s after launch, no tap needed.

```bash
SIMCTL_CHILD_QA_TAB=2 SIMCTL_CHILD_QA_AUTOSTART=1 xcrun simctl launch $DEV com.Korporate1k.LocalProxy
```

## Screenshot / logs

```bash
xcrun simctl io $DEV screenshot /path/to/out.png

CONTAINER=$(xcrun simctl get_app_container $DEV com.Korporate1k.LocalProxy data)
tail -n 40 "$CONTAINER/Documents/localproxy.log"
```

## No UI tap-automation is available here

Accessibility permission isn't granted to this environment's Terminal, so
taps/toggles can't be driven programmatically. Work around it with, in order
of preference:

1. The `QA_TAB`/`QA_AUTOSTART` launch hooks above.
2. Reading `localproxy.log` for state.
3. Screenshotting for anything visual.
4. **Driving real traffic at the app's listener directly from the Mac** —
   Simulator networking is NOT virtualized, it shares the host Mac's network
   stack, so `127.0.0.1:<port>` (current persisted port: check the log's
   `saveLastSettings: writing port=...` line, or the Settings tab screenshot)
   reaches the app's `NWListener` directly. This also means any local Swift
   package the app vendors (e.g. `Socks5Client`) can be exercised for real,
   end-to-end, from a throwaway command-line SwiftPM executable that depends
   on it by local `path:` and dials `127.0.0.1:<port>` — without touching the
   UI at all. Used this to verify the `Socks5Client` RFC 1929 wire-format
   port (2026-09-16, see `HANDOFF.md`): a scratch executable reproduced
   `Socks5ClientTestView`'s CONNECT and UDP ASSOCIATE checks bit-for-bit and
   got `HTTP/1.1 200 OK` / a 61-byte DNS reply back through the real running
   proxy.

## Real device signing (as of 2026-09-16)

A real Apple Developer Team (`DS8AMC8BSV`) is now configured
(`DEVELOPMENT_TEAM` in `project.pbxproj`, both the `LocalProxy` and
`LocalProxyTunnel` targets). `xcodebuild ... -sdk iphoneos -allowProvisioningUpdates`
successfully auto-fetches real provisioning profiles for both targets — but
the actual `codesign` step fails with `errSecInternalComponent` from this
automated shell every time, regardless of a fresh keychain/fresh cert
(confirmed not stale data — see `CLIENT-VPN-PROGRESS.md` for the full
troubleshooting log). This looks like a deliberate limitation of running
headless (no GUI session to answer the one-time "codesign wants to use a
key in your keychain" prompt a new private key requires), not a fixable
config issue. **Don't spend time re-litigating this from a shell** — if a
real signed device/archive build is needed, open `LocalProxy.xcodeproj` in
Xcode.app itself and Run/Archive from there; the project is fully ready.
