import NetworkExtension
import Network
import Security
import os
import Darwin
import LWIPTunnelEngine

/// The `NetBridgeTunnel` Network Extension: a real system-wide VPN that
/// routes this device's traffic out through a remote SOCKS5 server (configured
/// in the app's Client tab — see `ClientTunnelManager`).
///
/// Bridges `NEPacketTunnelFlow` (raw IPv4/IPv6 packets) to the tun2proxy
/// engine (`LWIPTunnelEngine.TunnelEngine`). The engine does all of the
/// TCP/UDP termination *and* the SOCKS5 dialing itself (CONNECT for TCP,
/// UDP ASSOCIATE for UDP, virtual DNS), so this provider only has to move raw
/// packets in and out and hand it the server address.
///
/// Username/password from the saved configuration are passed straight to the
/// engine, which puts them in the proxy URL so tun2proxy's SOCKS5 client
/// performs the real RFC 1929 sub-negotiation. The password
/// is read from the shared Keychain access group `ClientTunnelManager` saves
/// it into — see `loadClientPassword()` (inlined via `Security` rather than
/// sharing the app target's `KeychainStore`, which isn't compiled into this
/// extension).
///
/// Health monitoring (SOCKS5 probe every 20 s and after path changes, network-change cancel, engine-exit cancel)
/// runs on both iOS and macOS. Only the stats hand-off to the app (`TunnelCounters` / `handleAppMessage`) is
/// macOS- and tvOS-only, because `TunnelStats` is compiled into the Mac and tvOS targets only.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: TunnelEngine?
    #if os(macOS) || os(tvOS)
    /// Live traffic counters for the Mac app's dashboard (see `handleAppMessage`).
    private let counters = TunnelCounters()
    #endif

    /// The configured server, and the address it resolved to when this tunnel came up. That address is pinned into
    /// `excludedRoutes` and cannot be changed without restarting the tunnel — see `runProbe`.
    /// Written once in `startTunnel` before monitoring starts, then only read.
    private var serverHost: String?
    private var serverPort: UInt16 = 0
    private var pinnedServer: ServerAddress?
    /// Credentials for the probe (the same ones the engine uses). Written once in `startTunnel`.
    private var probeUsername = ""
    private var probePassword = ""

    private var pathMonitor: NWPathMonitor?
    /// Owned by `pathQueue`.
    private var pathCheckWork: DispatchWorkItem?
    private var lastPathFingerprint: String?
    private let pathQueue = DispatchQueue(label: "com.Korporate1k.LocalProxy.Tunnel.path")
    /// Probes block for up to 3 s, so they get their own serial queue: `pathQueue` is where `NWPathMonitor`
    /// delivers updates, and blocking that would back up path changes behind a probe.
    private let probeQueue = DispatchQueue(label: "com.Korporate1k.LocalProxy.Tunnel.probe")
    private var reachabilityTimer: DispatchSourceTimer?
    /// All of these are read and written only on `probeQueue`.
    private var serverWasReachable = false
    private var consecutiveUnreachable = 0
    /// A physical path change was seen since the last probe the server answered (or since start).
    private var pathChangedSinceSuccess = false
    /// Mirror of what was last logged, so a repeated verdict is not logged every 20 s.
    private var lastVerdict: String?
    /// `stopping` is set by `stopTunnel` and by our own cancels, from any queue, so it is guarded by `pathStateLock`.
    private let pathStateLock = NSLock()
    private var stopping = false
    /// Identifies this tunnel session in the errors we hand to `cancelTunnelWithError` and to `startTunnel`'s
    /// completion, so the app can tell one of our failures from a stale one. `fetchLastDisconnectError` is
    /// documented only as "the most recent error" — it makes no promise of being cleared or scoped to the session
    /// that just ended.
    private let sessionID = UUID().uuidString

    private static let probeInterval: DispatchTimeInterval = .seconds(20)
    private static let probeTimeout: TimeInterval = 3
    /// Minimum spacing between two network-change cancels (same value as the Windows client's
    /// `NETWORK_RESTART_BACKOFF`). Cleared as soon as the server answers again.
    private static let networkCancelSpacing: TimeInterval = 30
    private static let lastNetworkCancelKey = "tunnel.lastNetworkCancelEpoch"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration,
              let host = config["host"] as? String,
              let portNumber = config["port"] as? NSNumber
        else {
            completionHandler(sessionError(code: 1, "Missing server configuration"))
            return
        }
        let port = portNumber.uint16Value
        let username = config["username"] as? String ?? ""
        let password = Self.loadClientPassword()
        let authConfigured = !username.isEmpty && !password.isEmpty
        tunnelLog.log("startTunnel host=\(host, privacy: .public) port=\(port, privacy: .public) authConfigured=\(authConfigured, privacy: .public)")

        // The engine's own TCP/UDP connection to the SOCKS5 server must NOT be
        // routed back through the tunnel, or it loops: the tunnel captures the
        // engine's connect() to the server, feeds it back into the engine,
        // which dials the server again, and so on — the device can never get
        // out. Exclude the server's address (a /32 or /128) so that one
        // connection goes over the physical interface directly. (Potatso
        // avoided this by dialing a *local* 127.0.0.1 proxy; we dial a remote
        // server, so the exclusion is required.)
        // Refuse to start rather than come up without the exclusion. A tunnel whose excluded route is missing
        // sends the engine's own connection to the proxy back through itself — the loop described above — and
        // still reports Connected while carrying nothing. Failing here surfaces it so the app can retry.
        // Resolved here, with the tunnel down, so DNS is the real one (see `runProbe`).
        guard let server = ServerAddress.resolve(host) else {
            tunnelLog.error("could not resolve \(host, privacy: .public); refusing to start without an excluded route")
            completionHandler(sessionError(code: 4, "Could not resolve the SOCKS5 server address \"\(host)\"."))
            return
        }
        // IPv6 proxy servers are not supported: the engine's --proxy parser cannot take an IPv6 host, and a failed
        // parse would exit() the whole extension (see `TunnelEngine.canDial`). IPv4 is preferred by `resolve`, so
        // only an IPv6 literal or an IPv6-only name lands here; fail cleanly with a reason the app can show.
        guard TunnelEngine.canDial(host: server.ip) else {
            tunnelLog.error("server \(host, privacy: .public) resolved to IPv6 \(server.display, privacy: .public); IPv6 servers are not supported")
            completionHandler(sessionError(code: 5, "IPv6 SOCKS5 servers are not supported (\"\(host)\" resolved to \(server.display)). Use the server's IPv4 address or a name with an IPv4 address."))
            return
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: server.ip)
        let ipv4 = NEIPv4Settings(addresses: [TunnelEngine.tunnelLocalAddress], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // Capture IPv6 too — otherwise it goes straight out the physical
        // interface, bypassing the proxy. tun2proxy relays IPv6 like IPv4
        // (the old BadVPN core was IPv4-only, which is why this used to be
        // left uncaptured).
        let ipv6 = NEIPv6Settings(addresses: [TunnelEngine.tunnelLocalAddressV6], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        if server.isIPv6 {
            // Unreachable while IPv6 servers are refused by the `canDial` guard above; kept so the route is right
            // if the engine ever gains IPv6 --proxy support. The route has no zone field; the probe's sockaddr
            // carries a link-local scope itself.
            ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: server.ip, networkPrefixLength: 128)]
        } else {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: server.ip, subnetMask: "255.255.255.255")]
        }
        Self.debugLog("excluded route for server \(server.display)")
        serverHost = host
        serverPort = port
        pinnedServer = server
        probeUsername = username
        probePassword = password
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                tunnelLog.error("setTunnelNetworkSettings failed host=\(host, privacy: .public) error=\(String(describing: error), privacy: .public)")
                completionHandler(self.sessionError(code: 6, "Could not apply the tunnel's network settings: \(error.localizedDescription)",
                                                    underlying: error))
                return
            }
            tunnelLog.log("tunnel network settings applied ipv4=\(TunnelEngine.tunnelLocalAddress, privacy: .public) dns=8.8.8.8,8.8.4.4")
            // Dial the pinned literal, not the hostname: a name with an AAAA record could send the engine over an
            // address that has no excluded route (it loops) and would reach the phone under a different device key.
            self.startEngine(server: server, proxyPort: port, username: username, password: password,
                             verbosity: config["verbosity"] as? String ?? TunnelEngine.defaultVerbosity)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        tunnelLog.log("stopTunnel reason=\(String(describing: reason), privacy: .public)")
        memoryTimer?.cancel()
        #if os(macOS) || os(tvOS)
        statsTimer?.cancel()
        #endif
        stopMonitoring()
        engine?.stop()
        engine = nil
        completionHandler()
    }

    /// An error carrying this session's ID, for `startTunnel`'s completion and for `cancelTunnelWithError`.
    private func sessionError(code: Int, _ message: String, underlying: Error? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message, "sessionID": sessionID]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: "NetBridgeTunnel", code: code, userInfo: info)
    }

    /// Ends the session with one of our own errors. Marks the provider as stopping first, so no probe or path
    /// check runs (or cancels a second time) against a session that is going away.
    private func failSession(code: Int, _ message: String) {
        pathStateLock.lock()
        let alreadyStopping = stopping
        stopping = true
        pathStateLock.unlock()
        guard !alreadyStopping else { return }
        tunnelLog.error("cancelling tunnel: \(message, privacy: .public)")
        Self.debugLog("cancelling tunnel (code \(code)): \(message)")
        cancelTunnelWithError(sessionError(code: code, message))
    }

    #if os(macOS) || os(tvOS)
    /// The Mac app polls this once a second while connected; any message body
    /// returns the current `TunnelStats` as JSON.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(try? JSONEncoder().encode(counters.snapshot(footprintMB: Self.footprintMB())))
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private var statsTimer: DispatchSourceTimer?

    /// Logs the same counters the app's dashboard shows, every 10 s, so a QA pass
    /// can reconcile them against the kernel's utun counters (`netstat -I`).
    private func startStatsLogging() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let s = self.counters.snapshot(footprintMB: Self.footprintMB())
            Self.debugLog("stats up=\(s.up) down=\(s.down) pktUp=\(s.pktUp) pktDown=\(s.pktDown) mem=\(String(format: "%.1f", s.footprintMB))MB")
        }
        statsTimer = timer
        timer.resume()
    }
    #endif

    /// Mirrors `ClientTunnelManager.save()`'s Keychain write (same service,
    /// account key, and shared access group) — inlined via `Security`
    /// directly rather than referencing the app target's `KeychainStore`
    /// type, since that file isn't compiled into this extension target.
    private static func loadClientPassword() -> String {
        #if os(macOS)
        // Same split as `ClientTunnelManager.keychainAccessGroup`: macOS shares
        // via the data-protection keychain with a team-prefixed group.
        let accessGroup = "DS8AMC8BSV.com.Korporate1k.LocalProxy.shared"
        #else
        let accessGroup = "com.Korporate1k.LocalProxy.shared"
        #endif
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.Korporate1k.LocalProxy.persistence",
            kSecAttrAccount as String: "client_password",
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            // Not "no password": the read itself failed. The engine will go without credentials, and a server that
            // requires them will show up as "Sign-in refused" in the probe.
            tunnelLog.error("keychain read of client password failed OSStatus=\(status, privacy: .public)")
            debugLog("keychain read of client password failed OSStatus=\(status)")
        }
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private var inboundCount = 0
    private var outboundCount = 0

    private func startEngine(server: ServerAddress, proxyPort: UInt16, username: String, password: String, verbosity: String) {
        let engine = TunnelEngine(proxyHost: server.ip, proxyPort: proxyPort,
                                  username: username, password: password, verbosity: verbosity)
        self.engine = engine
        engine.logHandler = { Self.debugLog($0) }
        Self.debugLog("startEngine proxy=\(server.ip):\(proxyPort) auth=\(!username.isEmpty) verbosity=\(verbosity)")

        engine.onPacketsToWrite = { [weak self] packets, families in
            guard let self else { return }
            for data in packets {
                self.outboundCount += 1
                if self.outboundCount <= 5 {
                    Self.debugLog("outbound #\(self.outboundCount) bytes=\(data.count) first=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
                }
                #if os(macOS) || os(tvOS)
                self.counters.addDown(data.count)
                #endif
            }
            self.packetFlow.writePackets(packets, withProtocols: families.map { NSNumber(value: $0) })
        }

        // The engine ended (or lost its packet device) without stopTunnel() asking it to. tun2proxy force-exits
        // this process ~2 s after the engine returns, so report a real error to NetworkExtension while we still
        // can. On macOS the app reconnects on a disconnect that carries one of our session IDs. On iOS nothing
        // reconnects automatically, but a tunnel left "Connected" with a dead engine black-holes every packet with
        // no visible sign; ending the session makes the failure visible in Settings and in the Client tab (which
        // shows this error) instead.
        engine.onEngineExit = { [weak self] exit in
            self?.failSession(code: 2, "The tunnel stopped unexpectedly: \(exit).")
        }

        #if os(macOS) || os(tvOS)
        counters.markConnected()
        #endif
        engine.start()
        readPackets()
        startMemoryLogging()
        #if os(macOS) || os(tvOS)
        startStatsLogging()
        #endif
        startMonitoring()
    }

    // MARK: - Health monitoring (iOS and macOS)

    /// The excluded route pinned in `startTunnel` is only right for the address the server had at that moment.
    /// Across sessions the Mac has reached its relay at 172.20.10.1 (phone hotspot), 10.0.0.129 (home LAN) and
    /// once at a 169.254 link-local address, so it does move. NetworkExtension gives no callback for "the address
    /// behind your excluded route changed", and the failure is silent — the tunnel still reports Connected while
    /// nothing gets through — so watch for path changes and probe.
    ///
    /// A path change is not the only way to lose the proxy, and not even the common one: the relay app on the phone
    /// can be suspended, or the phone can walk away, with no network change here at all. Nothing in the stack
    /// notices — NE stays Connected and the engine keeps running — so also poll every 20 s.
    private func startMonitoring() {
        guard pathMonitor == nil else { return }
        // Physical interfaces only: our own utun is type `.other`, and its appearance must not count as a change.
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathUpdated(path)
        }
        monitor.start(queue: pathQueue)

        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + 5, repeating: Self.probeInterval)
        timer.setEventHandler { [weak self] in self?.runProbe(trigger: "timer") }
        reachabilityTimer = timer
        timer.resume()
    }

    private func stopMonitoring() {
        // Set first: a path update already in flight on pathQueue can install a new work item after the cancel
        // below, and that item would otherwise run a blocking probe against a torn-down session.
        pathStateLock.lock()
        stopping = true
        pathStateLock.unlock()
        reachabilityTimer?.cancel()
        reachabilityTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        // pathCheckWork belongs to pathQueue; mutating it from this queue would be an ARC race.
        pathQueue.async { [self] in
            pathCheckWork?.cancel()
            pathCheckWork = nil
        }
    }

    /// Runs on `pathQueue`. `NWPathMonitor` fires once immediately on start and then on every change, often several
    /// times for one Wi-Fi switch, and sometimes for things that are not a change at all. Only a different set of
    /// physical interfaces / gateways / status counts; then probe after the updates settle.
    private func pathUpdated(_ path: Network.NWPath) {
        let interfaces = path.availableInterfaces.map { "\($0.name)#\($0.index)" }.sorted().joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        let fingerprint = "\(path.status)|\(interfaces)|\(gateways)"
        let previous = lastPathFingerprint
        lastPathFingerprint = fingerprint
        guard let previous, previous != fingerprint else {
            if previous == nil { Self.debugLog("path baseline \(fingerprint)") }
            return
        }
        Self.debugLog("path changed \(previous) -> \(fingerprint)")
        // Enqueued now, so it lands on probeQueue before the settled probe below.
        probeQueue.async { [weak self] in self?.pathChangedSinceSuccess = true }
        pathCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.probeQueue.async { self.runProbe(trigger: "path change") }
        }
        pathCheckWork = work
        pathQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Runs on `probeQueue` (serial, so probes never overlap), and owns `serverWasReachable`,
    /// `consecutiveUnreachable`, `pathChangedSinceSuccess` and `lastVerdict`.
    ///
    /// The probe is a real SOCKS5 greeting (+ RFC 1929 sign-in when a username is set) followed by a UDP ASSOCIATE,
    /// all under one 3 s deadline. A TCP connect is not enough: a suspended iOS relay keeps accepting TCP but never
    /// answers SOCKS5, so a connect-only probe calls a dead server healthy.
    ///
    /// Deliberately does NOT re-resolve the host. While this tunnel is up, a DNS query from this process goes
    /// *through* the tunnel (that is the whole reason `excludedRoutes` exists), and the engine runs with
    /// `--dns virtual`, which answers any query for port 53 out of a fake 198.18.0.0/15 pool regardless of the
    /// destination. Re-resolving here would therefore return a fake address, compare unequal to the pinned one,
    /// and cancel a perfectly healthy tunnel — and it would poison the system resolver's cache for the server's
    /// name on the way out.
    ///
    /// So brokenness is detected without DNS: probe the address actually pinned into `excludedRoutes`, which by
    /// construction routes over the physical interface. When it stops answering after a network change, cancel and
    /// let the app reconnect — `startTunnel` then re-resolves with the tunnel *down*, where DNS is trustworthy, and
    /// pins whatever the correct address is now. That covers both a hostname whose address moved and a literal IP
    /// that belongs to a network we have left.
    private func runProbe(trigger: String) {
        guard !isStopping, let server = pinnedServer, serverPort != 0 else { return }
        let host = serverHost ?? server.display
        let result = Socks5Probe.probe(server, port: serverPort, username: probeUsername, password: probePassword,
                                       timeout: Self.probeTimeout)
        guard !isStopping else { return }

        switch result {
        case .answering(let udp):
            logVerdict("answering udp=\(udp)", "probe (\(trigger)): server \(host) at \(server.display) answering SOCKS5, UDP \(udp ? "relayed" : "refused")")
            report(reachable: true, udp: udp, authRejected: false)
            serverWasReachable = true
            consecutiveUnreachable = 0
            pathChangedSinceSuccess = false
            Self.clearNetworkCancel()

        case .authRejected(let why):
            logVerdict("auth", "probe (\(trigger)): server \(host) at \(server.display) refused sign-in: \(why)")
            report(reachable: true, udp: nil, authRejected: true)
            consecutiveUnreachable = 0

        case .notAnswering(let why):
            report(reachable: false, udp: nil, authRejected: false)
            consecutiveUnreachable += 1
            lastVerdict = "down"
            Self.debugLog("probe (\(trigger)): server \(host) at \(server.display) NOT ANSWERING (\(why); \(consecutiveUnreachable) in a row, wasReachable=\(serverWasReachable), pathChanged=\(pathChangedSinceSuccess)) — tunnel still reports connected")
            maybeCancelForNetworkChange(server: server)
            // After a path change, confirm quickly instead of waiting a full poll interval for the second failure.
            if trigger == "path change", consecutiveUnreachable == 1 {
                probeQueue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runProbe(trigger: "path follow-up") }
            }
        }
    }

    /// Any probe (timer or path) may cancel, but only when all of these hold — the same guards as the Windows
    /// client: the server answered earlier this session (otherwise the address is simply wrong or the relay is
    /// off, and restarting churns without fixing anything), it has now failed at least twice running, the physical
    /// path changed since it last answered (a relay that is merely switched off is not our routes' fault), and the
    /// last such cancel is at least 30 s old. That spacing is persisted (a new session may run in a new process)
    /// and cleared as soon as the server answers, so a second network change later in the day recovers too.
    private func maybeCancelForNetworkChange(server: ServerAddress) {
        guard serverWasReachable, consecutiveUnreachable >= 2, pathChangedSinceSuccess else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastNetworkCancelKey)
        if last > 0, now - last < Self.networkCancelSpacing, now >= last {
            Self.debugLog("probe: network-change cancel suppressed, last one was \(Int(now - last))s ago")
            return
        }
        UserDefaults.standard.set(now, forKey: Self.lastNetworkCancelKey)
        failSession(code: 3, "Lost the path to the SOCKS5 server at \(server.display) after a network change. Reconnecting to rebuild the tunnel's routes.")
    }

    private static func clearNetworkCancel() {
        if UserDefaults.standard.object(forKey: lastNetworkCancelKey) != nil {
            UserDefaults.standard.removeObject(forKey: lastNetworkCancelKey)
        }
    }

    /// Logs only when the verdict changes. `probeQueue` only.
    private func logVerdict(_ key: String, _ message: String) {
        guard lastVerdict != key else { return }
        lastVerdict = key
        Self.debugLog(message)
    }

    private func report(reachable: Bool, udp: Bool?, authRejected: Bool) {
        #if os(macOS) || os(tvOS)
        counters.setProbe(reachable: reachable, udp: udp, authRejected: authRejected)
        #endif
    }

    private var isStopping: Bool {
        pathStateLock.lock()
        defer { pathStateLock.unlock() }
        return stopping
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, let engine = self.engine else { return }
            for (i, packet) in packets.enumerated() {
                self.inboundCount += 1
                if self.inboundCount <= 5 {
                    Self.debugLog("inbound #\(self.inboundCount) bytes=\(packet.count) first=\(packet.prefix(8).map { String(format: "%02x", $0) }.joined())")
                }
                let family = protocols.indices.contains(i) ? protocols[i].int32Value : AF_INET
                #if os(macOS) || os(tvOS)
                self.counters.addUp(packet.count)
                #endif
                engine.consumeInboundPacket(packet, family: family)
            }
            self.readPackets()
        }
    }

    private var memoryTimer: DispatchSourceTimer?

    /// Logs phys_footprint — the counter jetsam compares against the 50MB
    /// packet-tunnel limit — every 10s, so a leak shows up in the QA log long
    /// before it becomes a silent SIGKILL.
    private func startMemoryLogging() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { return }
            Self.debugLog(String(format: "mem footprint=%.1fMB", Double(info.phys_footprint) / 1_048_576))
        }
        memoryTimer = timer
        timer.resume()
    }

    /// Appends a line to a shared-app-group file so a QA pass can read the
    /// extension's (separate-process) activity from the Mac without a console
    /// session. DEBUG-only diagnostics; cheap and safe to leave in.
    ///
    /// The engine's own log output arrives here synchronously on its tokio worker threads, thousands of lines a
    /// minute during bursts, so this must stay cheap: the destinations (also mirrored into the extension's private
    /// tmp dir: `devicectl device copy from --domain-type appGroupDataContainer` doesn't return the group file, but
    /// `--domain-type appDataContainer --domain-identifier com.Korporate1k.LocalProxy.Tunnel --source /tmp` does) are
    /// resolved once, the file handles stay open, and each file rotates to `.prev` at `maxLogBytes` so it can't grow
    /// without bound.
    private static func debugLog(_ message: String) {
        let data = Data("\(Date().timeIntervalSince1970) \(message)\n".utf8)
        logLock.lock()
        defer { logLock.unlock() }
        for url in logURLs { append(data, to: url) }
    }

    private static let maxLogBytes: UInt64 = 8_000_000
    private static let logLock = NSLock()
    private static var logHandles: [URL: FileHandle] = [:]
    private static var logSizes: [URL: UInt64] = [:]
    private static let logURLs: [URL] = {
        var urls = [FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-debug.log")]
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.Korporate1k.LocalProxy") {
            urls.append(dir.appendingPathComponent("tunnel-debug.log"))
        }
        return urls
    }()

    /// Caller holds `logLock`.
    private static func append(_ data: Data, to url: URL) {
        let fm = FileManager.default
        var size = logSizes[url] ?? ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size + UInt64(data.count) > maxLogBytes {
            try? logHandles[url]?.close()
            logHandles[url] = nil
            let previous = url.appendingPathExtension("prev")
            try? fm.removeItem(at: previous)
            do {
                try fm.moveItem(at: url, to: previous)
                size = 0
            } catch {
                // Rotation failed. Truncate in place instead, so the size bound still holds — resetting `size`
                // without either moving or truncating would let the file grow by another maxLogBytes each round.
                if (try? Data().write(to: url)) != nil { size = 0 }
            }
        }
        if logHandles[url] == nil {
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let fh = try? FileHandle(forWritingTo: url) {
                _ = try? fh.seekToEnd()
                logHandles[url] = fh
            }
        }
        guard let fh = logHandles[url] else { return }
        do {
            try fh.write(contentsOf: data)
            logSizes[url] = size + UInt64(data.count)
        } catch {
            try? fh.close()
            logHandles[url] = nil
            logSizes[url] = nil
        }
    }
}

#if os(macOS) || os(tvOS)
/// Thread-safe byte/packet counters. Packets arrive on the packet-flow queue and
/// leave from the engine's thread, and the app reads a snapshot at any time.
private final class TunnelCounters {
    private let lock = NSLock()
    private var up = 0, down = 0, pktUp = 0, pktDown = 0
    private var connectedSince: Double = 0
    private var serverReachable: Bool?
    private var lastProbe: Double = 0
    private var udpRelayed: Bool?
    private var authRejected: Bool?

    func addUp(_ bytes: Int) {
        lock.lock(); up += bytes; pktUp += 1; lock.unlock()
    }

    func addDown(_ bytes: Int) {
        lock.lock(); down += bytes; pktDown += 1; lock.unlock()
    }

    func markConnected() {
        lock.lock(); connectedSince = Date().timeIntervalSince1970; lock.unlock()
    }

    /// Result of the latest SOCKS5 probe (see `PacketTunnelProvider.runProbe`).
    func setProbe(reachable: Bool, udp: Bool?, authRejected: Bool) {
        lock.lock()
        serverReachable = reachable
        udpRelayed = udp
        self.authRejected = authRejected
        lastProbe = Date().timeIntervalSince1970
        lock.unlock()
    }

    func snapshot(footprintMB: Double) -> TunnelStats {
        lock.lock(); defer { lock.unlock() }
        return TunnelStats(up: up, down: down, pktUp: pktUp, pktDown: pktDown,
                           footprintMB: footprintMB, connectedSince: connectedSince,
                           serverReachable: serverReachable, lastProbe: lastProbe,
                           udpRelayed: udpRelayed, authRejected: authRejected,
                           sampledAt: ProcessInfo.processInfo.systemUptime,
                           sampledAtEpoch: Date().timeIntervalSince1970)
    }
}
#endif

// MARK: - Server address + SOCKS5 probe (BEGIN self-contained: Foundation + Darwin only)

/// The server address pinned for one tunnel session: a numeric IP (no zone text) plus, for IPv6, its scope.
struct ServerAddress: Equatable {
    let ip: String
    let isIPv6: Bool
    /// IPv6 interface index; non-zero only for a link-local (fe80::/10) address.
    let scopeID: UInt32

    /// For logs and messages: `fe80::1%en0` style when scoped.
    var display: String {
        guard isIPv6, scopeID != 0 else { return ip }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        if if_indextoname(scopeID, &name) != nil { return "\(ip)%\(String(cString: name))" }
        return "\(ip)%\(scopeID)"
    }

    /// Resolves `host` (an IP literal, optionally `[bracketed]` or `%zoned`, or a name) with `AF_UNSPEC`, preferring
    /// the first IPv4 answer and falling back to the first IPv6 one. Call only with the tunnel DOWN: with it up, the
    /// engine's virtual DNS answers every name with a fake 198.18.x.x address.
    static func resolve(_ rawHost: String) -> ServerAddress? {
        var host = rawHost.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }

        var v4: ServerAddress?
        var v6: ServerAddress?
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let ai = node, v4 == nil {
            if let sa = ai.pointee.ai_addr {
                if ai.pointee.ai_family == AF_INET {
                    var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil {
                        v4 = ServerAddress(ip: String(cString: buf), isIPv6: false, scopeID: 0)
                    }
                } else if ai.pointee.ai_family == AF_INET6, v6 == nil {
                    var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(buf.count)) != nil {
                        let ip = String(cString: buf)
                        var scope = sin6.sin6_scope_id
                        if scope == 0, isLinkLocalV6(ip) { scope = primaryInterfaceIndex() ?? 0 }
                        v6 = ServerAddress(ip: ip, isIPv6: true, scopeID: isLinkLocalV6(ip) ? scope : 0)
                    }
                }
            }
            node = ai.pointee.ai_next
        }
        return v4 ?? v6
    }

    static func isLinkLocalV6(_ ip: String) -> Bool {
        var a = in6_addr()
        guard inet_pton(AF_INET6, ip, &a) == 1 else { return false }
        return withUnsafeBytes(of: &a) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
    }

    /// Index of the interface that currently carries the default route: a link-local server without a zone is
    /// assumed to be on that link (the same choice the Windows client makes). Found by "connecting" a UDP socket
    /// (no packet is sent) and matching the local address the kernel picked against the interface list.
    static func primaryInterfaceIndex() -> UInt32? {
        func localAddress(family: Int32, probe: String) -> String? {
            let fd = socket(family, SOCK_DGRAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var storage = sockaddr_storage()
            var len: socklen_t
            if family == AF_INET {
                var sin = sockaddr_in()
                sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.sin_family = sa_family_t(AF_INET)
                sin.sin_port = UInt16(9).bigEndian
                guard inet_pton(AF_INET, probe, &sin.sin_addr) == 1 else { return nil }
                len = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeMutableBytes(of: &storage) { dst in withUnsafeBytes(of: &sin) { dst.copyMemory(from: $0) } }
            } else {
                var sin6 = sockaddr_in6()
                sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sin6.sin6_family = sa_family_t(AF_INET6)
                sin6.sin6_port = UInt16(9).bigEndian
                guard inet_pton(AF_INET6, probe, &sin6.sin6_addr) == 1 else { return nil }
                len = socklen_t(MemoryLayout<sockaddr_in6>.size)
                withUnsafeMutableBytes(of: &storage) { dst in withUnsafeBytes(of: &sin6) { dst.copyMemory(from: $0) } }
            }
            let rc = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            guard rc == 0 else { return nil }
            var local = sockaddr_storage()
            var localLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let ok = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &localLen) }
            }
            guard ok == 0 else { return nil }
            return numericHost(&local)
        }
        guard let local = localAddress(family: AF_INET, probe: "192.0.2.1")
                ?? localAddress(family: AF_INET6, probe: "2001:db8::1") else { return nil }
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return nil }
        defer { freeifaddrs(head) }
        var node: UnsafeMutablePointer<ifaddrs>? = head
        while let ifa = node {
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == AF_INET || sa.pointee.sa_family == AF_INET6 {
                var storage = sockaddr_storage()
                withUnsafeMutableBytes(of: &storage) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(start: sa, count: Int(sa.pointee.sa_len)))
                }
                if numericHost(&storage) == local {
                    let index = if_nametoindex(ifa.pointee.ifa_name)
                    return index != 0 ? index : nil
                }
            }
            node = ifa.pointee.ifa_next
        }
        return nil
    }

    /// Numeric host of a sockaddr, without any zone suffix.
    private static func numericHost(_ storage: inout sockaddr_storage) -> String? {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(storage.ss_len)
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard rc == 0 else { return nil }
        return String(cString: buf).split(separator: "%").first.map(String.init)
    }

    /// The socket address to dial, with the scope for a link-local IPv6 server.
    func socketAddress(port: UInt16) -> (sockaddr_storage, socklen_t)? {
        var storage = sockaddr_storage()
        if isIPv6 {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = port.bigEndian
            sin6.sin6_scope_id = scopeID
            guard inet_pton(AF_INET6, ip, &sin6.sin6_addr) == 1 else { return nil }
            withUnsafeMutableBytes(of: &storage) { dst in withUnsafeBytes(of: &sin6) { dst.copyMemory(from: $0) } }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &sin.sin_addr) == 1 else { return nil }
        withUnsafeMutableBytes(of: &storage) { dst in withUnsafeBytes(of: &sin) { dst.copyMemory(from: $0) } }
        return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}

/// SOCKS5 health probe, a port of the Windows client's `probe.rs`: greeting (no-auth, plus username/password when a
/// username is set), RFC 1929 sign-in if the server picks it, then UDP ASSOCIATE — all under ONE deadline, so a
/// server that accepts TCP and then stays silent (a suspended iOS relay) reads as "not answering" within the timeout.
/// Blocking; call it on a queue that may block for `timeout`. Dials the pinned address, which the excluded route
/// sends over the physical interface, never through the tunnel.
enum Socks5Probe {
    enum Result: Equatable {
        /// SOCKS5 answered (and accepted our credentials). `udp` is whether it granted a UDP ASSOCIATE.
        case answering(udp: Bool)
        /// The server answered SOCKS5 but refused our credentials / offered methods.
        case authRejected(String)
        /// No usable SOCKS5 answer: refused, timed out, closed, or spoke something else.
        case notAnswering(String)
    }

    private struct Failure: Error { let reason: String }

    static func probe(_ server: ServerAddress, port: UInt16, username: String, password: String,
                      timeout: TimeInterval) -> Result {
        guard let (address, addressLength) = server.socketAddress(port: port) else {
            return .notAnswering("bad address \(server.ip)")
        }
        let fd = socket(server.isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .notAnswering("socket: errno \(errno)") }
        defer { close(fd) }
        var one: Int32 = 1
        // A write to a server that already reset us must fail with EPIPE, not SIGPIPE the whole extension.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        let io = IO(fd: fd, deadline: deadline, timeout: timeout)
        do {
            var addr = address
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addressLength) }
            }
            if rc != 0 {
                guard errno == EINPROGRESS else { return .notAnswering("connect: \(String(cString: strerror(errno)))") }
                try io.wait(POLLOUT, what: "connect")
                var soError: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                if soError != 0 { return .notAnswering("connect: \(String(cString: strerror(soError)))") }
            }

            let withAuth = !username.isEmpty
            try io.write(withAuth ? [5, 2, 0x00, 0x02] : [5, 1, 0x00])
            let choice = try io.read(2)
            guard choice[0] == 5 else { return .notAnswering("not a SOCKS5 server (version byte \(choice[0]))") }
            switch choice[1] {
            case 0x00:
                break
            case 0x02:
                guard withAuth else { return .authRejected("server requires a username and password") }
                let user = Array(username.utf8), pass = Array(password.utf8)
                guard user.count <= 255, pass.count <= 255 else {
                    return .authRejected("username or password longer than 255 bytes")
                }
                try io.write([1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass)
                let status = try io.read(2)
                guard status[1] == 0 else { return .authRejected("wrong username or password") }
            case 0xFF:
                return .authRejected("server accepts none of the offered sign-in methods")
            case let method:
                return .notAnswering("server chose unsupported method \(method)")
            }

            // UDP ASSOCIATE with an unspecified client address (RFC 1928 §7). The association ends when we close.
            try io.write([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
            let head = try io.read(4)
            let udp = head[0] == 5 && head[1] == 0
            // Drain the bound address so the server sees a clean close rather than a reset with unread data.
            if udp {
                switch head[3] {
                case 1: _ = try? io.read(4 + 2)
                case 4: _ = try? io.read(16 + 2)
                case 3: if let len = try? io.read(1) { _ = try? io.read(Int(len[0]) + 2) }
                default: break
                }
            }
            shutdown(fd, SHUT_RDWR)
            return .answering(udp: udp)
        } catch let failure as Failure {
            return .notAnswering(failure.reason)
        } catch {
            return .notAnswering("\(error)")
        }
    }

    /// Nonblocking reads and writes against one shared deadline.
    private struct IO {
        let fd: Int32
        let deadline: UInt64
        let timeout: TimeInterval

        func wait(_ events: Int32, what: String) throws {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    throw Failure(reason: "no SOCKS5 reply within \(String(format: "%g", timeout)) s (\(what))")
                }
                let ms = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
                var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
                let n = poll(&pfd, 1, ms)
                if n > 0 { return }
                if n < 0 && errno != EINTR { throw Failure(reason: "\(what): poll \(String(cString: strerror(errno)))") }
            }
        }

        func write(_ bytes: [UInt8]) throws {
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
                if n > 0 { sent += n; continue }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { try wait(POLLOUT, what: "send"); continue }
                throw Failure(reason: "handshake: send \(String(cString: strerror(errno)))")
            }
        }

        func read(_ count: Int) throws -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
                if n > 0 { got += n; continue }
                if n == 0 { throw Failure(reason: "handshake: server closed the connection") }
                if errno == EAGAIN || errno == EINTR { try wait(POLLIN, what: "reply"); continue }
                throw Failure(reason: "handshake: recv \(String(cString: strerror(errno)))")
            }
            return buf
        }
    }
}

// MARK: - Server address + SOCKS5 probe (END)

/// Extension-wide logger — this process is separate from the app (a real
/// Network Extension sandbox), so the app's own `DebugLog.swift` file logger
/// (compiled only into the `NetBridge` app target) doesn't cover it. Plain
/// `os.Logger` output, read via Xcode's device console during testing.
private let tunnelLog = Logger(subsystem: "com.Korporate1k.LocalProxy.Tunnel", category: "tunnel")
