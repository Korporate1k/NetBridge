import Foundation

/// Live counters the macOS packet-tunnel extension reports to the app over
/// `sendProviderMessage` (see `PacketTunnelProvider.handleAppMessage`). Compiled
/// into both the app and the extension so the JSON shape can't drift.
///
/// `up` is traffic leaving this Mac (device -> tunnel), `down` is traffic coming
/// back (tunnel -> device). `connectedSince` is epoch seconds, 0 when unknown.
struct TunnelStats: Codable, Equatable {
    var up: Int
    var down: Int
    var pktUp: Int
    var pktDown: Int
    var footprintMB: Double
    var connectedSince: Double

    /// Whether the SOCKS5 server answered the extension's last reachability probe. `nil` until one has finished.
    ///
    /// This carries the difference between "the VPN is up" and "the VPN works". NetworkExtension reports Connected
    /// as soon as the tunnel's network settings are applied — it never contacts the proxy — and the engine does not
    /// exit when the proxy stops answering (per-session failures are logged inside spawned tasks). So a relay that
    /// has gone away looks exactly like a healthy one: Connected, uptime ticking, nothing moving. Without this the
    /// app has no signal at all.
    var serverReachable: Bool?
    /// Epoch seconds of the last probe; 0 if none has run yet. Lets the app ignore a stale verdict.
    var lastProbe: Double

    static let zero = TunnelStats(up: 0, down: 0, pktUp: 0, pktDown: 0, footprintMB: 0, connectedSince: 0,
                                  serverReachable: nil, lastProbe: 0)

    init(up: Int, down: Int, pktUp: Int, pktDown: Int, footprintMB: Double, connectedSince: Double,
         serverReachable: Bool?, lastProbe: Double) {
        self.up = up
        self.down = down
        self.pktUp = pktUp
        self.pktDown = pktDown
        self.footprintMB = footprintMB
        self.connectedSince = connectedSince
        self.serverReachable = serverReachable
        self.lastProbe = lastProbe
    }

    /// Decoded key by key rather than with the synthesised initialiser: while developing, a rebuilt app can poll an
    /// extension that is still running older code, and one missing key would throw and blank the whole dashboard.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        up = try c.decodeIfPresent(Int.self, forKey: .up) ?? 0
        down = try c.decodeIfPresent(Int.self, forKey: .down) ?? 0
        pktUp = try c.decodeIfPresent(Int.self, forKey: .pktUp) ?? 0
        pktDown = try c.decodeIfPresent(Int.self, forKey: .pktDown) ?? 0
        footprintMB = try c.decodeIfPresent(Double.self, forKey: .footprintMB) ?? 0
        connectedSince = try c.decodeIfPresent(Double.self, forKey: .connectedSince) ?? 0
        serverReachable = try c.decodeIfPresent(Bool.self, forKey: .serverReachable)
        lastProbe = try c.decodeIfPresent(Double.self, forKey: .lastProbe) ?? 0
    }
}
