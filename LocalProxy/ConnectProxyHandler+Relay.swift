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

            // Backpressure: re-arm the read only after this chunk is handed off,
            // so a slow destination can't cause unbounded buffering.
            self.sendsInFlight += 1
            let sendStart = DispatchTime.now()
            let doSend = { [weak self] in
                guard let self else { return }
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
