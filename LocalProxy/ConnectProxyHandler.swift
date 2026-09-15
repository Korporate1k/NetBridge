import Foundation
import Network

/// Handles one client connection end-to-end over Network.framework: parses the
/// request via a `Frontend` (today, `HTTPFrontend` — see `Frontend.swift`),
/// dials the outbound connection via `DirectTCPTransport` (see
/// `OutboundTransport.swift`), answers with the appropriate reply, then pipes
/// bytes bidirectionally with Network.framework's built-in flow control.
///
/// Every event is logged with this tunnel's id (`[T<id>]`). The new handlers
/// (path, viability, better-path, reports, heartbeat) are diagnostics only and
/// never change proxy behavior.
final class Tunnel {
    enum CloseReason {
        case bothFinished
        case clientFailed(String)
        case clientCancelled
        case clientClosedBeforeRequest(String)
        case badRequest
        case serverFailed(String)
        case serverCancelled
        case retriesExhausted(String)
        case receiveError(direction: String, error: String)
        case sendError(direction: String, error: String)
        case proxyStopped
        case udpAssociateClosed(String)

        var text: String {
            switch self {
            case .bothFinished: return "bothFinished (FIN both directions)"
            case .clientFailed(let e): return "clientFailed(\(e))"
            case .clientCancelled: return "clientCancelled"
            case .clientClosedBeforeRequest(let d): return "clientClosedBeforeRequest(\(d))"
            case .badRequest: return "badRequest"
            case .serverFailed(let e): return "serverFailed(\(e))"
            case .serverCancelled: return "serverCancelled"
            case .retriesExhausted(let e): return "retriesExhausted(\(e))"
            case .receiveError(let dir, let e): return "receiveError(\(dir): \(e))"
            case .sendError(let dir, let e): return "sendError(\(dir): \(e))"
            case .proxyStopped: return "proxyStopped"
            case .udpAssociateClosed(let d): return "udpAssociateClosed(\(d))"
            }
        }
    }

    let id: Int
    private let client: NWConnection
    private let queue: DispatchQueue
    private let stats: ProxyStats
    private let transport: DirectTCPTransport
    private let forcedProtocol: ListenerMode
    private let rateLimiter: RateLimiter?
    var onClose: (() -> Void)?
    var onActivity: ((String) -> Void)?
    /// Called once per request with the destination host (used to recognize devices).
    var onTarget: ((String) -> Void)?
    /// Called once, when the tunnel finishes, with a summary for `ConnectionHistory`.
    var onSummary: ((ConnectionSummary) -> Void)?
    /// Supplied by `ProxyServer` so failure lines record how many tunnels were open.
    var openTunnelCount: () -> Int = { 0 }

    private var server: NWConnection?
    private var udpRelay: UDPRelay?
    private var requestBuffer = Data()
    private var socks5Buffer = Data()
    private var didOpen = false
    private var cleanedUp = false
    private var clientFinished = false
    private var serverFinished = false

    // MARK: Diagnostics state (all mutated on `queue`)

    private let acceptedAt = DispatchTime.now()
    private var requestAt: DispatchTime?
    private var readyAt: DispatchTime?
    private var target = "?"
    private var modeName = "?"
    private var remoteAddress = "?"
    private var serverInterfaces = "?"
    private var bytesUp: UInt64 = 0
    private var bytesDown: UInt64 = 0
    private var chunksUp = 0
    private var chunksDown = 0
    private var firstByteDownAt: DispatchTime?
    private var firstByteToClientAt: DispatchTime?
    private var lastDataAt = DispatchTime.now()
    private var sendsInFlight = 0
    private var heartbeat: DispatchSourceTimer?
    private var beatBytesUp: UInt64 = 0
    private var beatBytesDown: UInt64 = 0
    private var stalled = false
    private var transferReport: NWConnection.PendingDataTransferReport?
    private var clientTransferReport: NWConnection.PendingDataTransferReport?

    private static let maxHeaderBytes = 64 * 1024
    private static let crlfcrlf = Data("\r\n\r\n".utf8)
    private static let stallThresholdMs = 2000.0

    init(id: Int, client: NWConnection, queue: DispatchQueue, stats: ProxyStats, transport: DirectTCPTransport,
         forcedProtocol: ListenerMode = .auto, rateLimiter: RateLimiter? = nil) {
        self.id = id
        self.client = client
        self.queue = queue
        self.stats = stats
        self.transport = transport
        self.forcedProtocol = forcedProtocol
        self.rateLimiter = rateLimiter
    }

    func start() {
        DebugLog.important("client", tunnel: id, "accepted from \(EndpointDescription.describe(client.endpoint)) openTunnels=\(openTunnelCount())")
        client.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .setup:
                DebugLog.debug("client", tunnel: self.id, "state setup")
            case .preparing:
                DebugLog.debug("client", tunnel: self.id, "state preparing")
            case .ready:
                DebugLog.debug("client", tunnel: self.id, "state ready after \(Self.ms(since: self.acceptedAt)) path: \(PathDescription.describe(self.client.currentPath))")
                self.clientTransferReport = self.client.startDataTransferReport()
            case .waiting(let error):
                DebugLog.important("client", tunnel: self.id, "state WAITING \(ErrorDescription.describe(error))")
            case .failed(let error):
                DebugLog.important("client", tunnel: self.id, "state FAILED \(ErrorDescription.describe(error)) \(self.progressText())")
                self.cleanup(.clientFailed(ErrorDescription.describe(error)))
            case .cancelled:
                DebugLog.debug("client", tunnel: self.id, "state cancelled")
                self.cleanup(.clientCancelled)
            @unknown default:
                DebugLog.important("client", tunnel: self.id, "state unknown \(state)")
            }
        }
        client.start(queue: queue)
        if forcedProtocol == .socks5Only {
            receiveSocks5Greeting()
        } else {
            receiveRequest()
        }
    }

    func cancel() {
        queue.async { self.cleanup(.proxyStopped) }
    }

    // MARK: - CONNECT request

    private func receiveRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            DebugLog.trace("client", tunnel: self.id, "request read bytes=\(data?.count ?? 0) isComplete=\(isComplete) error=\(ErrorDescription.describe(error))")

            if let data = data, !data.isEmpty {
                if self.forcedProtocol == .auto && self.requestBuffer.isEmpty && data.first == 0x05 {
                    // SOCKS5's leading VER byte can never collide with an HTTP
                    // method's leading ASCII byte, so this sniff is safe.
                    DebugLog.important("client", tunnel: self.id, "detected SOCKS5 client (VER=0x05)")
                    self.socks5Buffer = data
                    self.receiveSocks5Greeting()
                    return
                }
                self.requestBuffer.append(data)
                if self.requestBuffer.count > Self.maxHeaderBytes {
                    DebugLog.important("client", tunnel: self.id, "request headers exceed \(Self.maxHeaderBytes) bytes; first bytes: \(Self.escaped(self.requestBuffer.prefix(512)))")
                    self.sendErrorAndClose()
                    return
                }
                if self.requestBuffer.range(of: Self.crlfcrlf) != nil {
                    self.requestAt = DispatchTime.now()
                    DebugLog.important("client", tunnel: self.id, "request after \(Self.ms(since: self.acceptedAt)): \(Self.headerText(self.requestBuffer)) earlyDataBytes=\(HTTPFrontend.dataAfterHeaders(in: self.requestBuffer).count)")
                    if let request = HTTPFrontend.parse(self.requestBuffer) {
                        self.requestBuffer.removeAll()
                        self.open(request)
                    } else {
                        DebugLog.important("client", tunnel: self.id, "UNPARSEABLE request, first 512 bytes: \(Self.escaped(self.requestBuffer.prefix(512)))")
                        self.sendErrorAndClose()
                    }
                } else {
                    self.receiveRequest() // header not complete yet
                }
            } else if isComplete || error != nil {
                let detail = "bytesReceived=\(self.requestBuffer.count) isComplete=\(isComplete) error=\(ErrorDescription.describe(error)) after=\(Self.ms(since: self.acceptedAt))"
                DebugLog.important("client", tunnel: self.id, "client closed before sending a full request: \(detail)\(self.requestBuffer.isEmpty ? "" : " partial=\(Self.escaped(self.requestBuffer.prefix(512)))")")
                self.cleanup(.clientClosedBeforeRequest(detail))
            }
        }
    }

    // MARK: - SOCKS5 request

    /// Parses `socks5Buffer` as far as it goes; reads more from `client` only
    /// if needed. Callable both from the initial sniff (buffer already primed
    /// with the first chunk) and recursively once more data arrives.
    private func receiveSocks5Greeting() {
        switch Socks5.parseGreeting(socks5Buffer) {
        case .needMoreData:
            client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    self.socks5Buffer.append(data)
                    self.receiveSocks5Greeting()
                } else if isComplete || error != nil {
                    let detail = "SOCKS5 greeting: bytesReceived=\(self.socks5Buffer.count) isComplete=\(isComplete) error=\(ErrorDescription.describe(error))"
                    DebugLog.important("client", tunnel: self.id, "client closed before sending a full SOCKS5 greeting: \(detail)")
                    self.cleanup(.clientClosedBeforeRequest(detail))
                }
            }
        case .ok(let consumed):
            socks5Buffer.removeFirst(consumed)
            DebugLog.important("client", tunnel: id, "SOCKS5 greeting ok (no-auth offered)")
            client.send(content: Socks5.methodSelectionOK, completion: .contentProcessed { [weak self] sendError in
                guard let self = self else { return }
                if let sendError = sendError {
                    DebugLog.important("client", tunnel: self.id, "SOCKS5 method-selection send error \(ErrorDescription.describe(sendError))")
                    self.cleanup(.badRequest)
                    return
                }
                self.receiveSocks5Request()
            })
        case .noAcceptableMethod(let consumed):
            socks5Buffer.removeFirst(consumed)
            DebugLog.important("client", tunnel: id, "SOCKS5 no acceptable auth method offered (no-auth not in list)")
            client.send(content: Socks5.methodSelectionNoAcceptable, completion: .contentProcessed { [weak self] _ in
                self?.cleanup(.badRequest)
            })
        }
    }

    private func receiveSocks5Request() {
        switch Socks5.parseRequest(socks5Buffer) {
        case .needMoreData:
            if socks5Buffer.count > Self.maxHeaderBytes {
                DebugLog.important("client", tunnel: id, "SOCKS5 request exceeds \(Self.maxHeaderBytes) bytes")
                sendSocks5ErrorAndClose(.generalFailure)
                return
            }
            client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    self.socks5Buffer.append(data)
                    self.receiveSocks5Request()
                } else if isComplete || error != nil {
                    let detail = "SOCKS5 request: bytesReceived=\(self.socks5Buffer.count) isComplete=\(isComplete) error=\(ErrorDescription.describe(error))"
                    DebugLog.important("client", tunnel: self.id, "client closed before sending a full SOCKS5 request: \(detail)")
                    self.cleanup(.clientClosedBeforeRequest(detail))
                }
            }
        case .invalid:
            DebugLog.important("client", tunnel: id, "UNPARSEABLE SOCKS5 request, first 512 bytes: \(Self.escaped(socks5Buffer.prefix(512)))")
            sendSocks5ErrorAndClose(.generalFailure)
        case .parsed(let command, let host, let port, let consumed):
            requestAt = DispatchTime.now()
            let earlyData = Data(socks5Buffer.dropFirst(consumed))
            socks5Buffer.removeAll()
            switch command {
            case .connect:
                DebugLog.important("client", tunnel: id, "SOCKS5 CONNECT \(host):\(port) earlyDataBytes=\(earlyData.count)")
                let meta = ConnectMeta(
                    label: "SOCKS5-CONNECT",
                    successReply: Socks5.reply(.succeeded),
                    failureReply: Socks5.reply(.generalFailure)
                )
                open(.connect(host: host, port: port, earlyData: earlyData, meta: meta))
            case .udpAssociate:
                DebugLog.important("client", tunnel: id, "SOCKS5 UDP ASSOCIATE requested")
                startUDPAssociate()
            case .bind:
                DebugLog.important("client", tunnel: id, "SOCKS5 BIND requested — not supported")
                sendSocks5ErrorAndClose(.commandNotSupported)
            }
        }
    }

    private func sendSocks5ErrorAndClose(_ code: Socks5.ReplyCode) {
        client.send(content: Socks5.reply(code), completion: .contentProcessed { [weak self] _ in
            self?.cleanup(.badRequest)
        })
    }

    // MARK: - SOCKS5 UDP ASSOCIATE

    private func startUDPAssociate() {
        let relay = UDPRelay(id: id, queue: queue, stats: stats)
        udpRelay = relay
        relay.start { [weak self] host, port in
            guard let self = self else { return }
            guard let host = host, let port = port else {
                self.sendSocks5ErrorAndClose(.generalFailure)
                return
            }
            self.target = "\(host):\(port)"
            self.modeName = "SOCKS5-UDP-ASSOCIATE"
            self.onActivity?("SOCKS5 UDP ASSOCIATE \(host):\(port)")
            self.client.send(content: Socks5.associateReply(host: host, port: port), completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    DebugLog.important("client", tunnel: self.id, "SOCKS5 UDP ASSOCIATE reply send error \(ErrorDescription.describe(error))")
                    self.cleanup(.badRequest)
                    return
                }
                // No further application data is expected on this connection
                // (RFC 1928) — keep reading only to notice its eventual close,
                // which tears the relay down with it.
                self.watchControlConnectionForClose()
            })
        }
    }

    private func watchControlConnectionForClose() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self = self else { return }
            if isComplete || error != nil {
                self.cleanup(.udpAssociateClosed(ErrorDescription.describe(error)))
            } else {
                self.watchControlConnectionForClose()
            }
        }
    }

    // MARK: - Outbound + tunnel

    /// Dispatches a parsed `ProxyRequest` (see `Frontend.swift`) to the outbound
    /// dial. Replaces the old `openTunnel`/`openForward` pair now that both
    /// front-end outcomes share one enum.
    private func open(_ request: ProxyRequest) {
        let host: String
        let port: UInt16
        switch request {
        case .connect(let h, let p, _, _): host = h; port = p
        case .httpForward(let h, let p, _): host = h; port = p
        }
        guard let serverPort = NWEndpoint.Port(rawValue: port) else {
            sendErrorAndClose()
            return
        }
        target = "\(host):\(port)"
        onTarget?(host)
        switch request {
        case .connect(_, _, _, let meta):
            modeName = meta.label
            onActivity?("\(meta.label) \(host):\(port)")
        case .httpForward:
            modeName = "HTTP-forward"
            onActivity?("HTTP forward \(host):\(port)")
        }
        // Resolved once (if DoH is enabled) and reused across retry attempts,
        // rather than re-resolving on every attempt. `host` stays what's
        // logged/displayed throughout; only the actual dial target changes.
        DoHResolver.shared.resolve(host) { [weak self] resolvedIP in
            guard let self = self else { return }
            self.queue.async {
                guard !self.cleanedUp else { return }
                if let resolvedIP = resolvedIP {
                    DebugLog.debug("dns", tunnel: self.id, "DoH resolved \(host) -> \(resolvedIP)")
                }
                self.connectOutbound(dialHost: resolvedIP ?? host, host: host, port: serverPort, request: request, attempt: 0)
            }
        }
    }

    private func connectOutbound(dialHost: String, host: String, port: NWEndpoint.Port, request: ProxyRequest, attempt: Int) {
        let server = transport.dial(host: dialHost, port: port)
        self.server = server
        DebugLog.important("server", tunnel: id, "dialing \(host):\(port) mode=\(modeName) attempt=\(attempt) openTunnels=\(openTunnelCount())")

        server.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            DebugLog.important("server", tunnel: self.id, "PATH UPDATE \(self.progressText()) \(PathDescription.describe(path))")
        }
        server.viabilityUpdateHandler = { [weak self] isViable in
            guard let self = self else { return }
            DebugLog.important("server", tunnel: self.id, "VIABILITY -> \(isViable) \(self.progressText()) path: \(PathDescription.describe(server.currentPath))")
        }
        server.betterPathUpdateHandler = { [weak self] hasBetter in
            guard let self = self else { return }
            DebugLog.important("server", tunnel: self.id, "BETTER PATH available=\(hasBetter) \(self.progressText())")
        }

        server.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .setup:
                DebugLog.debug("server", tunnel: self.id, "state setup attempt=\(attempt)")
            case .preparing:
                DebugLog.debug("server", tunnel: self.id, "state preparing attempt=\(attempt) sinceRequest=\(self.msSinceRequest())")
            case .ready:
                self.readyAt = DispatchTime.now()
                let path = server.currentPath
                self.remoteAddress = EndpointDescription.describe(path?.remoteEndpoint)
                self.serverInterfaces = path.map { p in
                    p.availableInterfaces.filter { p.usesInterfaceType($0.type) }.map(\.name).joined(separator: ",")
                } ?? "?"
                DebugLog.important("server", tunnel: self.id, "READY \(host):\(port) attempt=\(attempt) connectTime=\(self.msSinceRequest()) openTunnels=\(self.openTunnelCount()) path: \(PathDescription.describe(path))")
                self.logEstablishmentReport(server)
                self.transferReport = server.startDataTransferReport()
                self.startHeartbeat()
                self.onActivity?("connected \(host):\(port)")
                self.didOpen = true
                self.stats.connectionOpened()
                switch request {
                case .connect(_, _, let earlyData, let meta):
                    self.client.send(
                        content: meta.successReply,
                        contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { [weak self] error in
                            guard let self = self else { return }
                            DebugLog.debug("client", tunnel: self.id, "sent \(meta.label) success reply error=\(ErrorDescription.describe(error))")
                            self.pipe(server: server, earlyData: earlyData)
                        }
                    )
                case .httpForward(_, _, let rawRequest):
                    server.send(
                        content: rawRequest,
                        contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { [weak self] error in
                            guard let self = self else { return }
                            DebugLog.debug("server", tunnel: self.id, "forwarded request bytes=\(rawRequest.count) error=\(ErrorDescription.describe(error))")
                            self.pipe(server: server, earlyData: Data())
                        }
                    )
                }
            case .waiting(let error):
                DebugLog.important("server", tunnel: self.id, "state WAITING \(ErrorDescription.describe(error)) attempt=\(attempt) \(self.progressText()) path: \(PathDescription.describe(server.currentPath))")
            case .failed(let error):
                let errorText = ErrorDescription.describe(error)
                DebugLog.important("server", tunnel: self.id, "state FAILED \(errorText) attempt=\(attempt) didOpen=\(self.didOpen) \(self.progressText()) openTunnels=\(self.openTunnelCount()) path: \(PathDescription.describe(server.currentPath))")
                self.onActivity?("outbound \(host):\(port) FAILED: \(errorText)")
                if !self.didOpen && attempt < 3 {
                    let delay = Double(1 << attempt) // 1s, 2s, 4s
                    DebugLog.important("server", tunnel: self.id, "retrying \(host):\(port) in \(delay)s (attempt \(attempt + 1) of 3)")
                    self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.connectOutbound(dialHost: dialHost, host: host, port: port, request: request, attempt: attempt + 1)
                    }
                } else if !self.didOpen {
                    if case .connect(_, _, _, let meta) = request, let failureReply = meta.failureReply {
                        self.client.send(content: failureReply, completion: .contentProcessed { _ in })
                    }
                    self.cleanup(.retriesExhausted(errorText))
                } else {
                    self.cleanup(.serverFailed(errorText))
                }
            case .cancelled:
                DebugLog.debug("server", tunnel: self.id, "state cancelled")
                self.cleanup(.serverCancelled)
            @unknown default:
                DebugLog.important("server", tunnel: self.id, "state unknown \(state)")
            }
        }
        server.start(queue: queue)
    }

    private func pipe(server: NWConnection, earlyData: Data) {
        if !earlyData.isEmpty {
            DebugLog.debug("data", tunnel: id, "sending early data bytes=\(earlyData.count) to server")
            server.send(content: earlyData, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [weak self] error in
                guard let self = self, let error = error else { return }
                DebugLog.important("data", tunnel: self.id, "early data send error \(ErrorDescription.describe(error))")
            })
        }
        forward(from: client, to: server, isUpstream: true)
        forward(from: server, to: client, isUpstream: false)
    }

    private func forward(from source: NWConnection, to destination: NWConnection, isUpstream: Bool) {
        let direction = isUpstream ? "client->server" : "server->client"
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            DebugLog.trace("data", tunnel: self.id, "\(direction) recv bytes=\(data?.count ?? 0) isComplete=\(isComplete) error=\(ErrorDescription.describe(error))")

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    DebugLog.important("data", tunnel: self.id, "\(direction) FIN received \(self.progressText())")
                    self.forwardFin(to: destination, isUpstream: isUpstream)
                } else if let error = error {
                    DebugLog.important("data", tunnel: self.id, "\(direction) RECEIVE ERROR \(ErrorDescription.describe(error)) \(self.progressText())")
                    self.cleanup(.receiveError(direction: direction, error: ErrorDescription.describe(error)))
                } else {
                    self.forward(from: source, to: destination, isUpstream: isUpstream)
                }
                return
            }

            let count = data.count
            if isUpstream {
                self.stats.addBytesUp(count)
                self.bytesUp += UInt64(count)
                self.chunksUp += 1
            } else {
                self.stats.addBytesDown(count)
                self.bytesDown += UInt64(count)
                self.chunksDown += 1
                if self.firstByteDownAt == nil {
                    self.firstByteDownAt = DispatchTime.now()
                    DebugLog.debug("data", tunnel: self.id, "first byte from server after \(self.msSinceReady()) (since request \(self.msSinceRequest()))")
                }
            }
            self.lastDataAt = DispatchTime.now()
            if error != nil {
                DebugLog.important("data", tunnel: self.id, "\(direction) data arrived WITH error \(ErrorDescription.describe(error))")
            }

            // Backpressure: re-arm the read only after this chunk is handed off,
            // so a slow destination can't cause unbounded buffering.
            self.sendsInFlight += 1
            let sendStart = DispatchTime.now()
            let doSend = {
                destination.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [weak self] sendError in
                    guard let self = self else { return }
                    self.sendsInFlight -= 1
                    if !isUpstream && sendError == nil && self.firstByteToClientAt == nil {
                        self.firstByteToClientAt = DispatchTime.now()
                        DebugLog.debug("data", tunnel: self.id, "first byte forwarded to client after \(Self.ms(since: self.acceptedAt))")
                    }
                    DebugLog.trace("data", tunnel: self.id, "\(direction) send bytes=\(count) done in \(Self.ms(since: sendStart)) error=\(ErrorDescription.describe(sendError))")
                    if let sendError = sendError {
                        DebugLog.important("data", tunnel: self.id, "\(direction) SEND ERROR \(ErrorDescription.describe(sendError)) \(self.progressText())")
                        self.cleanup(.sendError(direction: direction, error: ErrorDescription.describe(sendError)))
                    } else if isComplete {
                        DebugLog.important("data", tunnel: self.id, "\(direction) FIN received with final data \(self.progressText())")
                        self.forwardFin(to: destination, isUpstream: isUpstream)
                    } else {
                        self.forward(from: source, to: destination, isUpstream: isUpstream)
                    }
                })
            }
            // A device-level bandwidth cap: delay the send instead of sending
            // immediately, so the long-run rate stays at the cap. The next
            // read stays gated on this send completing either way, matching
            // the existing backpressure design above.
            if let delay = self.rateLimiter?.consume(count), delay > 0 {
                self.queue.asyncAfter(deadline: .now() + delay, execute: doSend)
            } else {
                doSend()
            }
        }
    }

    private func forwardFin(to destination: NWConnection, isUpstream: Bool) {
        DebugLog.debug("data", tunnel: id, "forwarding FIN to \(isUpstream ? "server" : "client")")
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self = self, let error = error else { return }
            DebugLog.important("data", tunnel: self.id, "FIN send error \(ErrorDescription.describe(error))")
        })
        if isUpstream { self.clientFinished = true } else { self.serverFinished = true }
        self.finishIfBothClosed()
    }

    // MARK: - Teardown

    private func sendErrorAndClose() {
        client.send(
            content: Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
            completion: .contentProcessed { [weak self] _ in
                self?.cleanup(.badRequest)
            }
        )
    }

    private func cleanup(_ reason: CloseReason) {
        guard !cleanedUp else { return }
        cleanedUp = true
        heartbeat?.cancel()
        heartbeat = nil

        let firstByte = firstByteDownAt.map { Self.ms(from: readyAt ?? acceptedAt, to: $0) } ?? "never"
        let firstByteToClient = firstByteToClientAt.map { Self.ms(from: acceptedAt, to: $0) } ?? "never"
        DebugLog.important("tunnel", tunnel: id, "CLOSED reason=\(reason.text) target=\(target) mode=\(modeName) remote=\(remoteAddress) iface=\(serverInterfaces) lifetime=\(Self.ms(since: acceptedAt)) sinceReady=\(msSinceReady()) firstByteDown=\(firstByte) firstByteToClient=\(firstByteToClient) up=\(bytesUp)B/\(chunksUp)chunks down=\(bytesDown)B/\(chunksDown)chunks openTunnels=\(openTunnelCount())")

        // Snapshots taken at collect time, so this must happen before cancel().
        if let report = transferReport {
            let tunnelID = id
            report.collect(queue: queue) { report in
                DebugLog.important("tunnel", tunnel: tunnelID, "server transfer report \(TransferReportDescription.describe(report))")
            }
            transferReport = nil
        }
        if let report = clientTransferReport {
            let tunnelID = id
            report.collect(queue: queue) { report in
                DebugLog.important("tunnel", tunnel: tunnelID, "client transfer report \(TransferReportDescription.describe(report))")
            }
            clientTransferReport = nil
        }

        onActivity?("closed \(target): \(reason.text)")
        if target != "?" {
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds &- acceptedAt.uptimeNanoseconds) / 1_000_000
            onSummary?(ConnectionSummary(target: target, mode: modeName, bytesUp: bytesUp, bytesDown: bytesDown,
                                          durationMs: durationMs, closedAt: Date(), reason: reason.text))
        }
        client.cancel()
        server?.cancel()
        udpRelay?.cancel()
        if didOpen {
            didOpen = false
            stats.connectionClosed()
        }
        onClose?()
    }

    private func finishIfBothClosed() {
        if clientFinished && serverFinished {
            cleanup(.bothFinished)
        }
    }

    // MARK: - Diagnostics helpers

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
            DebugLog.debug("data", tunnel: self.id, "heartbeat +up=\(deltaUp)B/s +down=\(deltaDown)B/s total up=\(self.bytesUp) down=\(self.bytesDown) sendsInFlight=\(self.sendsInFlight) idle=\(String(format: "%.0f", idleMs))ms")
            if idleMs > Self.stallThresholdMs && !self.stalled {
                self.stalled = true
                DebugLog.important("data", tunnel: self.id, "STALL no bytes either direction for \(String(format: "%.0f", idleMs))ms sendsInFlight=\(self.sendsInFlight) path: \(PathDescription.describe(self.server?.currentPath))")
            } else if idleMs <= Self.stallThresholdMs && self.stalled {
                self.stalled = false
                DebugLog.important("data", tunnel: self.id, "stall cleared")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func logEstablishmentReport(_ server: NWConnection) {
        let tunnelID = id
        server.requestEstablishmentReport(queue: queue) { report in
            guard let report = report else {
                DebugLog.debug("server", tunnel: tunnelID, "establishment report unavailable")
                return
            }
            let resolutions = report.resolutions.map {
                "dns(source=\($0.source) proto=\($0.dnsProtocol) took=\(Self.ms($0.duration)) endpoints=\($0.endpointCount) success=\(EndpointDescription.describe($0.successfulEndpoint)) preferred=\(EndpointDescription.describe($0.preferredEndpoint)))"
            }
            let handshakes = report.handshakes.map {
                "\($0.definition.name)(took=\(Self.ms($0.handshakeDuration)) rtt=\(Self.ms($0.handshakeRTT)))"
            }
            DebugLog.important("server", tunnel: tunnelID, "establishment total=\(Self.ms(report.duration)) startedAfter=\(Self.ms(report.attemptStartedAfterInterval)) previousAttempts=\(report.previousAttemptCount) usedProxy=\(report.usedProxy) proxyConfigured=\(report.proxyConfigured) \(resolutions.joined(separator: " ")) handshakes=[\(handshakes.joined(separator: ","))]")
        }
    }

    private func progressText() -> String {
        "sinceRequest=\(msSinceRequest()) sinceReady=\(msSinceReady()) up=\(bytesUp)B down=\(bytesDown)B"
    }

    private func msSinceRequest() -> String { requestAt.map { Self.ms(since: $0) } ?? "n/a" }
    private func msSinceReady() -> String { readyAt.map { Self.ms(since: $0) } ?? "n/a" }

    private static func ms(since start: DispatchTime) -> String {
        ms(from: start, to: DispatchTime.now())
    }

    private static func ms(from start: DispatchTime, to end: DispatchTime) -> String {
        String(format: "%.1fms", Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    private static func ms(_ interval: TimeInterval) -> String {
        String(format: "%.1fms", interval * 1000)
    }

    /// Request line + headers on one line, with credential-bearing header values redacted.
    private static func headerText(_ data: Data) -> String {
        guard let end = data.range(of: crlfcrlf),
              let text = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return "(non-UTF8 headers) \(escaped(data.prefix(512)))"
        }
        let redacted = ["cookie", "authorization", "proxy-authorization"]
        return text.components(separatedBy: "\r\n").map { line -> String in
            guard let colon = line.firstIndex(of: ":") else { return line }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            return redacted.contains(name) ? "\(line[..<colon]): <redacted>" : line
        }.joined(separator: " | ")
    }

    private static func escaped(_ data: Data) -> String {
        data.map { byte -> String in
            switch byte {
            case 0x0D: return "\\r"
            case 0x0A: return "\\n"
            case 0x20...0x7E: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02x", byte)
            }
        }.joined()
    }
}
