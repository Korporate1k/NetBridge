import Foundation
import Network
import Darwin

/// One SOCKS5 `UDP ASSOCIATE` session: an ephemeral UDP listener receives
/// wrapped datagrams from the SOCKS5 client, relays each one's payload to
/// whatever destination it names, and wraps replies the same way on the way
/// back. Owned by the `Tunnel` whose SOCKS5 request created it — its lifetime
/// is tied to that tunnel's TCP control connection per RFC 1928, so
/// `Tunnel.cleanup()` cancels it directly rather than `ProxyServer` tracking it
/// separately.
///
/// Destination side (full-cone NAT behaviour): all outbound traffic leaves
/// through ONE unconnected BSD UDP socket per address family (`EgressSocket`),
/// so the association has a single, stable external `ip:port` regardless of how
/// many destinations the client talks to, and datagrams that arrive on it from
/// ANY remote address are relayed back to the client, each tagged with its real
/// source (RFC 1928 §7). That is what DNS servers that answer from a different
/// IP, STUN and peer-to-peer hole punching need. The previous design used one
/// connected `NWConnection` per destination, which the OS filters to that exact
/// remote `ip:port` and which gives every destination a different external port.
///
/// Trade-off: anyone who learns the egress port can send datagrams to the
/// client for as long as the association lives. The port is ephemeral and dies
/// with the SOCKS5 control connection.
final class UDPRelay {
    let id: Int
    private let queue: DispatchQueue
    private let stats: ProxyStats

    private var listener: NWListener?
    private var clientConnection: NWConnection?
    private var cancelled = false
    private var didOpenStats = false

    // MARK: Destination side

    private var egress4: EgressSocket?
    private var egress6: EgressSocket?
    private var destinationsSeen: Set<String> = []

    /// Hostname destinations (ATYP 3) are resolved off-queue with
    /// `getaddrinfo`; datagrams that arrive while a lookup is in flight wait in
    /// `pendingResolution` (capped) and results are cached briefly.
    private var resolved: [String: (address: sockaddr_storage, expires: DispatchTime)] = [:]
    private var pendingResolution: [String: [(payload: Data, port: UInt16)]] = [:]
    private static let resolutionTTLSeconds = 60.0
    private static let maxPendingPerName = 32

    /// Per-`NWConnection` outbound send queue for the CLIENT connection (fixed
    /// key). Necessary because firing multiple `NWConnection.send()` calls back
    /// to back on the same UDP connection, before earlier ones complete, does
    /// not queue reliably — measured directly: a rapid burst of datagrams to
    /// one peer delivered only 1 of 8 replies, consistently. Serializing sends
    /// (never gating reads on it) fixed it. Destination sends do not need this:
    /// `sendto()` on a non-blocking socket hands the datagram to the kernel
    /// synchronously.
    private var pendingSends: [String: [Data]] = [:]
    private var sendInFlight: Set<String> = []
    private static let clientSendKey = "\u{0}client"

    // MARK: Throughput diagnostics (all mutated on `queue`)

    private var bytesUp: UInt64 = 0
    private var bytesDown: UInt64 = 0
    private var datagramsUp = 0
    private var datagramsDown = 0
    private var sendDrops = 0
    private var beatBytesUp: UInt64 = 0
    private var beatBytesDown: UInt64 = 0
    private var lastDataAt = DispatchTime.now()
    private var heartbeat: DispatchSourceTimer?
    private var stalled = false
    private var clientTransferReport: NWConnection.PendingDataTransferReport?
    private static let stallThresholdMs = 2000.0

    init(id: Int, queue: DispatchQueue, stats: ProxyStats) {
        self.id = id
        self.queue = queue
        self.stats = stats
    }

    /// Starts the ephemeral listener; reports `(host, port)` once ready for
    /// the SOCKS5 UDP ASSOCIATE success reply, or `(nil, nil)` on failure.
    func start(completion: @escaping (String?, UInt16?) -> Void) {
        do {
            let listener = try NWListener(using: .udp)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptFromClient(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    let port = listener.port.map { UInt16($0.rawValue) }
                    let host = LocalAddress.primaryIPv4() ?? "0.0.0.0"
                    DebugLog.important("udp", tunnel: self.id, "UDP ASSOCIATE relay ready on \(host):\(port.map { String($0) } ?? "?")")
                    self.didOpenStats = true
                    self.stats.connectionOpened()
                    self.startHeartbeat()
                    completion(host, port)
                case .failed(let error):
                    DebugLog.important("udp", tunnel: self.id, "UDP ASSOCIATE relay listener FAILED \(ErrorDescription.describe(error))")
                    completion(nil, nil)
                    self.cancel()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            DebugLog.important("udp", tunnel: id, "UDP ASSOCIATE relay listener init threw \(ErrorDescription.describe(error))")
            completion(nil, nil)
        }
    }

    // MARK: - Client side (one relay serves exactly one client, learned from its first datagram)

    private func acceptFromClient(_ connection: NWConnection) {
        guard clientConnection == nil else {
            DebugLog.important("udp", tunnel: id, "UDP ASSOCIATE relay ignoring unexpected sender \(EndpointDescription.describe(connection.endpoint))")
            connection.cancel()
            return
        }
        DebugLog.important("udp", tunnel: id, "UDP ASSOCIATE relay client bound to \(EndpointDescription.describe(connection.endpoint))")
        clientConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .failed(let error) = state {
                DebugLog.important("udp", tunnel: self.id, "UDP ASSOCIATE client connection FAILED \(ErrorDescription.describe(error))")
                self.cancel()
            }
        }
        connection.start(queue: queue)
        clientTransferReport = connection.startDataTransferReport()
        receiveFromClient(connection)
    }

    /// Unlike the TCP relay's `forward(from:to:isUpstream:)`, this does NOT
    /// gate the next read on the relayed send completing. Measured directly:
    /// doing so (an earlier version of this method did) dropped most of a
    /// rapid back-to-back burst of datagrams — while `receiveMessage()` sits
    /// unarmed waiting for an outbound send to finish, arriving datagrams are
    /// not queued the way TCP's kernel receive buffer queues bytes; they're
    /// simply lost. Always re-arming immediately is also the semantically
    /// correct choice for UDP: unlike TCP backpressure (which prevents
    /// unbounded buffering, not data loss), gating reads behind writes here
    /// actively causes loss for a protocol where dropping under real overload
    /// is already expected/tolerated by every caller.
    private func receiveFromClient(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, !self.cancelled else { return }
            guard error == nil else {
                DebugLog.important("udp", tunnel: self.id, "UDP ASSOCIATE client receive error \(ErrorDescription.describe(error))")
                self.cancel()
                return
            }
            guard let data = data, !data.isEmpty else {
                self.receiveFromClient(connection)
                return
            }
            switch Socks5.parseUDPDatagram(data) {
            case .invalid:
                DebugLog.debug("udp", tunnel: self.id, "dropped unparseable UDP datagram from client, \(data.count) bytes")
            case .parsed(let host, let port, let payload):
                self.relay(payload: payload, to: host, port: port)
            }
            self.receiveFromClient(connection)
        }
    }

    // MARK: - Destination side (shared unconnected sockets, any-source replies)

    private func relay(payload: Data, to host: String, port: UInt16) {
        if let address = EgressSocket.literalAddress(host: host, port: port) {
            send(payload, to: address, label: "\(host):\(port)")
            return
        }
        // Hostname (ATYP 3): resolve, then send.
        let name = host.lowercased()
        if let cached = resolved[name], cached.expires > DispatchTime.now() {
            send(payload, to: EgressSocket.withPort(cached.address, port), label: "\(host):\(port)")
            return
        }
        if pendingResolution[name] != nil {
            if pendingResolution[name]!.count < Self.maxPendingPerName {
                pendingResolution[name]!.append((payload, port))
            } else {
                sendDrops += 1
            }
            return
        }
        pendingResolution[name] = [(payload, port)]
        let tunnelID = id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let address = EgressSocket.resolve(name)
            self?.queue.async {
                guard let self = self, !self.cancelled else { return }
                let waiting = self.pendingResolution.removeValue(forKey: name) ?? []
                guard let address = address else {
                    DebugLog.debug("udp", tunnel: tunnelID, "UDP ASSOCIATE could not resolve \(name), dropped \(waiting.count) datagram(s)")
                    self.sendDrops += waiting.count
                    return
                }
                self.resolved[name] = (address, DispatchTime.now() + Self.resolutionTTLSeconds)
                for item in waiting {
                    self.send(item.payload, to: EgressSocket.withPort(address, item.port), label: "\(name):\(item.port)")
                }
            }
        }
    }

    private func send(_ payload: Data, to address: sockaddr_storage, label: String) {
        guard let egress = egressSocket(for: Int32(address.ss_family)) else {
            sendDrops += 1
            return
        }
        let error = egress.send(payload, to: address)
        if error != 0 {
            sendDrops += 1
            DebugLog.debug("udp", tunnel: id, "UDP ASSOCIATE send to \(label) failed errno=\(error) (\(String(cString: strerror(error))))")
            return
        }
        destinationsSeen.insert(label)
        stats.addBytesUp(payload.count)
        bytesUp += UInt64(payload.count)
        datagramsUp += 1
        lastDataAt = DispatchTime.now()
    }

    private func egressSocket(for family: Int32) -> EgressSocket? {
        if family == AF_INET, let existing = egress4 { return existing }
        if family == AF_INET6, let existing = egress6 { return existing }
        guard family == AF_INET || family == AF_INET6 else { return nil }
        let socket = EgressSocket(family: family, queue: queue) { [weak self] data, host, port in
            self?.receivedFromRemote(data, host: host, port: port)
        }
        guard let socket = socket else {
            DebugLog.important("udp", tunnel: id, "UDP ASSOCIATE could not create \(family == AF_INET ? "IPv4" : "IPv6") egress socket errno=\(errno)")
            return nil
        }
        DebugLog.important("udp", tunnel: id, "UDP ASSOCIATE \(family == AF_INET ? "IPv4" : "IPv6") egress socket bound to local port \(socket.localPort)")
        if family == AF_INET { egress4 = socket } else { egress6 = socket }
        return socket
    }

    /// A datagram arrived on an egress socket from `host:port` — any remote,
    /// not only ones the client has sent to (full cone).
    private func receivedFromRemote(_ data: Data, host: String, port: UInt16) {
        guard !cancelled, !data.isEmpty, let client = clientConnection else { return }
        stats.addBytesDown(data.count)
        bytesDown += UInt64(data.count)
        datagramsDown += 1
        lastDataAt = DispatchTime.now()
        let wrapped = Socks5.buildUDPDatagram(host: host, port: port, payload: data)
        enqueueSend(wrapped, on: client, key: Self.clientSendKey)
    }

    // MARK: - Client-connection outbound send serialization

    private func enqueueSend(_ payload: Data, on connection: NWConnection, key: String) {
        pendingSends[key, default: []].append(payload)
        sendNext(on: connection, key: key)
    }

    private func sendNext(on connection: NWConnection, key: String) {
        guard !sendInFlight.contains(key) else { return }
        guard var queued = pendingSends[key], !queued.isEmpty else { return }
        let payload = queued.removeFirst()
        pendingSends[key] = queued
        sendInFlight.insert(key)
        let tunnelID = id
        connection.send(content: payload, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DebugLog.debug("udp", tunnel: tunnelID, "UDP ASSOCIATE send to client error \(ErrorDescription.describe(error))")
            }
            self.sendInFlight.remove(key)
            self.sendNext(on: connection, key: key)
        })
    }

    // MARK: - Heartbeat / stall detection (mirrors Tunnel.startHeartbeat, one aggregate line for the whole
    // relay rather than per-destination — a relay can fan out to several destinations, e.g. DNS + QUIC +
    // game traffic, and per-destination heartbeats would multiply 1Hz log volume by destination count
    // for little value versus one summed line).

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let deltaUp = self.bytesUp - self.beatBytesUp
            let deltaDown = self.bytesDown - self.beatBytesDown
            self.beatBytesUp = self.bytesUp
            self.beatBytesDown = self.bytesDown
            let idleMs = Double(DispatchTime.now().uptimeNanoseconds - self.lastDataAt.uptimeNanoseconds) / 1_000_000
            let pending = self.pendingSends.values.reduce(0) { $0 + $1.count }
            DebugLog.debug("udp", tunnel: self.id, "heartbeat +up=\(deltaUp)B/s +down=\(deltaDown)B/s total up=\(self.bytesUp) down=\(self.bytesDown) datagrams up=\(self.datagramsUp) down=\(self.datagramsDown) destinations=\(self.destinationsSeen.count) sendDrops=\(self.sendDrops) pendingSends=\(pending) sendsInFlight=\(self.sendInFlight.count) idle=\(String(format: "%.0f", idleMs))ms")
            if idleMs > Self.stallThresholdMs && !self.stalled {
                self.stalled = true
                DebugLog.important("udp", tunnel: self.id, "STALL no datagrams either direction for \(String(format: "%.0f", idleMs))ms destinations=\(self.destinationsSeen.count) pendingSends=\(pending)")
            } else if idleMs <= Self.stallThresholdMs && self.stalled {
                self.stalled = false
                DebugLog.important("udp", tunnel: self.id, "stall cleared")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - Teardown

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        heartbeat?.cancel()
        heartbeat = nil
        DebugLog.important("udp", tunnel: id, "UDP ASSOCIATE relay closed, \(destinationsSeen.count) destination(s) up=\(bytesUp)B/\(datagramsUp)dgrams down=\(bytesDown)B/\(datagramsDown)dgrams sendDrops=\(sendDrops)")
        if let report = clientTransferReport {
            let tunnelID = id
            report.collect(queue: queue) { report in
                DebugLog.important("udp", tunnel: tunnelID, "client transfer report \(TransferReportDescription.describe(report))")
            }
            clientTransferReport = nil
        }
        listener?.cancel()
        clientConnection?.cancel()
        egress4?.close()
        egress6?.close()
        egress4 = nil
        egress6 = nil
        resolved.removeAll()
        pendingResolution.removeAll()
        pendingSends.removeAll()
        sendInFlight.removeAll()
        if didOpenStats {
            didOpenStats = false
            stats.connectionClosed()
        }
    }
}

// MARK: - EgressSocket

/// One unconnected, non-blocking BSD UDP socket (wildcard-bound, ephemeral
/// port) with a dispatch read source. `sendto()` targets any destination and
/// `recvfrom()` accepts datagrams from any source — the pieces Network.framework
/// does not expose for UDP. Carries the same egress hop limit as the rest of
/// the relay (`EgressTTL.hopLimit`).
private final class EgressSocket {
    private let fd: Int32
    private let source: DispatchSourceRead
    let localPort: UInt16

    private static let bufferSize = 65536
    private static let maxDatagramsPerWakeup = 64

    /// `onDatagram(payload, sourceHost, sourcePort)` runs on `queue`.
    init?(family: Int32, queue: DispatchQueue, onDatagram: @escaping (Data, String, UInt16) -> Void) {
        let fd = socket(family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }

        var on: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, intSize)
        }
        var hops = Int32(EgressTTL.hopLimit)
        if family == AF_INET {
            // Without SO_BROADCAST, sendto() to a broadcast address fails with EACCES.
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, intSize)
            setsockopt(fd, IPPROTO_IP, IP_TTL, &hops, intSize)
        } else {
            setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &hops, intSize)
        }
        var bufBytes: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufBytes, intSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufBytes, intSize)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var bound = sockaddr_storage()
        let boundLen: socklen_t
        if family == AF_INET {
            withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    $0.pointee.sin_family = sa_family_t(AF_INET)
                }
            }
            boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        } else {
            withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    $0.pointee.sin6_family = sa_family_t(AF_INET6)
                }
            }
            boundLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        }
        let bindResult = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, boundLen) }
        }
        guard bindResult == 0 else {
            let saved = errno
            Darwin.close(fd)
            errno = saved
            return nil
        }

        var actual = sockaddr_storage()
        var actualLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLen) }
        }
        self.localPort = EgressSocket.decode(actual)?.port ?? 0

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: EgressSocket.bufferSize, alignment: 1)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var handled = 0
            while handled < EgressSocket.maxDatagramsPerWakeup {
                var from = sockaddr_storage()
                var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buffer, EgressSocket.bufferSize, 0, $0, &fromLen)
                    }
                }
                if n < 0 { break }   // EWOULDBLOCK: drained
                handled += 1
                guard let (host, port) = EgressSocket.decode(from) else { continue }
                onDatagram(Data(bytes: buffer, count: n), host, port)
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
            buffer.deallocate()
        }
        self.fd = fd
        self.source = source
        source.resume()
    }

    /// Returns 0 on success, otherwise the `errno` from `sendto`.
    func send(_ payload: Data, to address: sockaddr_storage) -> Int32 {
        guard !payload.isEmpty else { return 0 }
        var address = address
        let length = socklen_t(address.ss_len)
        let sent = payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, length)
                }
            }
        }
        return sent < 0 ? errno : 0
    }

    func close() {
        source.cancel()
    }

    // MARK: Address helpers

    /// IPv4/IPv6 literal → socket address; `nil` for anything else (a hostname).
    static func literalAddress(host: String, port: UInt16) -> sockaddr_storage? {
        var storage = sockaddr_storage()
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    $0.pointee.sin_family = sa_family_t(AF_INET)
                    $0.pointee.sin_port = port.bigEndian
                    $0.pointee.sin_addr = v4
                }
            }
            return storage
        }
        if inet_pton(AF_INET6, host, &v6) == 1 {
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    $0.pointee.sin6_family = sa_family_t(AF_INET6)
                    $0.pointee.sin6_port = port.bigEndian
                    $0.pointee.sin6_addr = v6
                }
            }
            return storage
        }
        return nil
    }

    static func withPort(_ address: sockaddr_storage, _ port: UInt16) -> sockaddr_storage {
        var address = address
        withUnsafeMutablePointer(to: &address) { pointer in
            if Int32(pointer.pointee.ss_family) == AF_INET {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port = port.bigEndian }
            } else {
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port = port.bigEndian }
            }
        }
        return address
    }

    /// Blocking `getaddrinfo` — call off the relay queue. Prefers IPv4.
    static func resolve(_ name: String) -> sockaddr_storage? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var best: sockaddr_storage?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let sa = info.pointee.ai_addr, info.pointee.ai_family == AF_INET || info.pointee.ai_family == AF_INET6 {
                var storage = sockaddr_storage()
                memcpy(&storage, sa, min(Int(info.pointee.ai_addrlen), MemoryLayout<sockaddr_storage>.size))
                if info.pointee.ai_family == AF_INET { return storage }
                if best == nil { best = storage }
            }
            cursor = info.pointee.ai_next
        }
        return best
    }

    /// Socket address → `(printable host, port)`.
    static func decode(_ address: sockaddr_storage) -> (host: String, port: UInt16)? {
        var address = address
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    guard inet_ntop(AF_INET, &addr, &text, socklen_t(text.count)) != nil else { return nil }
                    return (String(cString: text), UInt16(bigEndian: sin.pointee.sin_port))
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var addr = sin6.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count)) != nil else { return nil }
                    return (String(cString: text), UInt16(bigEndian: sin6.pointee.sin6_port))
                }
            }
        default:
            return nil
        }
    }
}
