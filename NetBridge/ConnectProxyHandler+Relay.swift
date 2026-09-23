import Foundation
import Network

extension Tunnel {
    // MARK: - Outbound + tunnel

    /// Dispatches a parsed `ProxyRequest` (see `Frontend.swift`) to the outbound
    /// dial. Replaces the old `openTunnel`/`openForward` pair now that both
    /// front-end outcomes share one enum.
    func open(_ request: ProxyRequest) {
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
        case .connect(_, _, let earlyData, let meta):
            modeName = meta.label
            onActivity?("\(meta.label) \(host):\(port)")
            // Only sniff when the host is otherwise opaque (an IP literal) —
            // a domain host is already the human-readable answer.
            if IPv4Address(host) != nil || IPv6Address(host) != nil {
                if !earlyData.isEmpty {
                    sniffedHost = TrafficSniffer.extractHost(from: earlyData)
                } else {
                    sniffPending = true
                }
            }
        case .httpForward:
            modeName = "HTTP-forward"
            onActivity?("HTTP forward \(host):\(port)")
        }
        func startDial() {
            // Resolved once (if DoH is enabled) and reused across retry attempts,
            // rather than re-resolving on every attempt. `host` stays what's
            // logged/displayed throughout; only the actual dial target changes.
            DoHResolver.shared.resolve(host) { [weak self] resolvedIP in
                guard let self = self else { return }
                let launch: (String) -> Void = { dialHost in
                    self.queue.async {
                        guard !self.cleanedUp else { return }
                        if let resolvedIP = resolvedIP {
                            DebugLog.debug("dns", tunnel: self.id, "DoH resolved \(host) -> \(resolvedIP)")
                        }
                        if dialHost != (resolvedIP ?? host) {
                            DebugLog.important("dns", tunnel: self.id, "NAT64 (cellular pin): \(host) -> dial \(dialHost)")
                        }
                        self.connectOutbound(dialHost: dialHost, host: host, port: serverPort, request: request, attempt: 0)
                    }
                }
                let target = resolvedIP ?? host
                if EgressInterface.current == .cellular {
                    // NAT64 lookup may block in getaddrinfo, so keep it off the tunnel queue.
                    DispatchQueue.global(qos: .userInitiated).async { launch(NAT64.dialHost(for: target)) }
                } else {
                    launch(target)
                }
            }
    
        }
        // Bind-to-VPN with no tunnel right now. The tunnel often comes straight back (the VPN client reconnecting), so wait a
        // few seconds for it rather than failing every new connection; refuse only if it stays gone (never dial outside it).
        if EgressInterface.current == .vpn, VPNProbe.activeName() == nil {
            DebugLog.important("server", tunnel: id, "Bind to VPN is on but no VPN tunnel is up — waiting up to \(Int(Self.vpnReconnectWaitSeconds))s for it before \(host):\(port)")
            let deadline = DispatchTime.now() + Self.vpnReconnectWaitSeconds
            func poll() {
                guard !cleanedUp else { return }
                if VPNProbe.activeName() != nil {
                    DebugLog.important("server", tunnel: id, "VPN tunnel is back — dialing \(host):\(port)")
                    startDial()
                    return
                }
                if DispatchTime.now() >= deadline {
                    DebugLog.important("server", tunnel: id, "no VPN tunnel after \(Int(Self.vpnReconnectWaitSeconds))s — refusing \(host):\(port)")
                    onActivity?("outbound \(host):\(port) FAILED: no VPN active")
                    if case .connect(_, _, _, let meta) = request, let failureReply = meta.failureReply {
                        client.send(content: failureReply, completion: .contentProcessed { _ in })
                    }
                    cleanup(.retriesExhausted("Bind to VPN is on but no VPN is active"))
                    return
                }
                queue.asyncAfter(deadline: .now() + 0.25) { poll() }
            }
            poll()
            return
        }
        startDial()
    }

    /// How long a new dial waits for a reconnecting VPN tunnel before it is refused.
    private static var vpnReconnectWaitSeconds: Double { 6 }

    /// How long a dial may sit in `.waiting` when an outbound interface type is pinned before it is failed.
    private static var pinnedInterfaceWaitSeconds: Double { 5 }

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

        // NWConnection sits in `.waiting` (instead of failing) when the destination name doesn't exist or the pinned
        // outbound interface is down, so the client would hang. `abortDial` fails the dial with a real reason and the
        // protocol's failure reply. State updates all run on `queue`.
        var waitTimerArmed = false
        var lastWaitError: NWError?
        let abortDial: (String) -> Void = { [weak self, weak server] reason in
            guard let self = self, let server = server, self.server === server, !self.didOpen, !self.cleanedUp else { return }
            DebugLog.important("server", tunnel: self.id, "\(reason) — failing \(host):\(port)")
            self.onActivity?("outbound \(host):\(port) FAILED: \(reason)")
            if case .connect(_, _, _, let meta) = request, let failureReply = meta.failureReply {
                self.client.send(content: failureReply, completion: .contentProcessed { _ in })
            }
            self.cleanup(.retriesExhausted(reason))
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
                self.destinationIP = EndpointDescription.rawIP(path?.remoteEndpoint)
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
                lastWaitError = error
                // kDNSServiceErr_NoSuchRecord (-65554) / NoSuchName (-65538): the name has no address at all, so waiting can
                // never succeed — fail now rather than hang the client (and don't blame the network interface).
                if case .dns(let code) = error, code == -65554 || code == -65538 {
                    abortDial("DNS: \(host) does not exist")
                    return
                }
                let pinned = EgressInterface.current
                if pinned != .automatic, !waitTimerArmed {
                    waitTimerArmed = true
                    self.queue.asyncAfter(deadline: .now() + Self.pinnedInterfaceWaitSeconds) {
                        if case .dns? = lastWaitError {
                            abortDial("DNS lookup for \(host) failed over \(pinned.label) after \(Self.pinnedInterfaceWaitSeconds)s")
                        } else if pinned == .vpn {
                            // The tunnel exists (or Bind to VPN would have refused up front) but isn't passing traffic — usually
                            // a brief drop while it reconnects — so don't claim the interface is missing.
                            abortDial("VPN tunnel unavailable after \(Self.pinnedInterfaceWaitSeconds)s")
                        } else {
                            abortDial("no \(pinned.label) interface available after \(Self.pinnedInterfaceWaitSeconds)s")
                        }
                    }
                }
            case .failed(let error):
                let errorText = ErrorDescription.describe(error)
                DebugLog.important("server", tunnel: self.id, "state FAILED \(errorText) attempt=\(attempt) didOpen=\(self.didOpen) \(self.progressText()) openTunnels=\(self.openTunnelCount()) path: \(PathDescription.describe(server.currentPath))")
                self.onActivity?("outbound \(host):\(port) FAILED: \(errorText)")
                if !self.didOpen && attempt < self.retryAttempts {
                    let delay = self.retryBaseSeconds * Double(1 << attempt) // e.g. 1s, 2s, 4s
                    DebugLog.important("server", tunnel: self.id, "retrying \(host):\(port) in \(delay)s (attempt \(attempt + 1) of \(self.retryAttempts))")
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
            let onSendError: (NWError?) -> Void = { [weak self] error in
                guard let self = self, let error = error else { return }
                DebugLog.important("data", tunnel: self.id, "early data send error \(ErrorDescription.describe(error))")
            }
            if AntiDPI.isEnabled {
                AntiDPI.send(earlyData, over: server, queue: queue, isHandshake: true, completion: onSendError)
            } else {
                server.send(content: earlyData, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed(onSendError))
            }
        }
        forward(from: client, to: server, isUpstream: true)
        forward(from: server, to: client, isUpstream: false)
    }

    /// Outstanding-bytes cap per direction for pipelined reads (below) —
    /// roughly the bandwidth-delay product of a decent connection at typical
    /// internet RTTs. Bounds worst-case buffering the same way the old
    /// one-chunk-at-a-time design did, just with a throughput-shaped window
    /// instead of a throughput-crippling one.
    private static let maxInFlightBytesPerDirection = 512 * 1024

    private func inFlightBytes(isUpstream: Bool) -> Int {
        isUpstream ? inFlightBytesUp : inFlightBytesDown
    }

    private func addInFlightBytes(_ delta: Int, isUpstream: Bool) {
        if isUpstream { inFlightBytesUp += delta } else { inFlightBytesDown += delta }
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
            if isUpstream && self.sniffPending {
                self.sniffPending = false
                self.sniffedHost = self.sniffedHost ?? TrafficSniffer.extractHost(from: data)
            }
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

            // Pipelined backpressure: several chunks may be in flight per
            // direction at once (bounded by inFlightBytes), instead of
            // strict one-chunk-at-a-time waiting — turns stop-and-wait into
            // a sliding window so a single connection isn't capped at
            // chunk_size/RTT. Anti-DPI's continuous fragmentation jitters
            // *between fragments of one chunk* via asyncAfter, so pipelining
            // a second chunk's fragmented send concurrently could interleave
            // them out of order on the wire — only pipeline when that can't
            // happen. Never pipeline the chunk carrying the FIN (isComplete)
            // — nothing more to read from an already-finished source.
            let canPipeline = !(isUpstream && AntiDPI.isEnabled)
            let pipelinedRead = canPipeline && !isComplete
                && self.inFlightBytes(isUpstream: isUpstream) < Self.maxInFlightBytesPerDirection
            self.sendsInFlight += 1
            self.addInFlightBytes(count, isUpstream: isUpstream)
            if pipelinedRead {
                self.forward(from: source, to: destination, isUpstream: isUpstream)
            }

            let sendStart = DispatchTime.now()
            let doSend = { [weak self] in
                guard let self else { return }
                let onSendComplete: (NWError?) -> Void = { [weak self] sendError in
                    guard let self = self else { return }
                    self.sendsInFlight -= 1
                    self.addInFlightBytes(-count, isUpstream: isUpstream)
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
                    } else if !pipelinedRead {
                        self.forward(from: source, to: destination, isUpstream: isUpstream)
                    }
                }
                if isUpstream && AntiDPI.isEnabled {
                    AntiDPI.send(data, over: destination, queue: self.queue, isHandshake: false, completion: onSendComplete)
                } else {
                    destination.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed(onSendComplete))
                }
            }
            // A device-level bandwidth cap: delay the send instead of sending
            // immediately, so the long-run rate stays at the cap.
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

    func sendErrorAndClose() {
        client.send(
            content: Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
            completion: .contentProcessed { [weak self] _ in
                self?.cleanup(.badRequest)
            }
        )
    }

    func cleanup(_ reason: CloseReason) {
        guard !cleanedUp else { return }
        cleanedUp = true
        heartbeat?.cancel()
        heartbeat = nil

        let firstByte = firstByteDownAt.map { Self.ms(from: readyAt ?? acceptedAt, to: $0) } ?? "never"
        let firstByteToClient = firstByteToClientAt.map { Self.ms(from: acceptedAt, to: $0) } ?? "never"
        let geo = destinationIP.flatMap { GeoIPLookup.shared.lookup($0) }
        let geoText = geo.map { "\($0.countryCode)\($0.city.map { "/\($0)" } ?? "")" } ?? "none"
        DebugLog.important("tunnel", tunnel: id, "CLOSED reason=\(reason.text) target=\(target) mode=\(modeName) remote=\(remoteAddress) sniffedHost=\(sniffedHost ?? "none") geo=\(geoText) iface=\(serverInterfaces) lifetime=\(Self.ms(since: acceptedAt)) sinceReady=\(msSinceReady()) firstByteDown=\(firstByte) firstByteToClient=\(firstByteToClient) up=\(bytesUp)B/\(chunksUp)chunks down=\(bytesDown)B/\(chunksDown)chunks openTunnels=\(openTunnelCount())")

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
                                          durationMs: durationMs, closedAt: Date(), reason: reason.text,
                                          destinationIP: destinationIP, sniffedHost: sniffedHost,
                                          countryCode: geo?.countryCode, countryName: geo?.countryName, city: geo?.city))
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
}
