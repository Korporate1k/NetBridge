import Darwin
import Foundation
import tun2proxy

/// Wraps the tun2proxy engine (Rust, ipstack-based tun2socks — see
/// `Package.swift`): a self-contained "raw IP packets in -> SOCKS5 flows out"
/// relay. TCP goes out via SOCKS5 CONNECT, UDP via standard SOCKS5 UDP
/// ASSOCIATE, and DNS is answered locally from a virtual-IP pool
/// (`--dns virtual`) so hostnames reach the proxy unresolved — no DNS leak.
/// Handles IPv4 and IPv6.
///
/// Packets cross into the engine over an `AF_UNIX SOCK_DGRAM` socketpair: one
/// end is handed to tun2proxy as `--tun-fd`, the other is read/written here,
/// each datagram prefixed with the 4-byte big-endian protocol family
/// (`AF_INET`/`AF_INET6`) that tun2proxy's `packet_information` mode expects.
public final class TunnelEngine {
    /// The tun interface's own addresses — the `NEIPv4Settings` /
    /// `NEIPv6Settings` the `PacketTunnelProvider` installs.
    public static let tunnelLocalAddress = "10.0.0.2"
    public static let tunnelLocalAddressV6 = "fd00:7470::2"
    private static let tunnelMTU: UInt16 = 1500

    /// Concurrent TCP+UDP sessions the engine will track (`--max-sessions`; tun2proxy's own default is 200). Past the
    /// cap it silently drops packets of NEW flows ("Too many sessions ... dropping new session"), so the cap is also
    /// what protects the extension's ~50 MB memory limit (iOS kills the whole VPN past it) — raise it only to a
    /// measured value. Measured on an iPhone 15 Plus, extension memory: ≈3.9 MB baseline; worst case = sessions opened in
    /// a BURST, ≈43 KB each (900 = 42.5 MB, 700 = 33.9 MB, 500 = 25.3 MB, TCP ≈35 KB); 600 held UDP sessions + a 19 Mbit/s
    /// stream + 16 bulk TCP streams = 29.9 MB (traffic adds almost nothing). Independently, the engine stopped creating
    /// sessions at ≈1200 while memory sat at 37 MB — a limit that is not memory. iOS kills the whole VPN extension if it
    /// exceeds its memory ceiling (≈50 MB documented; never reached in testing, max seen 42.5 MB), which is far worse than
    /// dropping new flows, so: 800 keeps the worst measured case at ≈38 MB (≈23% margin) and ≈33% below the ≈1200
    /// session ceiling. 900 also worked in testing but leaves ≈15% margin — change this one constant to use it.
    public static let defaultMaxSessions = 800
    /// Idle time after which a UDP session is torn down (`--udp-timeout`; tun2proxy's default is 10). A new packet
    /// after that opens a NEW session, which the SOCKS5 relay sees as a new association with a new external port,
    /// so 10 s broke anything keyed on the source port (games, TURN, SIP) unless it sent keepalives more often than
    /// that. 120 s (the RFC 4787 minimum for NAT UDP mappings) covers the common 25–30 s keepalive intervals with a
    /// large cushion. KNOWN LIMIT of the vendored engine: its virtual-DNS name→fake-address mapping expires 60 s after the
    /// last lookup/new-session and is purged by the next DNS lookup from any app; a flow that resumes AFTER its session
    /// ended (idle longer than this timeout) may then be forwarded to the raw fake 198.18.x.x address and go nowhere.
    /// A longer timeout keeps sessions alive through longer pauses, so it shrinks how often that can happen.
    public static let defaultUDPTimeoutSeconds = 120

    /// Outbound packets the engine wants delivered back into the tunnel
    /// (i.e. handed to `NEPacketTunnelFlow.writePackets`), with their protocol
    /// family. Fired synchronously on the engine's dedicated read thread,
    /// inside a per-packet autorelease pool.
    public var onPacketToWrite: ((Data, Int32) -> Void)?

    /// Optional diagnostics sink (e.g. the extension's shared-group file log).
    /// Also receives the engine's own log output.
    public var logHandler: ((String) -> Void)?

    /// The single engine currently feeding the C log callback, which is a
    /// plain `void (*)(...)` and cannot capture Swift context.
    private static var active: TunnelEngine?

    private let proxyHost: String
    private let proxyPort: UInt16
    private let username: String?
    private let password: String?
    private let maxSessions: Int
    private let udpTimeoutSeconds: Int

    private var appFd: Int32 = -1
    private var worker: Thread?
    private var reader: Thread?
    private var started = false
    private var stopped = false

    public init(proxyHost: String, proxyPort: UInt16, username: String? = nil, password: String? = nil,
                maxSessions: Int = TunnelEngine.defaultMaxSessions,
                udpTimeoutSeconds: Int = TunnelEngine.defaultUDPTimeoutSeconds) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.username = username
        self.password = password
        // Clamped: these become command-line numbers, and clap exit()s the whole extension on a parse error.
        self.maxSessions = max(1, maxSessions)
        self.udpTimeoutSeconds = max(1, udpTimeoutSeconds)
    }

    /// Starts the engine and the tunnel-bound read loop on dedicated
    /// background threads. Idempotent.
    public func start() {
        guard !started else { return }
        started = true

        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            logHandler?("socketpair() failed errno=\(errno)")
            return
        }
        let tunFd = fds[0]  // owned by tun2proxy (--close-fd-on-drop true)
        appFd = fds[1]

        // The default buffers on a connected AF_UNIX SOCK_DGRAM pair are only
        // a few KB; a real page-load burst overflows them and Darwin resets
        // the pair (ECONNRESET on both ends) instead of backpressuring.
        var bufSize: Int32 = 1 << 20
        for fd in [tunFd, appFd] {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        }

        TunnelEngine.active = self
        tun2proxy_set_log_callback({ _, msg, _ in
            guard let msg else { return }
            TunnelEngine.active?.logHandler?("[engine] \(String(cString: msg))")
        }, nil)

        // clap parses this like a real argv: the first token is consumed as
        // the program name. Without the leading "tun2proxy", the real first
        // flag is swallowed, the parse fails, and clap calls exit() — killing
        // the whole extension process with no crash log.
        let cli = "tun2proxy --tun-fd \(tunFd) --close-fd-on-drop true --proxy \(proxyURL(redacted: false)) --dns virtual --max-sessions \(maxSessions) --udp-timeout \(udpTimeoutSeconds) --verbosity info"
        logHandler?("tun2proxy starting: " + cli.replacingOccurrences(of: proxyURL(redacted: false), with: proxyURL(redacted: true)))

        let worker = Thread { [weak self] in
            let rc = cli.withCString { tun2proxy_run_with_cli_args($0, Self.tunnelMTU, true) }
            self?.logHandler?("tun2proxy engine returned rc=\(rc)")
        }
        worker.name = "com.Korporate1k.LocalProxy.tun2proxy"
        worker.qualityOfService = .userInitiated
        self.worker = worker
        worker.start()

        let reader = Thread { [weak self] in self?.readLoop() }
        reader.name = "com.Korporate1k.LocalProxy.tun2proxy.read"
        reader.qualityOfService = .userInitiated
        self.reader = reader
        reader.start()
    }

    /// Stops the engine (returns `tun2proxy_run_with_cli_args` on its worker
    /// thread) and ends the read loop.
    public func stop() {
        guard started, !stopped else { return }
        stopped = true
        tun2proxy_stop()
        if appFd >= 0 {
            shutdown(appFd, SHUT_RDWR)  // unblocks the reader's recv()
            close(appFd)
            appFd = -1
        }
        if TunnelEngine.active === self { TunnelEngine.active = nil }
    }

    /// Feed one raw IP packet read from the tunnel (i.e. from an on-device
    /// app, outbound) into the engine.
    public func consumeInboundPacket(_ data: Data, family: Int32) {
        let fd = appFd
        guard fd >= 0, !stopped, !data.isEmpty else { return }
        let f = UInt32(bitPattern: family)
        var out = Data([UInt8(f >> 24 & 0xFF), UInt8(f >> 16 & 0xFF), UInt8(f >> 8 & 0xFF), UInt8(f & 0xFF)])
        out.append(data)
        out.withUnsafeBytes { raw in
            _ = send(fd, raw.baseAddress, raw.count, 0)
        }
    }

    /// Engine -> tunnel. Runs for the tunnel's whole lifetime on its own
    /// thread, so it never returns to a run loop or GCD that would drain an
    /// autorelease pool for it. `writePackets` bridges each packet to
    /// autoreleased NSData/NSArray/NSNumber; without the per-packet pool below,
    /// every packet ever received stays resident — memory grows ~1:1 with
    /// bytes downloaded until jetsam's 50MB packet-tunnel ceiling SIGKILLs the
    /// extension (reproduced and fixed in ~/Desktop/tun2proxy-test).
    private func readLoop() {
        let fd = appFd
        var buf = [UInt8](repeating: 0, count: Int(Self.tunnelMTU) + 64)
        let bufLen = buf.count
        while !stopped {
            let keepGoing: Bool = autoreleasepool {
                let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, bufLen, 0) }
                if n <= 0 {
                    // 0 = engine closed its end; -1 = error or stop(). Either
                    // way, exit rather than busy-loop at 100% CPU (which the
                    // CPU-resource watchdog would kill).
                    if !stopped { logHandler?("read loop: recv returned \(n) errno=\(errno), stopping") }
                    return false
                }
                guard n > 4 else { return true }
                let family = Int32(bitPattern: UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3]))
                onPacketToWrite?(Data(buf[4..<n]), family)
                return true
            }
            if !keepGoing { break }
        }
    }

    /// `socks5://[user:pass@]host:port`, credentials percent-encoded (tun2proxy
    /// percent-decodes them and performs the RFC 1929 sub-negotiation).
    private func proxyURL(redacted: Bool) -> String {
        let hostPart = proxyHost.contains(":") ? "[\(proxyHost)]" : proxyHost
        var auth = ""
        if let username, !username.isEmpty {
            let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let user = username.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            let pass = redacted ? "***" : ((password ?? "").addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
            auth = "\(user):\(pass)@"
        }
        return "socks5://\(auth)\(hostPart):\(proxyPort)"
    }
}
