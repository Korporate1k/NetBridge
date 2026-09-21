import NetworkExtension
import Network
import Security
import os
import Darwin
import LWIPTunnelEngine

/// The `LocalProxyTunnel` Network Extension: a real system-wide VPN that
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
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: TunnelEngine?
    #if os(macOS)
    /// Live traffic counters for the Mac app's dashboard (see `handleAppMessage`).
    private let counters = TunnelCounters()

    /// The configured server, and the address it resolved to when this tunnel came up. That address is pinned into
    /// `excludedRoutes` and cannot be changed without restarting the tunnel — see `checkServerAddress()`.
    /// Written once in `startTunnel` before the monitor starts, then owned by `pathQueue`.
    private var serverHost: String?
    private var serverPort: UInt16 = 0
    private var excludedServerIP: String?
    private var pathMonitor: NWPathMonitor?
    private var pathCheckWork: DispatchWorkItem?
    private let pathQueue = DispatchQueue(label: "com.Korporate1k.LocalProxy.Tunnel.path")
    /// Probes block for up to 3 s, so they get their own serial queue: `pathQueue` is where `NWPathMonitor`
    /// delivers updates, and blocking that would back up path changes behind a probe.
    private let probeQueue = DispatchQueue(label: "com.Korporate1k.LocalProxy.Tunnel.probe")
    private var reachabilityTimer: DispatchSourceTimer?
    /// All of these are read and written only on `pathQueue` (after `startTunnel` seeds the first three).
    /// `stopping` is the exception — `stopTunnel` sets it, so it is guarded by `pathStateLock`.
    private var serverWasReachable = false
    private var consecutiveUnreachable = 0
    private var didCancelForPath = false
    /// Mirror of what was last reported to the app, so a repeated verdict is not logged every 20 s.
    private var serverReachable: Bool?
    private let pathStateLock = NSLock()
    private var stopping = false
    /// Identifies this tunnel session in the errors we hand to `cancelTunnelWithError`, so the app can tell one
    /// of our failures from a stale one. `fetchLastDisconnectError` is documented only as "the most recent error"
    /// — it makes no promise of being cleared or scoped to the session that just ended.
    private let sessionID = UUID().uuidString
    #endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration,
              let host = config["host"] as? String,
              let portNumber = config["port"] as? NSNumber
        else {
            completionHandler(NSError(domain: "LocalProxyTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing server configuration"]))
            return
        }
        let port = portNumber.uint16Value
        let username = config["username"] as? String ?? ""
        let password = Self.loadClientPassword()
        let authConfigured = !username.isEmpty && !password.isEmpty
        tunnelLog.log("startTunnel host=\(host, privacy: .public) port=\(port, privacy: .public) authConfigured=\(authConfigured, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: host)
        let ipv4 = NEIPv4Settings(addresses: [TunnelEngine.tunnelLocalAddress], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // The engine's own TCP/UDP connection to the SOCKS5 server must NOT be
        // routed back through the tunnel, or it loops: the tunnel captures the
        // engine's connect() to the server, feeds it back into the engine,
        // which dials the server again, and so on — the device can never get
        // out. Exclude the server's address (resolved to a /32) so that one
        // connection goes over the physical interface directly. (Potatso
        // avoided this by dialing a *local* 127.0.0.1 proxy; we dial a remote
        // server, so the exclusion is required.)
        // Refuse to start rather than come up without the exclusion. A tunnel whose excluded route is missing
        // sends the engine's own connection to the proxy back through itself — the loop described above — and
        // still reports Connected while carrying nothing. Failing here surfaces it so the app can retry.
        guard let serverIP = Self.resolveIPv4(host) else {
            tunnelLog.error("could not resolve \(host, privacy: .public); refusing to start without an excluded route")
            completionHandler(NSError(domain: "LocalProxyTunnel", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Could not resolve the SOCKS5 server address \"\(host)\"."
            ]))
            return
        }
        ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255")]
        Self.debugLog("excluded route for server \(serverIP)")
        #if os(macOS)
        excludedServerIP = serverIP
        #endif
        #if os(macOS)
        serverHost = host
        serverPort = port
        #endif
        settings.ipv4Settings = ipv4
        // Capture IPv6 too — otherwise it goes straight out the physical
        // interface, bypassing the proxy. tun2proxy relays IPv6 like IPv4
        // (the old BadVPN core was IPv4-only, which is why this used to be
        // left uncaptured).
        let ipv6 = NEIPv6Settings(addresses: [TunnelEngine.tunnelLocalAddressV6], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                tunnelLog.error("setTunnelNetworkSettings failed host=\(host, privacy: .public) error=\(String(describing: error), privacy: .public)")
                completionHandler(error)
                return
            }
            tunnelLog.log("tunnel network settings applied ipv4=\(TunnelEngine.tunnelLocalAddress, privacy: .public) dns=8.8.8.8,8.8.4.4")
            self.startEngine(proxyHost: host, proxyPort: port, username: username, password: password,
                             verbosity: config["verbosity"] as? String ?? TunnelEngine.defaultVerbosity)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        tunnelLog.log("stopTunnel reason=\(String(describing: reason), privacy: .public)")
        memoryTimer?.cancel()
        #if os(macOS)
        statsTimer?.cancel()
        reachabilityTimer?.cancel()
        // Set first: a path update already in flight on pathQueue can install a new work item after the cancel
        // below, and that item would otherwise run a blocking probe against a torn-down session.
        pathStateLock.lock()
        stopping = true
        pathStateLock.unlock()
        pathMonitor?.cancel()
        pathMonitor = nil
        // pathCheckWork belongs to pathQueue; mutating it from this queue would be an ARC race.
        pathQueue.async { [self] in
            pathCheckWork?.cancel()
            pathCheckWork = nil
        }
        #endif
        engine?.stop()
        engine = nil
        completionHandler()
    }

    #if os(macOS)
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
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Resolves the configured server `host` to an IPv4 literal for the
    /// tunnel's `excludedRoutes` (the engine's own connection to the server
    /// must bypass the tunnel). Returns `nil` if it's neither an IPv4 literal
    /// nor resolvable to one.
    private static func resolveIPv4(_ host: String) -> String? {
        // Fast path: already an IPv4 literal.
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) == 1 {
            return host
        }
        // Slow path: hostname → getaddrinfo (runs before the tunnel is up, so
        // it uses the device's normal DNS).
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = res.pointee.ai_addr else { return nil }
        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var sinAddr = sin.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let ip = inet_ntop(AF_INET, &sinAddr, &buf, socklen_t(INET_ADDRSTRLEN)) else { return nil }
        return String(cString: ip)
    }

    private var inboundCount = 0
    private var outboundCount = 0

    private func startEngine(proxyHost: String, proxyPort: UInt16, username: String, password: String, verbosity: String) {
        let engine = TunnelEngine(proxyHost: proxyHost, proxyPort: proxyPort, username: username, password: password,
                                  verbosity: verbosity)
        self.engine = engine
        engine.logHandler = { Self.debugLog($0) }
        Self.debugLog("startEngine proxy=\(proxyHost):\(proxyPort) auth=\(!username.isEmpty) verbosity=\(verbosity)")

        engine.onPacketsToWrite = { [weak self] packets, families in
            guard let self else { return }
            for data in packets {
                self.outboundCount += 1
                if self.outboundCount <= 5 {
                    Self.debugLog("outbound #\(self.outboundCount) bytes=\(data.count) first=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
                }
                #if os(macOS)
                self.counters.addDown(data.count)
                #endif
            }
            self.packetFlow.writePackets(packets, withProtocols: families.map { NSNumber(value: $0) })
        }

        #if os(macOS)
        // The engine ended without stopTunnel() asking it to. tun2proxy force-exits this process ~2 s later, so
        // report a real error to NetworkExtension while we still can; the Mac app reconnects on a disconnect that
        // carries one.
        //
        // macOS only, deliberately. On iOS nothing reconnects — there are no on-demand rules and no equivalent of
        // MacClientModel's retry — and letting the process die on its own leaves NetworkExtension free to relaunch
        // the provider. Ending the session explicitly there would turn a recoverable crash into a tunnel that
        // stays down in the user's pocket.
        engine.onEngineExit = { [weak self] rc in
            guard let self else { return }
            Self.debugLog("engine exited unexpectedly rc=\(rc), cancelling tunnel")
            self.cancelTunnelWithError(NSError(domain: "LocalProxyTunnel", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel engine stopped unexpectedly (rc=\(rc))",
                "sessionID": self.sessionID
            ]))
        }
        #endif

        #if os(macOS)
        counters.markConnected()
        #endif
        engine.start()
        readPackets()
        startMemoryLogging()
        #if os(macOS)
        startStatsLogging()
        startPathMonitor()
        #endif
    }

    #if os(macOS)
    /// The excluded route pinned in `startTunnel` is only right for the address the server had at that moment.
    /// Across sessions this Mac has reached its relay at 172.20.10.1 (phone hotspot), 10.0.0.129 (home LAN) and
    /// once at a 169.254 link-local address, so it does move. NetworkExtension gives no callback for "the address
    /// behind your excluded route changed", and the failure is silent — the tunnel still reports Connected while
    /// nothing gets through — so watch for path changes and check.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Self.debugLog("path update status=\(path.status) interfaces=\(path.availableInterfaces.map(\.name).joined(separator: ","))")
            self.schedulePathCheck()
        }
        monitor.start(queue: pathQueue)
        startReachabilityPolling()
    }

    /// A path change is not the only way to lose the proxy, and not even the common one: the relay app on the phone
    /// can be suspended, or the phone can walk away, with no network change on this Mac at all. Nothing in the
    /// stack notices — NE stays Connected and the engine keeps running — so poll, and report the verdict to the
    /// app through `TunnelStats.serverReachable`.
    private func startReachabilityPolling() {
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + 5, repeating: .seconds(20))
        // Polls only report; they never tear the tunnel down. Acting on a bad poll would mean cancelling sessions
        // whenever the relay is merely off, which churns without fixing anything.
        timer.setEventHandler { [weak self] in self?.probeServer(mayCancelTunnel: false) }
        reachabilityTimer = timer
        timer.resume()
    }

    /// One Wi-Fi change emits several path updates in a row, so settle first.
    private func schedulePathCheck() {
        pathCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.probeQueue.async { self.probeServer(mayCancelTunnel: true) }
        }
        pathCheckWork = work
        pathQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Runs on `probeQueue` (serial, so probes never overlap), and owns `serverWasReachable`,
    /// `consecutiveUnreachable` and `didCancelForPath`.
    ///
    /// Deliberately does NOT re-resolve the host. While this tunnel is up, a DNS query from this process goes
    /// *through* the tunnel (that is the whole reason `excludedRoutes` exists), and the engine runs with
    /// `--dns virtual`, which answers any query for port 53 out of a fake 198.18.0.0/15 pool regardless of the
    /// destination. Re-resolving here would therefore return a fake address, compare unequal to the pinned one,
    /// and cancel a perfectly healthy tunnel — and it would poison the system resolver's cache for the server's
    /// name on the way out.
    ///
    /// So brokenness is detected without DNS: probe the address actually pinned into `excludedRoutes`, which by
    /// construction routes over the physical interface. When it stops answering, cancel once and let the app
    /// reconnect — `startTunnel` then re-resolves with the tunnel *down*, where DNS is trustworthy, and pins
    /// whatever the correct address is now. That covers both a hostname whose address moved and a literal IP
    /// that belongs to a network we have left.
    private func probeServer(mayCancelTunnel: Bool) {
        guard !isStopping, let pinned = excludedServerIP, serverPort != 0 else { return }
        let host = serverHost ?? pinned

        if Self.canReachServer(ip: pinned, port: serverPort, timeout: 3) {
            if serverReachable != true { Self.debugLog("probe: server \(host) at \(pinned) reachable") }
            counters.setServerReachable(true)
            serverWasReachable = true
            consecutiveUnreachable = 0
            return
        }

        counters.setServerReachable(false)
        consecutiveUnreachable += 1
        Self.debugLog("probe: server \(host) at \(pinned) UNREACHABLE (\(consecutiveUnreachable) in a row, wasReachable=\(serverWasReachable)) — tunnel still reports connected")

        // Only a path change may act on this, and only for a server this session had already reached: if it was
        // never reachable the address is simply wrong or the relay is off, and restarting would churn without
        // fixing anything. One cancel per session, so a reconnect landing in the same broken state cannot loop.
        guard mayCancelTunnel, serverWasReachable, consecutiveUnreachable >= 2, !didCancelForPath else { return }
        didCancelForPath = true
        tunnelLog.error("server \(pinned, privacy: .public) stopped answering after a network change; cancelling so routes are rebuilt")
        Self.debugLog("probe: cancelling tunnel so the app reconnects and re-resolves \(host) with the tunnel down")
        cancelTunnelWithError(NSError(domain: "LocalProxyTunnel", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Lost the path to the SOCKS5 server at \(pinned) after a network change. Reconnecting to rebuild the tunnel's routes.",
            "sessionID": sessionID
        ]))
    }

    private var isStopping: Bool {
        pathStateLock.lock()
        defer { pathStateLock.unlock() }
        return stopping
    }

    /// Blocking TCP connect with a timeout, used only as a reachability probe. Goes out over the physical
    /// interface because `pinned` is exactly the address `excludedRoutes` covers.
    private static func canReachServer(ip: String, port: UInt16, timeout: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        // Non-blocking connect + poll, so a black-holed address cannot park this queue for the system's full
        // TCP timeout.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeout * 1000) == 1 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }
    #endif

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, let engine = self.engine else { return }
            for (i, packet) in packets.enumerated() {
                self.inboundCount += 1
                if self.inboundCount <= 5 {
                    Self.debugLog("inbound #\(self.inboundCount) bytes=\(packet.count) first=\(packet.prefix(8).map { String(format: "%02x", $0) }.joined())")
                }
                let family = protocols.indices.contains(i) ? protocols[i].int32Value : AF_INET
                #if os(macOS)
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

#if os(macOS)
/// Thread-safe byte/packet counters. Packets arrive on the packet-flow queue and
/// leave from the engine's thread, and the app reads a snapshot at any time.
private final class TunnelCounters {
    private let lock = NSLock()
    private var up = 0, down = 0, pktUp = 0, pktDown = 0
    private var connectedSince: Double = 0
    private var serverReachable: Bool?
    private var lastProbe: Double = 0

    func addUp(_ bytes: Int) {
        lock.lock(); up += bytes; pktUp += 1; lock.unlock()
    }

    func addDown(_ bytes: Int) {
        lock.lock(); down += bytes; pktDown += 1; lock.unlock()
    }

    func markConnected() {
        lock.lock(); connectedSince = Date().timeIntervalSince1970; lock.unlock()
    }

    /// Result of the latest reachability probe (see `PacketTunnelProvider.probeServer`).
    func setServerReachable(_ reachable: Bool) {
        lock.lock()
        serverReachable = reachable
        lastProbe = Date().timeIntervalSince1970
        lock.unlock()
    }

    func snapshot(footprintMB: Double) -> TunnelStats {
        lock.lock(); defer { lock.unlock() }
        return TunnelStats(up: up, down: down, pktUp: pktUp, pktDown: pktDown,
                           footprintMB: footprintMB, connectedSince: connectedSince,
                           serverReachable: serverReachable, lastProbe: lastProbe)
    }
}
#endif

/// Extension-wide logger — this process is separate from the app (a real
/// Network Extension sandbox), so the app's own `DebugLog.swift` file logger
/// (compiled only into the `LocalProxy` app target) doesn't cover it. Plain
/// `os.Logger` output, read via Xcode's device console during testing.
private let tunnelLog = Logger(subsystem: "com.Korporate1k.LocalProxy.Tunnel", category: "tunnel")
