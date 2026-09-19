import Network

/// The IP TTL / IPv6 hop-limit forced onto every SOCKS5 egress connection the
/// client dials, so tunneled traffic that leaves the device reads like a phone
/// dialing directly (64 is the stock iOS/macOS/Linux value).
fileprivate let socks5ClientEgressHopLimit: UInt8 = 64

extension NWParameters {
    /// A reasonable default for dialing a SOCKS5 proxy: disables Nagle's
    /// algorithm and ACK stretching (both are a pure latency cost for a
    /// proxy handshake's small, back-to-back writes) and avoids routing the
    /// dial itself through some ambient system proxy configuration.
    ///
    /// Deliberately does not set app-specific policy like
    /// `prohibitExpensivePaths` or `serviceClass` — those are a consuming
    /// app's call to make (e.g. via its own `NWParameters` passed to
    /// `Socks5Client.init`), not this package's.
    public static func socks5ClientDefault() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.disableAckStretching = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.preferNoProxies = true
        installEgressHopLimit(on: parameters)
        return parameters
    }

    /// UDP preset for the SOCKS5 UDP ASSOCIATE leg, carrying the same egress
    /// hop limit as `socks5ClientDefault()`.
    public static func socks5ClientUDP() -> NWParameters {
        let parameters = NWParameters.udp
        installEgressHopLimit(on: parameters)
        return parameters
    }

    private static func installEgressHopLimit(on parameters: NWParameters) {
        guard let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options else { return }
        ip.hopLimit = socks5ClientEgressHopLimit
    }
}
