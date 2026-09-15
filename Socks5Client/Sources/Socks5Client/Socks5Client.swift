import Foundation
import Network

/// A SOCKS5 client (RFC 1928, no-auth only): dials a SOCKS5 proxy server and
/// performs either a CONNECT (handing back a live `NWConnection` to the
/// destination) or a UDP ASSOCIATE (handing back a `Socks5UDPAssociation`).
///
/// Closure-based throughout, matching this codebase's existing
/// `NWConnection`-driven style rather than async/await — there's no
/// structured-concurrency benefit here worth diverging from that idiom for a
/// two-round-trip handshake.
public final class Socks5Client {
    public struct Endpoint {
        public let host: String
        public let port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    /// No-op by default. Set to route diagnostics through a host app's own
    /// logging (e.g. `{ DebugLog.debug("socks5client", $0) }`) — this
    /// package has no logging dependency of its own.
    public var logHandler: ((String) -> Void)?

    private let proxy: Endpoint
    private let queue: DispatchQueue
    private let parameters: NWParameters

    public init(proxy: Endpoint, queue: DispatchQueue = DispatchQueue(label: "socks5client"), parameters: NWParameters? = nil) {
        self.proxy = proxy
        self.queue = queue
        self.parameters = parameters ?? .socks5ClientDefault()
    }

    /// Dials the proxy, performs the no-auth greeting + CONNECT request, and
    /// hands back the live connection once the server replies success. The
    /// caller then owns it for relaying, same as `DirectTCPTransport.dial()`
    /// callers do server-side.
    public func connect(
        destinationHost: String,
        destinationPort: UInt16,
        completion: @escaping (Result<NWConnection, Socks5ClientError>) -> Void
    ) {
        let connection = dial()
        // Captured strongly throughout this call chain, deliberately: this
        // is a single bounded operation (dial + two-round-trip handshake),
        // not a long-lived subscription, so there's no retain-cycle risk in
        // keeping `self` alive until it completes — a caller that does
        // `Socks5Client(proxy:).connect(...)` without storing the instance
        // must still see the operation through.
        handshake(connection) { handshakeResult in
            switch handshakeResult {
            case .failure(let error):
                connection.cancel()
                completion(.failure(error))
            case .success:
                self.performRequest(connection, command: .connect, host: destinationHost, port: destinationPort) { result in
                    switch result {
                    case .failure(let error):
                        connection.cancel()
                        completion(.failure(error))
                    case .success:
                        completion(.success(connection))
                    }
                }
            }
        }
    }

    /// Performs the no-auth greeting + UDP ASSOCIATE request over a new TCP
    /// control connection, then wires up the UDP relay connection at the
    /// address the server names in its reply.
    public func associateUDP(completion: @escaping (Result<Socks5UDPAssociation, Socks5ClientError>) -> Void) {
        let control = dial()
        // Same deliberate strong-`self` reasoning as `connect()` above.
        handshake(control) { handshakeResult in
            switch handshakeResult {
            case .failure(let error):
                control.cancel()
                completion(.failure(error))
            case .success:
                // Client's own DST.ADDR/DST.PORT in the request are ignored
                // by servers that haven't required a fixed source (the
                // conventional 0.0.0.0:0 "not yet bound" placeholder).
                self.performRequest(control, command: .udpAssociate, host: "0.0.0.0", port: 0) { result in
                    switch result {
                    case .failure(let error):
                        control.cancel()
                        completion(.failure(error))
                    case .success(let bound):
                        guard let relayPort = NWEndpoint.Port(rawValue: bound.port) else {
                            control.cancel()
                            completion(.failure(.malformedReply))
                            return
                        }
                        let udpConnection = NWConnection(host: NWEndpoint.Host(bound.host), port: relayPort, using: .udp)
                        let association = Socks5UDPAssociation(
                            controlConnection: control,
                            udpConnection: udpConnection,
                            queue: self.queue,
                            logHandler: self.logHandler
                        )
                        association.start()
                        completion(.success(association))
                    }
                }
            }
        }
    }

    // MARK: - Handshake internals

    private func dial() -> NWConnection {
        let port = NWEndpoint.Port(rawValue: proxy.port) ?? .any
        return NWConnection(host: NWEndpoint.Host(proxy.host), port: port, using: parameters)
    }

    private func handshake(_ connection: NWConnection, completion: @escaping (Result<Void, Socks5ClientError>) -> Void) {
        waitUntilReady(connection) { readyResult in
            switch readyResult {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.send(Socks5ClientWire.buildGreeting(), on: connection) { sendError in
                    if let sendError = sendError {
                        completion(.failure(sendError))
                        return
                    }
                    self.receiveLoop(connection: connection, parse: { data -> ParseStep<Void> in
                        switch Socks5ClientWire.parseMethodSelection(data) {
                        case .needMoreData: return .needMoreData
                        case .ok: return .success(())
                        case .rejected: return .failure(.noAcceptableAuthMethod)
                        case .invalidVersion(let version): return .failure(.unexpectedProtocolVersion(version))
                        }
                    }, completion: completion)
                }
            }
        }
    }

    private func performRequest(
        _ connection: NWConnection,
        command: Socks5ClientWire.Command,
        host: String,
        port: UInt16,
        completion: @escaping (Result<(host: String, port: UInt16), Socks5ClientError>) -> Void
    ) {
        let request = Socks5ClientWire.buildRequest(command: command, host: host, port: port)
        send(request, on: connection) { sendError in
            if let sendError = sendError {
                completion(.failure(sendError))
                return
            }
            self.receiveLoop(connection: connection, parse: { data -> ParseStep<(host: String, port: UInt16)> in
                switch Socks5ClientWire.parseReply(data) {
                case .needMoreData: return .needMoreData
                case .invalid: return .failure(.malformedReply)
                case .invalidVersion(let version): return .failure(.unexpectedProtocolVersion(version))
                case .parsed(let code, let bindHost, let bindPort, _):
                    return code == 0x00 ? .success((bindHost, bindPort)) : .failure(.from(replyCode: code))
                }
            }, completion: completion)
        }
    }

    private func waitUntilReady(_ connection: NWConnection, completion: @escaping (Result<Void, Socks5ClientError>) -> Void) {
        var resolved = false
        connection.stateUpdateHandler = { state in
            guard !resolved else { return }
            switch state {
            case .ready:
                resolved = true
                completion(.success(()))
            case .failed(let error):
                resolved = true
                completion(.failure(.dialFailed(error)))
            case .waiting(let error):
                // Network.framework treats e.g. "connection refused" as
                // transient and parks here indefinitely, retrying on its own
                // schedule, rather than moving to `.failed` — appropriate
                // for a long-lived app connection, wrong for a one-shot
                // proxy dial. Fail fast instead of hanging forever.
                resolved = true
                connection.cancel()
                completion(.failure(.dialFailed(error)))
            case .cancelled:
                resolved = true
                completion(.failure(.connectionClosed))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func send(_ data: Data, on connection: NWConnection, completion: @escaping (Socks5ClientError?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error.map { .sendFailed($0) })
        })
    }

    private enum ParseStep<T> {
        case needMoreData
        case failure(Socks5ClientError)
        case success(T)
    }

    private func receiveLoop<T>(
        connection: NWConnection,
        accumulated: Data = Data(),
        parse: @escaping (Data) -> ParseStep<T>,
        completion: @escaping (Result<T, Socks5ClientError>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let error = error {
                completion(.failure(.receiveFailed(error)))
                return
            }
            var buffer = accumulated
            if let data = data { buffer.append(data) }
            switch parse(buffer) {
            case .needMoreData:
                if isComplete {
                    completion(.failure(.connectionClosed))
                } else {
                    self.receiveLoop(connection: connection, accumulated: buffer, parse: parse, completion: completion)
                }
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                completion(.success(value))
            }
        }
    }
}
