import Foundation
import Network

extension Tunnel {
    // MARK: - SOCKS5 request

    /// Parses `socks5Buffer` as far as it goes; reads more from `client` only
    /// if needed. Callable both from the initial sniff (buffer already primed
    /// with the first chunk) and recursively once more data arrives.
    func receiveSocks5Greeting() {
        switch Socks5.parseGreeting(socks5Buffer, requireAuth: requiredCredentials != nil) {
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
        case .selectedNoAuth(let consumed):
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
        case .selectedUserPass(let consumed):
            socks5Buffer.removeFirst(consumed)
            DebugLog.important("client", tunnel: id, "SOCKS5 greeting selected username/password auth")
            client.send(content: Socks5.methodSelectionRequireAuth, completion: .contentProcessed { [weak self] sendError in
                guard let self = self else { return }
                if let sendError = sendError {
                    DebugLog.important("client", tunnel: self.id, "SOCKS5 method-selection send error \(ErrorDescription.describe(sendError))")
                    self.cleanup(.badRequest)
                    return
                }
                self.receiveSocks5Auth()
            })
        case .noAcceptableMethod(let consumed):
            socks5Buffer.removeFirst(consumed)
            DebugLog.important("client", tunnel: id, "SOCKS5 no acceptable auth method offered (required=\(requiredCredentials != nil))")
            client.send(content: Socks5.methodSelectionNoAcceptable, completion: .contentProcessed { [weak self] _ in
                self?.cleanup(.badRequest)
            })
        }
    }

    /// RFC 1929 username/password sub-negotiation, entered only after the
    /// greeting selected method `0x02` (i.e. this connection is configured
    /// via `requiredCredentials` to require auth). Mirrors
    /// `receiveSocks5Request()`'s own buffer/parse-loop shape for multi-chunk
    /// arrivals.
    private func receiveSocks5Auth() {
        switch Socks5.parseAuthRequest(socks5Buffer) {
        case .needMoreData:
            if socks5Buffer.count > Self.maxHeaderBytes {
                DebugLog.important("client", tunnel: id, "SOCKS5 auth request exceeds \(Self.maxHeaderBytes) bytes")
                cleanup(.authenticationFailed)
                return
            }
            client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    self.socks5Buffer.append(data)
                    self.receiveSocks5Auth()
                } else if isComplete || error != nil {
                    let detail = "SOCKS5 auth: bytesReceived=\(self.socks5Buffer.count) isComplete=\(isComplete) error=\(ErrorDescription.describe(error))"
                    DebugLog.important("client", tunnel: self.id, "client closed before sending a full SOCKS5 auth request: \(detail)")
                    self.cleanup(.clientClosedBeforeRequest(detail))
                }
            }
        case .invalid:
            DebugLog.important("client", tunnel: id, "UNPARSEABLE SOCKS5 auth request, first 512 bytes: \(Self.escaped(socks5Buffer.prefix(512)))")
            client.send(content: Socks5.authReply(success: false), completion: .contentProcessed { [weak self] _ in
                self?.cleanup(.authenticationFailed)
            })
        case .parsed(let username, let password, let consumed):
            socks5Buffer.removeFirst(consumed)
            // Never log the password itself — matches this file's existing
            // credential-redaction stance for HTTP headers (see `headerText`).
            let ok = requiredCredentials.map { $0.username == username && $0.password == password } ?? false
            DebugLog.important("client", tunnel: id, "SOCKS5 auth attempt user=\(username) result=\(ok ? "OK" : "REJECTED")")
            client.send(content: Socks5.authReply(success: ok), completion: .contentProcessed { [weak self] sendError in
                guard let self = self else { return }
                if let sendError = sendError {
                    DebugLog.important("client", tunnel: self.id, "SOCKS5 auth reply send error \(ErrorDescription.describe(sendError))")
                    self.cleanup(.badRequest)
                    return
                }
                if ok {
                    self.receiveSocks5Request()
                } else {
                    self.cleanup(.authenticationFailed)
                }
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
        let advertised = LocalAddress.localAddress(of: client)
        DebugLog.important("client", tunnel: id, "SOCKS5 UDP ASSOCIATE will advertise \(advertised ?? "primary interface (control-connection address unavailable)")")
        let relay = UDPRelay(id: id, queue: queue, stats: stats, rateLimiter: rateLimiter,
                             expectedClientKey: DeviceRegistry.deviceKey(for: client.endpoint),
                             advertisedHost: advertised)
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
}
