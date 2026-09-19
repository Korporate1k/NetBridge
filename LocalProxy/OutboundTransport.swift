import Foundation
import Network

/// A direct TCP `NWConnection` using `.tunedTCP()` (below) instead of the bare
/// `.tcp` preset for throughput.
struct DirectTCPTransport {
    func dial(host: String, port: NWEndpoint.Port) -> NWConnection {
        let parameters = NWParameters.tunedTCP()
        // Outbound-only: this app IS the proxy for its own clients, so its
        // own outbound dials should never be intercepted by some unrelated
        // system proxy configuration — only meaningful for the dialing side,
        // not the inbound listener, so it isn't part of `tunedTCP()` itself.
        parameters.preferNoProxies = true
        EgressTTL.install(on: parameters)
        return NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }
}

extension NWParameters {
    /// TCP tuning shared by both legs of every relayed connection: the
    /// inbound listener (`ProxyServer`) and every outbound dial
    /// (`DirectTCPTransport`, above). Replaces the bare `.tcp` preset both
    /// used before.
    static func tunedTCP() -> NWParameters {
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

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

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
        return parameters
    }
}
