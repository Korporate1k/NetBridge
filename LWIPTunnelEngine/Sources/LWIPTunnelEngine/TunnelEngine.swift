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
    /// measured value. Measured on an iPhone 15 Plus, extension memory: ≈3.9 MB baseline; ≈25 KB per idle UDP session and
    /// ≈47 KB once a session has carried traffic (TCP ≈35 KB): 976 sessions after two rounds of traffic = 45.6 MB (the
    /// worst case measured), 900 held sessions + a 19 Mbit/s stream + 16 bulk TCP streams = 42.8 MB, 600 = 29.9 MB.
    /// TWO independent ceilings: (1) memory — iOS kills the whole VPN extension past ≈50 MB (documented; never reached,
    /// max seen 45.6 MB, so 1000 leaves only ≈9% margin — thin: anything much heavier than the tested worst case is
    /// close to the line); (2) file descriptors — the extension's RLIMIT_NOFILE soft limit is 2560 and each UDP session
    /// holds 2 (976 sessions = 1974 fds), so ≈1200 UDP sessions is a hard ceiling that no cap can exceed. Saturation is
    /// disruptive: the engine checks this cap BEFORE it handles DNS, so once full it drops new flows, including DNS
    /// lookups, until idle sessions expire (UDP: `defaultUDPTimeoutSeconds`; TCP: 600 s). 1000 was chosen by the owner
    /// over the more conservative 800 (≈38 MB, ≈23% margin) to make saturation rarer; lower this constant to trade that
    /// back for memory margin.
    public static let defaultMaxSessions = 1000
    /// Idle time after which a UDP session is torn down (`--udp-timeout`; tun2proxy's default is 10). A new packet
    /// after that opens a NEW session, which the SOCKS5 relay sees as a new association with a new external port,
    /// so 10 s broke anything keyed on the source port (games, TURN, SIP) unless it sent keepalives more often than
    /// that. 120 s (the RFC 4787 minimum for NAT UDP mappings) covers the common 25–30 s keepalive intervals with a
    /// large cushion. KNOWN LIMIT of the vendored engine: its virtual-DNS name→fake-address mapping expires 60 s after the
    /// last lookup/new-session and is purged by the next DNS lookup from any app; a flow that resumes AFTER its session
    /// ended (idle longer than this timeout) may then be forwarded to the raw fake 198.18.x.x address and go nowhere.
    /// A longer timeout keeps sessions alive through longer pauses, so it shrinks how often that can happen.
    public static let defaultUDPTimeoutSeconds = 120

    /// Engine log level (`--verbosity`). Every line the engine emits crosses into Swift on a tokio worker thread
    /// and is written to a file synchronously under a shared lock, so `info` — which logs the start and end of
    /// every single flow, thousands of lines a minute — puts real work on the packet path. `warn` is the shipping
    /// default; QA can raise it per-session with the `verbosity` key in `providerConfiguration`.
    public static let defaultVerbosity = "warn"
    public static let allowedVerbosities = ["off", "error", "warn", "info", "debug", "trace"]

    /// Outbound packets the engine wants delivered back into the tunnel
    /// (i.e. handed to `NEPacketTunnelFlow.writePackets`), with their protocol
    /// family. Fired synchronously on the engine's dedicated read thread,
    /// inside a per-packet autorelease pool.
    /// Delivered in batches (up to `maxBatch` packets that were already queued), so the reader keeps pace with the
    /// engine: one `writePackets` call per packet made the app-side reader the bottleneck during connection bursts,
    /// and a backed-up socketpair is where Darwin starts failing the engine's writes.
    public var onPacketsToWrite: (([Data], [Int32]) -> Void)?

    /// Called (on the engine's worker thread) if the engine stops on its own — i.e. not via `stop()`. tun2proxy
    /// force-exits the whole process a couple of seconds after this, so the owner should report the failure
    /// (`cancelTunnelWithError`) while it still can.
    public var onEngineExit: ((Int32) -> Void)?

    private static let maxBatch = 64

    /// Optional diagnostics sink (e.g. the extension's shared-group file log).
    /// Also receives the engine's own log output.
    public var logHandler: ((String) -> Void)?

    /// The single engine currently feeding the C log callback, which is a plain `void (*)(...)` and cannot
    /// capture Swift context. The callback fires on the engine's tokio worker threads while `start`/`stop` run on
    /// others, so this needs a lock of its own: an unsynchronised read/write of a class reference is an ARC race,
    /// and the log callback is never uninstalled, so a late line can arrive during teardown.
    private static let activeLock = NSLock()
    private static var _active: TunnelEngine?

    private static var active: TunnelEngine? {
        activeLock.lock()
        defer { activeLock.unlock() }
        return _active
    }

    private static func setActive(_ engine: TunnelEngine?) {
        activeLock.lock()
        _active = engine
        activeLock.unlock()
    }

    /// Clears `active` only if it is still `engine` — as one atomic step, so a newer engine's registration is
    /// never wiped by an older one's `stop()`.
    private static func clearActive(ifSameAs engine: TunnelEngine) {
        activeLock.lock()
        if _active === engine { _active = nil }
        activeLock.unlock()
    }

    private let proxyHost: String
    private let proxyPort: UInt16
    private let username: String?
    private let password: String?
    private let maxSessions: Int
    private let udpTimeoutSeconds: Int

    private let verbosity: String

    /// `appFd`, `started` and `stopped` are touched by three threads — the caller of `start()`/`stop()`, the
    /// engine's worker thread and the read loop — so every access goes through `stateLock`. Without it a `stop()`
    /// racing the engine's return could fire `onEngineExit` for a deliberate teardown, which the Mac app would
    /// then treat as a crash and reconnect.
    private let stateLock = NSLock()
    private var appFd: Int32 = -1
    private var worker: Thread?
    private var reader: Thread?
    private var started = false
    private var stopped = false

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    public init(proxyHost: String, proxyPort: UInt16, username: String? = nil, password: String? = nil,
                maxSessions: Int = TunnelEngine.defaultMaxSessions,
                udpTimeoutSeconds: Int = TunnelEngine.defaultUDPTimeoutSeconds,
                verbosity: String = TunnelEngine.defaultVerbosity) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.username = username
        self.password = password
        // Clamped: these become command-line numbers, and clap exit()s the whole extension on a parse error.
        self.maxSessions = max(1, maxSessions)
        self.udpTimeoutSeconds = max(1, udpTimeoutSeconds)
        // Same reason: an unrecognised level would make clap exit() and take the extension with it.
        self.verbosity = Self.allowedVerbosities.contains(verbosity) ? verbosity : Self.defaultVerbosity
    }

    /// Starts the engine and the tunnel-bound read loop on dedicated
    /// background threads. Idempotent.
    public func start() {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()

        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            logHandler?("socketpair() failed errno=\(errno)")
            return
        }
        let tunFd = fds[0]  // owned by tun2proxy (--close-fd-on-drop true)
        let app = fds[1]
        stateLock.lock()
        appFd = app
        stateLock.unlock()

        // The default buffers on a connected AF_UNIX SOCK_DGRAM pair are only
        // a few KB; a real page-load burst overflows them and Darwin resets
        // the pair (ECONNRESET on both ends) instead of backpressuring.
        //
        // What happens at the limit (measured on macOS with a nonblocking writer and no reader): the writer's send()
        // fails with ENOBUFS — not EAGAIN, so tokio never treats it as "try again later" — after ~689 full-size
        // datagrams per MB of buffer, and recovers as soon as the reader takes one. Before patch 0004 a single such
        // failure ended the engine and, via tun2proxy's forced exit, the whole VPN. On macOS the extension has no
        // 50 MB jetsam ceiling, so take 4 MB (≈2,700 datagrams of headroom); iOS keeps 1 MB.
        #if os(macOS)
        var bufSize: Int32 = 4 << 20
        #else
        var bufSize: Int32 = 1 << 20
        #endif
        for fd in [tunFd, app] {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        }

        TunnelEngine.setActive(self)
        tun2proxy_set_log_callback({ _, msg, _ in
            guard let msg else { return }
            TunnelEngine.active?.logHandler?("[engine] \(String(cString: msg))")
        }, nil)

        // clap parses this like a real argv: the first token is consumed as
        // the program name. Without the leading "tun2proxy", the real first
        // flag is swallowed, the parse fails, and clap calls exit() — killing
        // the whole extension process with no crash log.
        let cli = "tun2proxy --tun-fd \(tunFd) --close-fd-on-drop true --proxy \(proxyURL(redacted: false)) --dns virtual --max-sessions \(maxSessions) --udp-timeout \(udpTimeoutSeconds) --verbosity \(verbosity)"
        logHandler?("tun2proxy starting: " + cli.replacingOccurrences(of: proxyURL(redacted: false), with: proxyURL(redacted: true)))

        let worker = Thread { [weak self] in
            let rc = cli.withCString { tun2proxy_run_with_cli_args($0, Self.tunnelMTU, true) }
            guard let self else { return }
            self.logHandler?("tun2proxy engine returned rc=\(rc)")
            // Read the handler and the stopped flag together, so a concurrent stop() either wins outright (handler
            // already nil'd, nothing fires) or loses outright (fires once). `stop()` nils it under the same lock.
            self.stateLock.lock()
            let handler = self.stopped ? nil : self.onEngineExit
            self.stateLock.unlock()
            handler?(rc)
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
        stateLock.lock()
        guard started, !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        // Cleared under the same lock the worker reads it under: once stop() has begun, the engine returning is a
        // deliberate teardown and must not be reported as a crash.
        onEngineExit = nil
        let fd = appFd
        appFd = -1
        stateLock.unlock()

        tun2proxy_stop()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)  // unblocks the reader's recv()
            close(fd)
        }
        TunnelEngine.clearActive(ifSameAs: self)
    }

    /// Feed one raw IP packet read from the tunnel (i.e. from an on-device
    /// app, outbound) into the engine.
    public func consumeInboundPacket(_ data: Data, family: Int32) {
        stateLock.lock()
        let fd = stopped ? -1 : appFd
        stateLock.unlock()
        guard fd >= 0, !data.isEmpty else { return }
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
        stateLock.lock()
        let fd = appFd
        stateLock.unlock()
        var buf = [UInt8](repeating: 0, count: Int(Self.tunnelMTU) + 64)
        let bufLen = buf.count
        while !isStopped {
            let keepGoing: Bool = autoreleasepool {
                let batch = Self.readBatch(fd: fd, buf: &buf, maxBatch: Self.maxBatch)
                if !batch.packets.isEmpty { onPacketsToWrite?(batch.packets, batch.families) }
                if !batch.keepGoing, !isStopped {
                    logHandler?("read loop: recv returned \(batch.endReason ?? "?"), stopping")
                }
                return batch.keepGoing
            }
            if !keepGoing { break }
        }
    }

    /// One batch of packets from the engine: blocks for the first datagram, then takes only what is already
    /// queued. Split out of `readLoop` so it can be exercised over a plain socketpair in tests without starting
    /// the engine (see `TunnelEngineTests`).
    struct ReadBatch {
        var packets: [Data] = []
        var families: [Int32] = []
        /// False once the socket is finished (peer closed, or an error that is not EINTR/EAGAIN).
        var keepGoing = true
        /// Populated only when `keepGoing` is false.
        var endReason: String?
    }

    static func readBatch(fd: Int32, buf: inout [UInt8], maxBatch: Int) -> ReadBatch {
        var out = ReadBatch()
        let bufLen = buf.count
        var flags: Int32 = 0  // the first recv blocks; the rest only take what is already queued
        // `iterations` bounds the loop independently of `packets.count`: the EINTR and
        // too-short-to-be-a-packet paths below consume an iteration without producing a packet, and a
        // persistent one of those would otherwise spin here forever.
        var iterations = 0
        while out.packets.count < maxBatch, iterations < maxBatch * 4 {
            iterations += 1
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, bufLen, flags) }
            let err = errno
            if n <= 0 {
                if n < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
                    if flags != 0 { break }  // queue drained: the rest of the batch simply isn't there yet
                    // Defensive: the app fd is blocking today, so a first-recv EAGAIN should be impossible. If it
                    // ever becomes non-blocking, "no data yet" must not be mistaken for the end of the tunnel —
                    // yield and retry instead (bounded by `iterations`, so this cannot spin hot).
                    usleep(1000)
                    continue
                }
                if n < 0 && err == EINTR { continue }
                // 0 = engine closed its end; -1 = error or stop(). Either way, stop rather than busy-loop at
                // 100% CPU (which the CPU-resource watchdog would kill).
                out.keepGoing = false
                out.endReason = "\(n) errno=\(err)"
                return out
            }
            flags = MSG_DONTWAIT
            guard n > 4 else { continue }
            out.families.append(Int32(bitPattern: UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3])))
            out.packets.append(Data(buf[4..<n]))
        }
        return out
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
