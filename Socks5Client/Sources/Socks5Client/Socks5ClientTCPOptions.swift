import Network

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
        return parameters
    }
}
