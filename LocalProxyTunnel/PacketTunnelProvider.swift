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
        if let serverIP = Self.resolveIPv4(host) {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255")]
            Self.debugLog("excluded route for server \(serverIP)")
        }
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
            self.startEngine(proxyHost: host, proxyPort: port, username: username, password: password)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        tunnelLog.log("stopTunnel reason=\(String(describing: reason), privacy: .public)")
        memoryTimer?.cancel()
        engine?.stop()
        engine = nil
        completionHandler()
    }

    /// Mirrors `ClientTunnelManager.save()`'s Keychain write (same service,
    /// account key, and shared access group) — inlined via `Security`
    /// directly rather than referencing the app target's `KeychainStore`
    /// type, since that file isn't compiled into this extension target.
    private static func loadClientPassword() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.Korporate1k.LocalProxy.persistence",
            kSecAttrAccount as String: "client_password",
            kSecAttrAccessGroup as String: "com.Korporate1k.LocalProxy.shared",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
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

    private func startEngine(proxyHost: String, proxyPort: UInt16, username: String, password: String) {
        let engine = TunnelEngine(proxyHost: proxyHost, proxyPort: proxyPort, username: username, password: password)
        self.engine = engine
        engine.logHandler = { Self.debugLog($0) }
        Self.debugLog("startEngine proxy=\(proxyHost):\(proxyPort) auth=\(!username.isEmpty)")

        engine.onPacketToWrite = { [weak self] data, family in
            guard let self else { return }
            self.outboundCount += 1
            if self.outboundCount <= 5 {
                Self.debugLog("outbound #\(self.outboundCount) bytes=\(data.count) first=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
            }
            self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: family)])
        }

        engine.start()
        readPackets()
        startMemoryLogging()
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
    private static func debugLog(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        // Also mirrored into the extension's private tmp dir: `devicectl
        // device copy from --domain-type appGroupDataContainer` doesn't return
        // this group file, but the private container
        // (`--domain-type appDataContainer --domain-identifier
        // com.Korporate1k.LocalProxy.Tunnel --source /tmp`) reliably does.
        appendLine(line, to: FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-debug.log"))
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.Korporate1k.LocalProxy") else { return }
        appendLine(line, to: dir.appendingPathComponent("tunnel-debug.log"))
    }

    private static func appendLine(_ line: String, to url: URL) {
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Extension-wide logger — this process is separate from the app (a real
/// Network Extension sandbox), so the app's own `DebugLog.swift` file logger
/// (compiled only into the `LocalProxy` app target) doesn't cover it. Plain
/// `os.Logger` output, read via Xcode's device console during testing.
private let tunnelLog = Logger(subsystem: "com.Korporate1k.LocalProxy.Tunnel", category: "tunnel")
