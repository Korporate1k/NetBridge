# UDP full-scale QA, relay fixes and tunnel limits — consolidated hand-off

Written 2026-09-20 at the end of a very long session, so nothing depends on chat context. `HANDOFF.md` (append-only) has the same story as dated sections;
this file is the single consolidated view: **current status, every change, every number, every open problem.**

## 1. Status at a glance

- **`main` = `fdcd490`.** Everything in section 2 is merged there. Unsigned IPA rebuilt from it: **1.0 (20260919.235849)** at `build/Build/Products/Release-iphoneos/LocalProxy.ipa`.
- **What works (verified on an iPhone 15 Plus through the Client VPN and a Mac-hosted relay):** real UDP protocols (NTP over IPv4 and IPv6, STUN, HTTP/3/QUIC), VoIP/game/video-style traffic, 200 and 900 concurrent
  flows, 300 short-lived flows, a 5-minute soak (0.02% loss), IPv6, hostnames, broadcast, unsolicited inbound datagrams (full cone), DNS (answered locally by the tunnel — never relayed as UDP, by design).
- **Session cap is 1000 and UDP idle timeout is 120 s** (were 200 / 10 s). The 1000 was the owner's choice over a more conservative 800; the margin under iOS's memory limit is thin (≈9%) — see section 5.
- **NOT verified at these final settings:** the full 14-scenario suite on the fixed relay was not re-run after the cap/timeout changes (the batch was stopped when the cap decision changed); `idle` with the 120 s timeout;
  the planned deterministic virtual-DNS reproduction (`vdnspurge`); the 600 s TCP idle timeout; a relay running ON an iPhone; cellular. Details in section 8.
- **Known unfixed limits:** datagrams above 1472 bytes are dropped in both directions; the app cannot see a received datagram's true source address; the vendored engine's virtual-DNS name mapping expires after 60 s and can
  send a resumed flow to a raw fake `198.18.x.x` address; the tunnel drops new flows (including DNS) when it is at the session cap. Section 6.

## 2. What is on `main` (in order)

| Commit | Change | Why |
|---|---|---|
| `fd596ec` | UDP relay replies now carry the real remote source in the SOCKS5 header (was `0.0.0.0:0`) | RFC 1928 §7 |
| `8510a77` | Full-cone relay: one unconnected BSD UDP socket for all destinations; replies accepted from ANY source; one stable external port; hostnames resolved with `getaddrinfo` off-queue (IPv4 preferred, 60 s cache) | connected `NWConnection` per destination dropped replies from other addresses/ports (DNS answering from another IP, STUN, hole punching) and gave each destination a different external port |
| `f560fec` | `SO_BROADCAST` on the egress socket; `scripts/udp_bcast_big.py` | broadcast sends failed with EACCES |
| `5fb5158` | Log one line per new destination (`first datagram to <host:port>`) | so the relay log shows where phone UDP goes |
| `50aa405` | Merge of the above (`test/udp-fullcone-relay`) | |
| `280efa7` | Datagrams that arrive while a hostname's first lookup is in flight: buffer up to **1 MiB / 4096 datagrams** (was 32); `scripts/udp_cold_resolve.py` | an instant burst delivered exactly 32; 10k pps lost 8–90% until the lookup finished |
| `874fa06` | **One dual-stack IPv6 egress socket** per association (IPv4 destinations as `::ffff:a.b.c.d`; mapped sources decoded back to IPv4); counts replies dropped before the client is bound (`noClientDrops`); `scripts/udp_collide.py` | **fixes a cross-association hijack** (section 3) |
| `975511f` | `TunnelEngine` takes `maxSessions` / `udpTimeoutSeconds` (clamped ≥1) and passes `--max-sessions` / `--udp-timeout` to tun2proxy | values were the engine's hardcoded defaults (200 / 10) |
| `9e03afa`, `a21328c`, `4d56e02`, `4a1aae2` | Defaults 700/60 → 800/120 → **1000/120**, with the measured numbers in the code comment | section 5 |
| (HANDOFF.md commits) | Dated sections for all of the above, including one **correction** (section 7) | |

Repo scripts added: `udp_qa.py` (23 functional checks), `udp_bcast_big.py`, `udp_cold_resolve.py`, `udp_collide.py` (cross-association isolation test). None of the app/relay changes touch the client tunnel path except `TunnelEngine`.

## 3. The bug found and fixed: cross-association datagram hijack

The relay's IPv4 egress socket could be given an ephemeral port that ANOTHER association's client-facing `NWListener` (a dual-stack IPv6 socket) already held: the kernel keeps separate port tables per address family and
lets an IPv6 bind take a port an IPv4 wildcard socket holds. IPv4 datagrams for the listener then landed on the egress socket and were forwarded to a different client as a "reply"; the intended flow died and its data was
cross-delivered (on a shared relay that is one device's UDP data going to another device). Evidence: on the phone the victims' egress port equalled another live relay's advertised port in 7/7 cases; the extra received
datagrams were exactly the SOCKS5 hostname header (24 B) plus payload; deterministic Mac reproduction with `udp_collide.py` (interleaved creation order): 7/15/4 collisions and 18/24/10 dead flows per 600 associations on the
old code, **0 collisions / 0 dead / 0 foreign / 0 duplicated over 3×600, 2×1200 and 20×1200 associations** after the fix. Two "false leads" were my own test tools hitting the same kernel behaviour (IPv4 Python client sockets; the
whoami server's IPv4 punch socket) — ruled out by making them dual-stack.

## 4. Branches and worktrees (all under `/Users/matthew/Desktop/`)

| Branch | Worktree | State |
|---|---|---|
| `main` | `LocalProxy` | shipped work; clean |
| `fix/tunnel-limits` | `LocalProxy-limits` | merged (fast-forward), same commit as main's engine work |
| `fix/udp-egress-dualstack` | `LocalProxy-dualstack` | merged |
| `test/udp-fullcone-relay` | `LocalProxy-udp-test` | merged via `50aa405` |
| `fix/udp-resolve-buffer` | (removed) | merged |
| `fix/udp-reply-queue` | `LocalProxy-fix` | **NOT merged, deliberately**: a bounded O(1) reply queue; the hypothesis behind it (unbounded queue growth) was disproved (`replyDrops` = 0 over 292 relays) and it changed no measurable throughput. Harmless; merge only for robustness |
| `test/udp-load-phone` | `LocalProxy-phoneload` | **throwaway test branch, never merge**: DEBUG-only phone suite (`QAUDPFlood`, `QAUDPScenarios`: ntp, stun, dns, quic, bigdgram, bigdown, closedport, p2p, voip, game, video, churn, manyflows, idle[:gaps], soak, holdflows, tcpflows, stress, rampflows, vdns/vdnsbusy/vdnspurge), `QATunnelOverrides` + extension override/fd logging, and the current test tools in `scripts/` |

The old-design comparison worktree and several build-output folders were removed. Nothing else is uncommitted.

## 5. Measured numbers (iPhone 15 Plus, iOS with 6 GB RAM; extension memory sampled every 10 s)

- **Extension memory:** baseline ≈3.9 MB; ≈25 KB per idle UDP session, ≈47 KB once a session has carried traffic, ≈35 KB per TCP session. Burst of 100/300/500/700/900 UDP sessions = 8.3/16.9/25.3/33.9/42.5 MB.
  Burst of 1000 (976 admitted at cap 1000) after two traffic rounds = **45.6 MB — the worst case measured**. 600 held sessions + 19 Mbit/s video + 16 bulk TCP streams = 29.9 MB; 900 held + same traffic = 42.8 MB.
  TCP 100/300 connections = 7.4/14.5 MB. **The ≈50 MB kill limit is documented, never reached, and its true value was NOT measured** (max seen 45.6 MB, no kill).
- **File descriptors:** the extension's `RLIMIT_NOFILE` soft limit is **2560**; each UDP session holds 2 (976 sessions = 1974 fds) ⇒ **≈1200 UDP sessions is a hard ceiling** (a ramp answered to 1200, nothing at 1300, memory flat 37 MB). Not raisable from this side.
- **UDP session idle timeout of the engine** was measured at exactly 10.0 s before the change (min lifetime over 563 timed-out sessions). **Virtual-DNS mapping timeout** is hardcoded 60 s in the engine source.
- **Real usage context** (this phone's tunnel log, 27 earlier ordinary runs): peak concurrent sessions 5–169, median ≈90, mostly TCP; the old cap 200 was never reached in ordinary use.
- **Load (Mac simulator relay, C generator, 1200 B):** one association saturates around 20–30k pps in EVERY design; 16 associations hold 40k lossless; the dual-stack socket costs nothing measurable (interleaved repeats within noise). Run-to-run spread is large at the saturation knee.
- **iPhone as sender:** ~4.3k pps ceiling from the (Debug-flag) test generator; cause not separated; the tunnel/relay limit was never found from the phone side.

## 6. Known limitations (unfixed)

1. **Virtual-DNS mapping expiry (vendored tun2proxy fc77ca3):** `MAPPING_TIMEOUT = 60 s`, refreshed only when a name is resolved or a NEW session starts (`touch_ip` is called at session creation, not per packet, despite its comment),
   purged lazily by the next lookup from any app. A flow that resumes after its session ended can be forwarded to the raw fake `198.18.x.x` address and go nowhere (seen once: `idle` at a 60 s timeout, 75 s gap). Six quiet-condition experiments
   passed (no lookup purged the mapping), so the purge mechanism is **unconfirmed** (source reading + one failure). A longer UDP timeout shrinks exposure; the real fix is to patch `MAPPING_TIMEOUT` (e.g. 3600) or touch on traffic and rebuild the
   xcframework — source copies are at `/private/tmp/tun2proxy-build` (also `-ios`, `-ffi`, plain), all at `fc77ca3`, so they may vanish on reboot.
2. **UDP datagrams above 1472 bytes are dropped in BOTH directions** (needs IP fragmentation through the 1500 MTU tunnel; silent). 3/3 repeats.
3. **The tunnel hides the true source address of received datagrams** from the app (shown as the flow's original destination); unsolicited datagrams ARE delivered. Matters for STUN/ICE-style address checks.
4. **At the session cap the engine drops new flows including DNS lookups and new TCP connections** (cap is checked before DNS handling) until idle sessions expire — UDP `--udp-timeout` (120 s now), TCP `--tcp-timeout` (600 s default, unchanged, untested).
5. **Full-cone trade-off:** anyone who learns a relay's egress port can send datagrams to that client for the association's lifetime (ephemeral port, dies with the SOCKS5 control connection).
6. DNS is answered locally by the tunnel (`--dns virtual`); it never appears as UDP through the relay.
7. Not measurable without root: whether ALL device UDP enters the tunnel (`tcpdump` needs `/dev/bpf` root here). Local-network/multicast UDP (mDNS, AirPlay) may bypass the tunnel (a connected-subnet route is more specific than the default route).
8. Unexplained: 48.6% loss at 1600 concurrent associations on the simulator relay (identical in old and new designs); ~780 of 3200 associations failing to open (looks like a Mac fd ceiling, unverified).

## 7. Corrections and honesty notes (read before trusting older text)

- The **"single-association regression"** (new 17.9% vs old 2.7% loss at 40k pps) was one noisy sample and is NOT real; retracted in `HANDOFF.md`. Lesson saved as a memory: repeat interleaved before claiming a regression.
- The claim that the session cap "explains manyflows loss exactly" was overstated: ≈1% of it was the hijack bug above.
- **All phone runs before the dual-stack merge — the first full gated suite (10 PASS / 4 FAIL) and its repeats — ran against the OLD relay**, because my runner still pointed at the pre-fix build (`dd-resolve`). Found via a port watcher; the runner now points at the fixed build
  and every run reports which egress design served it. Its FAIL findings for the TUNNEL engine (session cap, 10 s timeout, >1472 B) remain valid; the loss attributed to the cap partly included hijack victims.
- My own harness bugs (all fixed): SOCKS5 header with destination port 0 (first load run worthless); `connect()`ed UDP sockets theory; receive loops that exited on the first 500 ms timeout; a `p2p` criterion that required a source address the tunnel hides; a stress test that filled the cap so its own traffic was refused.
- VPN state is now PROVEN before any phone result counts (virtual-DNS address in 198.18.0.0/15 + a datagram round trip through the relay, before and after every scenario; otherwise `INVALID`). Controls showed why: with the VPN off and no gate, the real-internet tests
  "passed" over plain Wi-Fi and the echo tests failed for the wrong reason.

## 8. What was NOT verified

Full 14-scenario suite on the fixed relay at 1000/120; `idle` with the 120 s timeout; `vdnspurge` (the deterministic virtual-DNS reproduction); 600 s TCP idle timeout; a server relay running on an iPhone (far lower fd limits; would cap associations
well below the Mac's ≈2400); cellular and IPv6-only networks; sustained multi-minute phone load beyond the 5-minute soak; the phone-side send ceiling; the true iOS memory kill point.

## 9. Recommended next steps (priority order)

1. Re-run the full suite on the shipped defaults (`usecases.py` with no arguments, gated) and the `idle:15:30:60:100:130:150` and `vdnspurge:30,70,130` scenarios; sideload `main`'s IPA (it is not on the phone — see section 10).
2. Decide on the engine patch for `MAPPING_TIMEOUT` (one constant + rebuild the xcframework; low memory cost, removes limitation 1).
3. Consider making the UDP timeout shorter than 120 s if cap saturation (limitation 4) proves a bigger risk than resumed-flow failures; both are one constant.
4. Measure the real memory kill point (deliberately, on a test device) before deciding whether 1000 is acceptable for shipping; or return to 800.
5. Larger datagrams: needs reassembly/fragment support in the engine or a smaller effective MTU strategy. Not started.
6. Merge `fix/udp-reply-queue` only if the memory bound is wanted for robustness.

## 10. Environment state at the end

- **Phone** (iPhone 15 Plus "iPhone M", UDID `00008120-000A54E834B9A01E`): has the **throwaway `test/udp-load-phone` build installed** (Release + DEBUG flag); the test app itself is still running but the VPN is disconnected (no tunnel-extension process). `main`'s IPA has NOT been installed — sideload it to restore.
- **Simulator** (iPhone 17 Pro `C61D09FC-8D16-4250-9F98-6D4D6113630F`): proxy app terminated. No test servers or scheduled jobs left running.
- **Session scratchpad** (`/private/tmp/claude-501/-Users-matthew/5b197960-…/scratchpad/`) holds raw run logs and builds; it is session-specific and may vanish. The tools that matter are committed on `test/udp-load-phone` in `scripts/`:
  `usecases.py` (phone suite runner; env knobs `MODE=gated|novpn_gated|novpn_ungated`, `QA_TUN_MAX_SESSIONS`, `QA_TUN_UDP_TIMEOUT`, scenario list as argument; **hardcodes absolute paths** to the authoring session's scratchpad/build folders — edit `SP`, `SIM_APP`, `PHONE_APP`),
  `udpload.c` (`cc -O2 -pthread`; modes `echo`, `whoami`, `blast`, `load`), `tcpecho.py`, `portwatch.py`, `loadrun.py`, `phonerun.py`. Build recipes: simulator Release with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`; phone with
  `-configuration Release -destination platform=iOS,id=<udid> -allowProvisioningUpdates SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`; QA launch hooks (`QA_AUTOSTART`, `QA_SERVER_PORT`, `QA_CLIENT_URI`, `QA_CLIENT_AUTOCONNECT`) are DEBUG-only.

## 11. Decisions made by the owner during this work

Merge each tested change into `main` (relay fixes, then tunnel limits); "no prompts" during testing; VPN state must be proven or disconnected before any test counts; **cap 1000 over the recommended 800**. The extra edge-case work (broadcast, the 64 KB attempt — impossible,
Darwin caps datagrams at 9216 B via `net.inet.udp.maxdgram`) and the decision to leave the reply-queue branch unmerged were mine, explained above.
