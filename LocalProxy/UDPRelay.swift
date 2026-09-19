import Foundation
import Network

/// One SOCKS5 `UDP ASSOCIATE` session: an ephemeral UDP listener receives
/// wrapped datagrams from the SOCKS5 client, relays each one's payload to
/// whatever destination it names (one `NWConnection(.udp)` per distinct
/// destination), and wraps replies the same way on the way back. Owned by the
/// `Tunnel` whose SOCKS5 request created it — its lifetime is tied to that
/// tunnel's TCP control connection per RFC 1928, so `Tunnel.cleanup()`
/// cancels it directly rather than `ProxyServer` tracking it separately.
///
/// Throughput audit notes (no `NWParameters`/`NWProtocolUDP.Options` tuning
/// applied — none were found with a clear, protocol-agnostic benefit):
/// - `receiveMessage(completion:)` (used below, no size arguments) already
///   delivers one complete datagram regardless of size — unlike the TCP
///   relay's byte-stream `receive(minimumIncompleteLength:maximumLength:)`,
///   there is no smaller default to raise here, and no `maximumLength`
///   overload exists for message-based receives to begin with.
/// - `NWParameters.udp`'s default `serviceClass` (`.bestEffort`) is kept
///   deliberately: this relay carries arbitrary, unidentified UDP payloads
///   (DNS, voice, game traffic, ...), so biasing toward a latency-oriented
///   class like `.responsiveData` would be a QoS tradeoff for some traffic
///   at the expense of others, not a universal speed win.
///   `multipathServiceType` and TCP Fast Open have no UDP equivalent, so
///   neither applies here.
/// - One `NWConnection` per distinct destination (already the design below)
///   is the correct model for outbound UDP under Network.framework — it has
///   no connectionless "send to arbitrary address" API — and `.start()`
///   already doesn't block the first `send()` (Network.framework queues it
///   until ready), so there is no first-packet latency being left on the
///   table.
final class UDPRelay {
    let id: Int
    private let queue: DispatchQueue
    private let stats: ProxyStats

    private var listener: NWListener?
    private var clientConnection: NWConnection?
    private var destinations: [String: NWConnection] = [:]
    private var cancelled = false
    private var didOpenStats = false

    /// Per-`NWConnection` outbound send queues (keyed the same as
    /// `destinations`, plus a fixed key for the single client connection).
    /// Necessary because firing multiple `NWConnection.send()` calls back to
    /// back on the same UDP connection, before earlier ones complete, does
    /// not queue reliably — measured directly: a rapid burst of datagrams to
    /// the same destination delivered only 1 of 8 replies, consistently,
    /// regardless of read-side backpressure (already tried and correctly
    /// ruled out — see `receiveFromClient`'s doc comment). Serializing sends
    /// per connection (never gating reads on it) fixed it. Each destination
    /// gets its own queue so unrelated destinations still send concurrently.
    private var pendingSends: [String: [Data]] = [:]
    private var sendInFlight: Set<String> = []
    private static let clientSendKey = "\u{0}client"

    // MARK: Throughput diagnostics (all mutated on `queue`)

    private var bytesUp: UInt64 = 0
    private var bytesDown: UInt64 = 0
    private var datagramsUp = 0
    private var datagramsDown = 0
    private var beatBytesUp: UInt64 = 0
    private var beatBytesDown: UInt64 = 0
    private var lastDataAt = DispatchTime.now()
    private var heartbeat: DispatchSourceTimer?
    private var stalled = false
    private var clientTransferReport: NWConnection.PendingDataTransferReport?
    private var destinationTransferReports: [String: NWConnection.PendingDataTransferReport] = [:]
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

    // MARK: - Destination side (one NWConnection per distinct host:port the client has talked to)

    private func relay(payload: Data, to host: String, port: UInt16) {
        let key = "\(host):\(port)"
        let destination: NWConnection
        if let existing = destinations[key] {
            destination = existing
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                DebugLog.debug("udp", tunnel: id, "UDP ASSOCIATE dropped datagram with invalid port \(port)")
                return
            }
            let newConnection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: EgressTTL.udp)
            destinations[key] = newConnection
            newConnection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                if case .failed(let error) = state {
                    DebugLog.debug("udp", tunnel: self.id, "UDP ASSOCIATE destination \(key) FAILED \(ErrorDescription.describe(error))")
                    self.logAndClearDestinationReport(key: key)
                    self.destinations.removeValue(forKey: key)
                    self.pendingSends.removeValue(forKey: key)
                    self.sendInFlight.remove(key)
                }
            }
            newConnection.start(queue: queue)
            destinationTransferReports[key] = newConnection.startDataTransferReport()
            logDestinationEstablishment(newConnection, key: key)
            receiveFromDestination(newConnection, key: key, host: host, port: port)
            destination = newConnection
        }
        stats.addBytesUp(payload.count)
        bytesUp += UInt64(payload.count)
        datagramsUp += 1
        lastDataAt = DispatchTime.now()
        enqueueSend(payload, on: destination, key: key)
    }

    private func receiveFromDestination(_ connection: NWConnection, key: String, host: String, port: UInt16) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, !self.cancelled else { return }
            guard error == nil else { return }
            if let data = data, !data.isEmpty, let client = self.clientConnection {
                self.stats.addBytesDown(data.count)
                self.bytesDown += UInt64(data.count)
                self.datagramsDown += 1
                self.lastDataAt = DispatchTime.now()
                let wrapped = Socks5.buildUDPDatagram(host: host, port: port, payload: data)
                self.enqueueSend(wrapped, on: client, key: Self.clientSendKey)
            }
            self.receiveFromDestination(connection, key: key, host: host, port: port)
        }
    }

    private func logDestinationEstablishment(_ connection: NWConnection, key: String) {
        let tunnelID = id
        connection.requestEstablishmentReport(queue: queue) { report in
            guard let report = report else {
                DebugLog.debug("udp", tunnel: tunnelID, "destination \(key) establishment report unavailable")
                return
            }
            let resolutions = report.resolutions.map {
                "dns(source=\($0.source) proto=\($0.dnsProtocol) took=\(DurationFormat.ms($0.duration)) endpoints=\($0.endpointCount) success=\(EndpointDescription.describe($0.successfulEndpoint)) preferred=\(EndpointDescription.describe($0.preferredEndpoint)))"
            }
            let handshakes = report.handshakes.map {
                "\($0.definition.name)(took=\(DurationFormat.ms($0.handshakeDuration)) rtt=\(DurationFormat.ms($0.handshakeRTT)))"
            }
            DebugLog.important("udp", tunnel: tunnelID, "destination \(key) establishment total=\(DurationFormat.ms(report.duration)) startedAfter=\(DurationFormat.ms(report.attemptStartedAfterInterval)) previousAttempts=\(report.previousAttemptCount) \(resolutions.joined(separator: " ")) handshakes=[\(handshakes.joined(separator: ","))]")
        }
    }

    private func logAndClearDestinationReport(key: String) {
        guard let report = destinationTransferReports.removeValue(forKey: key) else { return }
        let tunnelID = id
        report.collect(queue: queue) { report in
            DebugLog.important("udp", tunnel: tunnelID, "destination \(key) transfer report \(TransferReportDescription.describe(report))")
        }
    }

    // MARK: - Per-connection outbound send serialization

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
                DebugLog.debug("udp", tunnel: tunnelID, "UDP ASSOCIATE send to \(key) error \(ErrorDescription.describe(error))")
            }
            self.sendInFlight.remove(key)
            self.sendNext(on: connection, key: key)
        })
    }

    // MARK: - Heartbeat / stall detection (mirrors Tunnel.startHeartbeat, one aggregate line for the whole
    // relay rather than per-destination — a relay can fan out to several destinations, e.g. DNS + QUIC +
    // game traffic each opening their own NWConnection, and per-destination heartbeats would multiply 1Hz
    // log volume by destination count for little value versus one summed line).

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
            DebugLog.debug("udp", tunnel: self.id, "heartbeat +up=\(deltaUp)B/s +down=\(deltaDown)B/s total up=\(self.bytesUp) down=\(self.bytesDown) datagrams up=\(self.datagramsUp) down=\(self.datagramsDown) destinations=\(self.destinations.count) pendingSends=\(pending) sendsInFlight=\(self.sendInFlight.count) idle=\(String(format: "%.0f", idleMs))ms")
            if idleMs > Self.stallThresholdMs && !self.stalled {
                self.stalled = true
                DebugLog.important("udp", tunnel: self.id, "STALL no datagrams either direction for \(String(format: "%.0f", idleMs))ms destinations=\(self.destinations.count) pendingSends=\(pending)")
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
        DebugLog.important("udp", tunnel: id, "UDP ASSOCIATE relay closed, \(destinations.count) destination(s) up=\(bytesUp)B/\(datagramsUp)dgrams down=\(bytesDown)B/\(datagramsDown)dgrams")
        if let report = clientTransferReport {
            let tunnelID = id
            report.collect(queue: queue) { report in
                DebugLog.important("udp", tunnel: tunnelID, "client transfer report \(TransferReportDescription.describe(report))")
            }
            clientTransferReport = nil
        }
        for key in destinations.keys { logAndClearDestinationReport(key: key) }
        listener?.cancel()
        clientConnection?.cancel()
        for (_, connection) in destinations { connection.cancel() }
        destinations.removeAll()
        pendingSends.removeAll()
        sendInFlight.removeAll()
        if didOpenStats {
            didOpenStats = false
            stats.connectionClosed()
        }
    }
}
