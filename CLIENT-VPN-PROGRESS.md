# Progress — Full system-level SOCKS5 VPN client + Client tab

Live log, updated ~every 1 minute while work is in flight. Plan file:
`/Users/matthew/.claude/plans/lucky-tinkering-zebra.md`.

Renamed from `PROGRESS.md` to this file at 09:58 — another active session
(`upload-throughput-diagnostic`, working in this same shared, uncommitted
repo) was using the generic name too and its write clobbered mine. Its
content is untouched; this is now the dedicated log for this task.

## Task status

- [x] #1 Vendor lwIP NO_SYS core sources into LWIPTunnelEngine/Sources/CLwIP
- [x] #2 Build LWIPTunnelEngine Swift package (TunnelEngine wrapper)
- [x] #3 Standalone test: TunnelEngine TCP flow against real SOCKS5 listener
- [x] #4 Standalone test: TunnelEngine UDP flow (DNS-style) against real SOCKS5 listener
- [x] #5 Add entitlements files (app + extension)
- [ ] #6 Add LocalProxyTunnel NEPacketTunnelProvider Xcode target — in progress (project.pbxproj surgery — see note below)
- [x] #7 Extend KeychainStore.swift with optional accessGroup param
- [x] #8 Add ClientConfiguration.swift
- [x] #9 Add ClientTunnelManager.swift
- [x] #10 Add QRScannerView.swift + NSCameraUsageDescription
- [x] #11 Add ClientTabView.swift
- [x] #12 Wire Client tab into DashboardView
- [ ] #13 Build both Xcode targets for Simulator; screenshot Client tab
- [ ] #14 Append HANDOFF.md, update SIMULATOR.md, rebuild unsigned IPA

## Shared-repo note

This repo has multiple active sessions editing the same uncommitted working
tree concurrently (confirmed via `git status`: many files modified/untracked
beyond this task's scope). `upload-throughput-diagnostic`'s own log
(`PROGRESS.md`) says its `project.pbxproj` changes are already done and it's
waiting on this session's in-progress files to settle before rebuilding the
IPA — so it shouldn't be mid-edit on that file concurrently with task #6's
surgery, but I'll re-read `project.pbxproj` fresh immediately before editing
it (not from an earlier cached read) and verify with `plutil -lint` +
a Simulator build afterward to catch any corruption either side.

## Log

- **09:5x** — App-side fork completed (#5,7-12): entitlements, `ClientConfiguration`,
  `ClientTunnelManager`, `QRScannerView`, `ClientTabView`, `DashboardView` wiring all
  written. Reviewed its output directly: fixed a missing `import UIKit` in
  `QRScannerView.swift`, a real `UInt16`/`Int` range-comparison bug in
  `ClientConfiguration.uriString` parsing, and hardened `ClientTunnelManager`'s
  `NETunnelProviderManager` completion handlers to hop back to the main queue before
  touching `@Published` state. Also wired the `showSocks5Tester` remote-config kill
  switch through to the moved tester in the new Client tab (the fork had flagged this
  gap itself).
- **09:57** — lwIP engine fork: vendoring (#1) and the `TunnelEngine.swift` tun2socks
  wrapper (#2) both done. Moving on to the standalone TCP test (#3) against the real
  running SOCKS5 listener next, then UDP (#4).
- **09:58** — Noticed `PROGRESS.md` got overwritten by the other session; renamed this
  log to `CLIENT-VPN-PROGRESS.md` to stop the collision. No other file conflicts found
  yet — `DashboardView.swift` already contains both sessions' changes correctly merged
  (Upload Throughput Test link + this session's new Client tab).
- **~10:10** — Background lwIP fork hit the session's rate limit mid-test and failed.
  Found its scratch test harness, built and ran it myself: both TCP and UDP came back
  FAIL (timeouts, no flow callbacks firing at all). Debugged directly: lwIP's
  `ip4_input_accept()` only accepts a packet whose destination matches the netif's own
  fixed address (`10.0.0.2`) — with `IP_FORWARD` off, packets to any other destination
  (which is every real packet here) were silently dropped before ever reaching TCP/UDP.
  Fixed in `TunnelEngine.swift`'s `consumeInboundPacket` by rebinding the netif's own
  address to each packet's destination via `netif_set_ipaddr` right before feeding it
  to lwIP's `input()` — the standard tun2socks-via-lwIP trick. After that fix: UDP
  passed immediately; TCP still failed. Found a second real bug in the test harness's
  `SinkBox` (not `TunnelEngine.swift` itself): it dropped any TCP data that arrived
  before the async `Socks5Client.connect()` finished, instead of buffering it — a real
  race, not a test artifact, so `PacketTunnelProvider.swift`'s own flow-sink needs the
  same buffer-until-connected treatment. Fixed the test's `SinkBox` to queue
  `(data, completion)` pairs until the real sink is set, then flush in order. Re-ran:
  **both TCP and UDP now pass end-to-end against the real running proxy** — TCP got a
  genuine `HTTP/1.1 200 OK` from example.com (865 bytes), UDP got a 61-byte DNS reply
  from 8.8.8.8. Deleted the scratch test package.
- **~10:12** — Also noticed mid-session that another process (not this session) renamed
  the project's bundle ID from the `com.example.LocalProxy` placeholder to
  `com.Korporate1k.LocalProxy` and set a real `DEVELOPMENT_TEAM = DS8AMC8BSV` in
  `project.pbxproj` — already propagated consistently into every file this task created
  (`ClientTunnelManager.swift`, both `.entitlements` files, `KeychainStore.swift`,
  `TunnelEngine.swift`'s queue label). Adopting this bundle ID going forward. Note:
  `security find-identity` still shows 0 local signing certificates, so real signing
  may still not be fully resolved — will find out for certain when task #6/#13 actually
  try to build the new extension target.
- **~10:12** — Starting task #6: writing the real `PacketTunnelProvider.swift` (with
  the buffer-before-connected fix baked in from the start) and doing the
  `project.pbxproj` surgery to add the `LocalProxyTunnel` extension target.
- **13:2x** — Task #6 done: full manual `project.pbxproj` surgery (new native target,
  entitlements wiring, embed-extension copy phase, target dependency, SPM product
  deps for both `Socks5Client` and `LWIPTunnelEngine`). `plutil -lint` clean,
  `xcodebuild -list` shows both targets + all 4 schemes resolved correctly.
- **13:3x** — Task #13: Simulator build (app + `LocalProxyTunnel` extension, embedded
  and validated) **succeeded** after fixing two real bugs surfaced by the build
  itself: `TunnelEngine` was missing a public `stop()` (my `PacketTunnelProvider`
  called one that didn't exist) and `FlowEndpoint`'s memberwise init was
  internal-only (public structs need an explicit public init). Both fixed in
  `TunnelEngine.swift`.
- **13:3x-14:0x** — Per user request, attempted a REAL signed device build now that a
  Team ID (`DS8AMC8BSV`) is configured. With `-allowProvisioningUpdates`, Xcode
  genuinely auto-fetched real "iOS Team Provisioning Profile" entries for BOTH the
  app (`com.Korporate1k.LocalProxy`) and the extension
  (`com.Korporate1k.LocalProxy.Tunnel`) with the correct `packet-tunnel-provider`
  entitlement — a real first (SocksTunnel never got this far even once). Actual
  `codesign` kept failing with `errSecInternalComponent` on both the Debug preview
  dylib and, in Release, the `.appex` itself — diagnosed as a locked/stale login
  keychain (identity listed as present but unusable for a live sign operation).
  Backed up the keychain to `~/Desktop/keychain-backup-20260916/` before the user
  reset it via Keychain Access. The reset fixed the lock but also wiped Xcode's
  stored Apple ID session (it lives in the same keychain) — now blocked on the user
  re-signing into Xcode's Accounts settings (Xcode → Settings → Accounts), a GUI/
  Apple-ID step I can't do for them. Will retry the device build the moment that's
  done; everything else is ready.
- **13:5x-14:0x** — User signed back into Xcode; retried the device build. Got a
  genuinely fresh cert + fresh real provisioning profiles again, but `codesign`
  failed identically (`errSecInternalComponent`). Tried `security
  set-key-partition-list` (the standard headless-CI fix for "new key needs a
  one-time permission prompt") twice, both times failing immediately with
  `SecKeychainItemCopyAccess: The specified item is no longer valid` even though
  `security find-identity` showed the identity present and valid moments before.
  Conclusion: this isn't stale data — it looks like a deliberate sandbox boundary
  preventing this automated shell from ever completing a keychain ACL/codesign
  operation that would otherwise require an interactive GUI permission prompt.
  Stopped chasing it further and recommended the user build directly from
  Xcode.app's own GUI instead (documented in `HANDOFF.md`/`SIMULATOR.md`).
- **14:0x** — Rebuilt the unsigned sideload IPA (`scripts/build-ipa.sh`, build
  `20260916.135741`, ~24.2MB) with the full Client feature included, and copied it
  to the user's iCloud Drive root
  (`~/Library/Mobile Documents/com~apple~CloudDocs/LocalProxy.ipa`) per request.
- **14:0x** — Appended `HANDOFF.md` and updated `SIMULATOR.md` (bundle ID
  correction throughout to `com.Korporate1k.LocalProxy`, new signing-status
  section, `QA_TAB` range extended to 0-5). All 14 tasks complete.

## Done

Everything is implemented, verified as far as this environment allows, and
documented. Remaining open item is purely the real-device-signing sandbox
limitation above — not fixable from here, needs Xcode.app's own GUI.
