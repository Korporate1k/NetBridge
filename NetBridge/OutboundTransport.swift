import Foundation
import Network

/// A direct TCP `NWConnection` using `.tunedTCP()` (below) instead of the bare
/// `.tcp` preset for throughput.
struct DirectTCPTransport {
    /// `tlsServerName` non-nil: run TLS to the origin with Network.framework (the
    /// iOS ClientHello, ALPN `http/1.1`, system trust). It is the SNI and the
    /// name the certificate is checked against, so it stays the real hostname even
    /// when `host` is an IP from DoH or NAT64.
    func dial(host: String, port: NWEndpoint.Port, tlsServerName: String? = nil) -> NWConnection {
        let parameters = NWParameters.tunedTCP(tlsServerName: tlsServerName)
        // Outbound-only: this app IS the proxy for its own clients, so its
        // own outbound dials should never be intercepted by some unrelated
        // system proxy configuration — only meaningful for the dialing side,
        // not the inbound listener, so it isn't part of `tunedTCP()` itself.
        parameters.preferNoProxies = true
        EgressTTL.install(on: parameters)
        EgressInterface.apply(to: parameters)
        // Cellular-pinned on an IPv6-only carrier: an IPv4 literal has no route, so reach it through NAT64 (no-op otherwise).
        let dialHost = NAT64.synthesizedHost(forIPv4Literal: host) ?? host
        // Carrier NAT (CGNAT/NAT64) drops idle mappings — the phone's log showed established connections reset after
        // ~30-45 s idle. Cellular-pinned connections send TCP keep-alives to keep the mapping warm.
        if EgressInterface.current == .cellular, let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 4
        }
        return NWConnection(host: NWEndpoint.Host(dialHost), port: port, using: parameters)
    }
}

extension NWParameters {
    /// TCP tuning shared by both legs of every relayed connection: the
    /// inbound listener (`ProxyServer`) and every outbound dial
    /// (`DirectTCPTransport`, above). Replaces the bare `.tcp` preset both
    /// used before.
    static func tunedTCP(tlsServerName: String? = nil) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()

        // Nagle's algorithm delays small writes to coalesce them into fewer,
        // larger segments — a win for chatty, small-write workloads (its
        // original telnet-latency use case), but a pure cost here: the relay
        // loop already reads/writes in large, Network.framework-sized chunks
        // (up to 1MB per `receive()`, see `ConnectProxyHandler.swift`'s
        // `forward(from:to:isUpstream:)`), so there's nothing worth
        // coalescing — only an artificial delay added to every relayed write
        // while Nagle waits for more data or an ACK. Disabling it
        // (TCP_NODELAY) is the standard choice for a relay/proxy.
        tcpOptions.noDelay = true

        // Nagle (above) and the peer's delayed-ACK timer are the classic pair
        // that causes ~40-200ms stalls when only one side is tuned; disabling
        // ACK stretching on our side too closes the other half of that gap.
        // The cost — more, smaller ACK packets — is negligible next to the
        // relayed chunk sizes involved.
        tcpOptions.disableAckStretching = true

        var tlsOptions: NWProtocolTLS.Options?
        if let name = tlsServerName {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, name)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            tlsOptions = tls
        }
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        // A proxy shouldn't second-guess which path the OS already chose —
        // refusing "expensive" paths (cellular, personal hotspot, ...) would
        // make the relay silently fail on exactly the connections its client
        // is relying on it for.
        parameters.prohibitExpensivePaths = false

        // Hints the OS scheduler that this is not background/bulk-only
        // traffic. The default `.bestEffort` already isn't deprioritized the
        // way `.background` is, but `.responsiveData` is the closest accurate
        // description of "proxying whatever the client is doing right now"
        // without misrepresenting this as voice/video-specific traffic.
        parameters.serviceClass = .responsiveData

        return parameters
    }
}

/// IP TTL / IPv6 hop-limit forced onto every egress (dial-out) connection, so
/// relayed traffic that leaves this device reads like a phone dialing directly
/// (64 is the stock iPhone/iPad/macOS/Linux value).
enum EgressTTL {
    static let hopLimit: UInt8 = 64

    /// Installs the egress hop limit onto `parameters` (mutates in place).
    ///
    /// `NWProtocolIP.Options` has no accessible initializer, so we don't build
    /// a fresh one — we grab the internet-protocol options the default protocol
    /// stack already created and mutate its hop limit in place.
    static func install(on parameters: NWParameters) {
        guard let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options else { return }
        ip.hopLimit = hopLimit
    }

    /// UDP preset with the egress hop limit installed.
    static var udp: NWParameters {
        let parameters = NWParameters.udp
        install(on: parameters)
        EgressInterface.apply(to: parameters)
        return parameters
    }
}

/// Which kind of network interface outbound (dial-out) traffic must use.
/// `automatic` leaves the choice to the OS. Stored in `UserDefaults` under
/// `defaultsKey` (the same read-directly pattern `DoHResolver` uses for
/// `doh.enabled`), so no setting has to be threaded through `ProxyServer`/
/// `Tunnel`. Pinned types fail closed: if no matching interface is up, the
/// dial waits/fails rather than silently leaving over a different interface.
enum EgressInterface: String, CaseIterable, Identifiable, Codable {
    case automatic, wifi, cellular, wired
    /// Not in the picker: driven by its own "Bind to VPN" switch (`bindVPNKey`), which overrides the picker.
    case vpn

    static let defaultsKey = "egress.interface"
    static let bindVPNKey = "egress.bindVPN"
    /// Posted (userInfo `old`/`new`, tunnel names) when the VPN tunnel appears, disappears or changes.
    static let vpnChangedNotification = Notification.Name("EgressVPNTunnelChanged")

    /// What the Outbound-interface picker offers (VPN has its own control).
    static let pickerCases: [EgressInterface] = [.automatic, .wifi, .cellular, .wired]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .wired: return "Wired (Ethernet)"
        case .vpn: return "VPN"
        }
    }

    var nwType: NWInterface.InterfaceType? {
        switch self {
        case .automatic: return nil
        case .wifi: return .wifi
        case .cellular: return .cellular
        case .wired: return .wiredEthernet
        case .vpn: return .other
        }
    }

    /// The picker's stored value (never `.vpn`).
    static var stored: EgressInterface {
        let value = UserDefaults.standard.string(forKey: defaultsKey).flatMap(EgressInterface.init(rawValue:)) ?? .automatic
        return value == .vpn ? .automatic : value
    }

    /// The effective egress: the VPN switch wins over the picker.
    static var current: EgressInterface {
        UserDefaults.standard.bool(forKey: bindVPNKey) ? .vpn : stored
    }

    /// Starts watching interfaces from launch so VPN connect/disconnect is noticed (see `vpnChangedNotification`).
    static func startWatching() { InterfaceLookup.startWatching() }

    /// Pins `parameters` to the selected interface type (no-op for `automatic`).
    static func apply(to parameters: NWParameters) {
        let mode = current
        guard let type = mode.nwType else { return }
        if mode == .vpn, let vpn = InterfaceLookup.shared.vpnInterface() {
            parameters.requiredInterface = vpn          // the exact utun tunnel
        } else {
            // VPN with no tunnel object found: `.other` is what worked on the phone (236 dials via utun7). Do NOT add
            // prohibitedInterfaceTypes here — a tunnel that rides cellular/Wi-Fi counts as that type, so prohibiting them
            // blocks the tunnel itself (seen on the phone: "Interface type 'cellular' is prohibited by parameters").
            parameters.requiredInterfaceType = type
        }
    }

    /// BSD interface index of a live interface of the selected type, for
    /// `IPV6_BOUND_IF` on raw sockets (`EgressSocket`). `nil`
    /// when `automatic` or when no such interface is currently up.
    static func boundInterfaceIndex() -> UInt32? {
        guard let type = current.nwType else { return nil }
        // The path monitor reports nothing for a type while e.g. a VPN is connecting (its path is `requiresConnection`),
        // so fall back to reading the interface table directly — stable pdp_ip* naming makes that safe for cellular.
        let name: String?
        switch current {
        case .vpn: name = VPNProbe.activeName()
        case .cellular: name = InterfaceLookup.shared.interfaceName(for: type) ?? CellularProbe.primaryName()
        default: name = InterfaceLookup.shared.interfaceName(for: type)
        }
        guard let name = name else { return nil }
        let index = if_nametoindex(name)
        return index == 0 ? nil : index
    }
}

/// Tracks the live interface name for each pinnable type with one long-lived
/// `NWPathMonitor(requiredInterfaceType:)` apiece (started lazily on first
/// use), so `boundInterfaceIndex()` is a cheap cached read. A path monitor's
/// `currentPath` is only available asynchronously, hence the cache.
private final class InterfaceLookup {
    static let shared = InterfaceLookup()

    private let lock = NSLock()
    private var names: [NWInterface.InterfaceType: String] = [:]
    private var interfaces: [NWInterface.InterfaceType: [NWInterface]] = [:]
    private var vpnName: String?
    private var vpnKnown = false   // the first report is a baseline, not a change
    private var reported: Set<NWInterface.InterfaceType> = []
    private let queue = DispatchQueue(label: "egress.interface.lookup")
    private var monitors: [NWPathMonitor] = []

    private static let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]

    private init() {
        for type in Self.types {
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                let name = path.status == .satisfied
                    ? path.availableInterfaces.first(where: { $0.type == type })?.name
                    : nil
                self.lock.lock()
                self.names[type] = name
                self.interfaces[type] = path.availableInterfaces.filter { $0.type == type }
                self.reported.insert(type)
                var change: (old: String?, new: String?)?
                if type == .other {
                    let newVPN = self.newestUtun(in: self.interfaces[type] ?? [])
                    if self.vpnKnown, newVPN != self.vpnName { change = (self.vpnName, newVPN) }
                    self.vpnName = newVPN
                    self.vpnKnown = true
                }
                self.lock.unlock()
                if let change = change {
                    NotificationCenter.default.post(name: EgressInterface.vpnChangedNotification, object: nil,
                                                    userInfo: ((change.old.map { ["old": $0] } ?? [:]).merging(change.new.map { ["new": $0] } ?? [:]) { a, _ in a }))
                }
            }
            monitor.start(queue: queue)
            monitors.append(monitor)
        }
    }

    /// Cached interface name for `type`; on the very first call, waits briefly
    /// (up to ~300 ms) for the monitor's initial report so a freshly launched
    /// app doesn't misread "not reported yet" as "interface down".
    /// Starts the path monitors early so VPN changes are noticed from launch (otherwise they start on first use).
    static func startWatching() { _ = shared }

    private func newestUtun(in list: [NWInterface]) -> String? {
        func index(_ n: String) -> Int { Int(n.dropFirst("utun".count)) ?? -1 }
        return list.map(\.name).filter { $0.hasPrefix("utun") }.max { index($0) < index($1) }
    }

    /// The `NWInterface` of the active VPN tunnel (found by name via `VPNProbe`), if the monitor knows it.
    /// Taken from the interfaces iOS itself reports as available (an address-based guess picked the wrong or no tunnel).
    func vpnInterface() -> NWInterface? {
        _ = interfaceName(for: .other)   // waits for the first report
        lock.lock()
        defer { lock.unlock() }
        func index(_ i: NWInterface) -> Int { Int(i.name.dropFirst("utun".count)) ?? -1 }
        return (interfaces[.other] ?? []).filter { $0.name.hasPrefix("utun") }.max { index($0) < index($1) }
    }

    func interfaceName(for type: NWInterface.InterfaceType) -> String? {
        for _ in 0..<30 {
            lock.lock()
            let done = reported.contains(type)
            let name = names[type]
            lock.unlock()
            if done { return name }
            usleep(10_000)
        }
        return nil
    }
}

/// NAT64 address synthesis for the Cellular pin. Measured on a phone (T-Mobile-style 464XLAT carrier) with Wi-Fi as the
/// primary network: an `NWConnection` required to use cellular gets "No network route" for every IPv4 destination — the
/// v4 default route stays on Wi-Fi — while IPv6 destinations work. iOS has no public NAT64 API, so when the pin is Cellular
/// and that interface is IPv6-only, IPv4 destinations are dialed as `64:ff9b::a.b.c.d` (the RFC 6052 well-known prefix,
/// which NAT64 gateways translate). Assumes the carrier uses the well-known prefix; other prefixes would need discovery.
enum NAT64 {
    private static let lock = NSLock()
    private static var cached: (value: Bool, at: UInt64)?
    private static let cacheNanos: UInt64 = 5_000_000_000
    private static let prefix: [UInt8] = [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]

    /// True when the pin is Cellular and the cellular interface has no real IPv4 address (none, or only the
    /// `192.0.0.0/29` CLAT/DS-Lite address). Cached briefly — it is consulted per UDP datagram.
    static var isActive: Bool {
        guard EgressInterface.current == .cellular else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        if let cached = cached, now &- cached.at < cacheNanos { return cached.value }
        let value = cellularIsIPv6Only()
        cached = (value, now)
        return value
    }

    /// Auto-detects an IPv6-only cellular network from the interface table: the data interface has a global IPv6
    /// address and no real IPv4 (none, or only the 192.0.0.0/29 CLAT address). Deliberately independent of the path
    /// monitor, whose cellular path can read unsatisfied while a VPN connects — that used to turn NAT64 off and break IPv4.
    private static func cellularIsIPv6Only() -> Bool {
        let name = InterfaceLookup.shared.interfaceName(for: .cellular) ?? CellularProbe.primaryName()
        guard let name = name, let facts = CellularProbe.facts().first(where: { $0.name == name }) else { return false }
        return CellularProbe.isIPv6Only(realIPv4: facts.realIPv4, globalIPv6: facts.globalIPv6)
    }

    /// Public, globally routable IPv4 only — private/loopback/link-local/CGNAT/multicast can't be NAT64'd.
    static func synthesizable(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (100, 64...127), (172, 16...31), (198, 18...19), (224...255, _): return false
        case (192, 0) where b[2] == 0: return false
        default: return true
        }
    }

    static func synthesizedBytes(_ v4: [UInt8]) -> [UInt8] { prefix + v4 }

    /// The IPv4 embedded in a `64:ff9b::/96` address, or nil.
    static func embeddedIPv4(from v6: [UInt8]) -> [UInt8]? {
        guard v6.count == 16, Array(v6[0..<12]) == prefix else { return nil }
        return Array(v6[12..<16])
    }

    private static func text(_ b: [UInt8]) -> String {
        String(format: "64:ff9b::%02x%02x:%02x%02x", b[0], b[1], b[2], b[3])
    }

    /// `64:ff9b::…` text for a public IPv4 literal when NAT64 is active; nil otherwise (including for hostnames).
    static func synthesizedHost(forIPv4Literal host: String) -> String? {
        var v4 = in_addr()
        guard inet_pton(AF_INET, host, &v4) == 1 else { return nil }
        let octets = withUnsafeBytes(of: v4) { Array($0) }
        guard synthesizable(octets), isActive else { return nil }
        return text(octets)
    }

    /// The host string to actually dial. BLOCKING for hostnames (`getaddrinfo`) — call off the relay queue. When NAT64
    /// is active: IPv4 literals are synthesized; a hostname resolves to its native IPv6 if it has one, else its first
    /// public IPv4 synthesized. Anything else (IPv6 literal, private IPv4, resolution failure) is returned unchanged.
    static func dialHost(for host: String) -> String {
        guard isActive else { return host }
        if let synthesized = synthesizedHost(forIPv4Literal: host) { return synthesized }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return host }

        // Ask for IPv6 explicitly first: an AF_UNSPEC lookup on the phone returned only IPv4 for hosts that have real IPv6
        // (Google/Apple), so they went out through NAT64 and showed the most resets. An AF_INET6 lookup returns the native
        // AAAA, or IPv4-mapped (::ffff:a.b.c.d) addresses for IPv4-only names, which are synthesized instead.
        var mappedV4: [UInt8]?
        var v6Hints = addrinfo()
        v6Hints.ai_family = AF_INET6
        v6Hints.ai_socktype = SOCK_STREAM
        var v6Result: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &v6Hints, &v6Result) == 0, let first = v6Result {
            defer { freeaddrinfo(v6Result) }
            for info in sequence(first: first, next: { $0.pointee.ai_next }) {
                guard let sa = info.pointee.ai_addr, info.pointee.ai_family == AF_INET6 else { continue }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let resolved: (native: Bool, v4: [UInt8]?, text: String?) = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var a = sin6.pointee.sin6_addr
                    let b = withUnsafeBytes(of: a) { Array($0) }
                    if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return (false, nil, nil) }   // link-local
                    if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return (false, Array(b[12..<16]), nil) }
                    guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return (false, nil, nil) }
                    return (true, nil, String(cString: buf))
                }
                if resolved.native, let text = resolved.text { return text }
                if mappedV4 == nil, let v4 = resolved.v4, synthesizable(v4) { mappedV4 = v4 }
            }
        }
        if let v4 = mappedV4 { return text(v4) }

        // No IPv6 answer at all: fall back to a plain IPv4 lookup and synthesize.
        var v4Hints = addrinfo()
        v4Hints.ai_family = AF_INET
        v4Hints.ai_socktype = SOCK_STREAM
        var v4Result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &v4Hints, &v4Result) == 0, let first4 = v4Result else { return host }
        defer { freeaddrinfo(v4Result) }
        for info in sequence(first: first4, next: { $0.pointee.ai_next }) {
            guard let sa = info.pointee.ai_addr, info.pointee.ai_family == AF_INET else { continue }
            let octets = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
            if synthesizable(octets) { return text(octets) }
        }
        return host
    }
}

/// Reads cellular (`pdp_ip*`) interface state straight from the interface table.
enum CellularProbe {
    struct Facts { let name: String; let realIPv4: Bool; let globalIPv6: Bool }

    /// Up-and-running `pdp_ip*` interfaces in numeric order (pdp_ip0 — the data APN — first).
    static func facts() -> [Facts] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }
        var byName: [String: (v4: Bool, v6: Bool)] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("pdp_ip"), let addr = ifa.ifa_addr,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_RUNNING) != 0 else { continue }
            var entry = byName[name] ?? (false, false)
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                let o = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                if isRealIPv4(o) { entry.v4 = true }
            case AF_INET6:
                let b = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                if b[0] & 0xe0 == 0x20 { entry.v6 = true }   // 2000::/3 global unicast
            default: break
            }
            byName[name] = entry
        }
        func index(_ n: String) -> Int { Int(n.dropFirst("pdp_ip".count)) ?? Int.max }
        return byName.keys.sorted { index($0) < index($1) }.map { Facts(name: $0, realIPv4: byName[$0]!.v4, globalIPv6: byName[$0]!.v6) }
    }

    /// The cellular data interface: the first up `pdp_ip*` that has a usable address.
    static func primaryName() -> String? {
        facts().first(where: { $0.globalIPv6 || $0.realIPv4 })?.name
    }

    /// Not a CLAT/DS-Lite (192.0.0.0/29) or link-local address.
    static func isRealIPv4(_ o: [UInt8]) -> Bool {
        guard o.count == 4 else { return false }
        if o[0] == 192 && o[1] == 0 && o[2] == 0 && o[3] < 8 { return false }
        if o[0] == 169 && o[1] == 254 { return false }
        return true
    }

    static func isIPv6Only(realIPv4: Bool, globalIPv6: Bool) -> Bool { globalIPv6 && !realIPv4 }
}

/// The VPN tunnel to bind to, taken only from the interfaces iOS itself reports as available (`InterfaceLookup`). An earlier
/// address-based guess over `getifaddrs` could pick the wrong tunnel, and as a fallback it let dials proceed with no real
/// VPN, so there is deliberately no fallback: no reported tunnel means "no VPN" and Bind to VPN fails closed.
enum VPNProbe {
    static func activeName() -> String? {
        InterfaceLookup.shared.vpnInterface()?.name
    }
}
