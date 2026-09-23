import Foundation
import Network

/// A minimal hand-rolled SOCKS5 server used only by this test target — not
/// a reuse of NetBridge's own app-target server code (an SPM test target
/// can't depend on an Xcode app target), and deliberately simple: no-auth
/// only, echoes CONNECT traffic back, echoes UDP ASSOCIATE datagrams back.
/// Configurable failure modes let tests exercise each client-side error path.
final class MockSocks5Server {
    var rejectAuth = false
    var connectReplyCode: UInt8 = 0x00
    var associateReplyCode: UInt8 = 0x00
    var closeBeforeMethodSelection = false

    private(set) var port: UInt16 = 0

    private var listener: NWListener!
    private var udpListener: NWListener?
    private var udpClientConnection: NWConnection?
    private var lastControlConnection: NWConnection?
    private let queue = DispatchQueue(label: "mock-socks5-server")

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleControl(connection)
        }
        listener.start(queue: queue)
        ready.wait()
        port = listener.port.map { UInt16($0.rawValue) } ?? 0
    }

    func stop() {
        listener?.cancel()
        udpListener?.cancel()
        udpClientConnection?.cancel()
        lastControlConnection?.cancel()
    }

    /// Simulates the server unexpectedly dropping the UDP ASSOCIATE control
    /// connection, to test that the client tears down the UDP leg too.
    func dropControlConnection() {
        queue.async { [weak self] in
            self?.lastControlConnection?.cancel()
        }
    }

    // MARK: - Control connection: greeting + request

    private func handleControl(_ connection: NWConnection) {
        lastControlConnection = connection
        connection.start(queue: queue)
        readGreeting(connection, buffer: Data())
    }

    private func readGreeting(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self, error == nil else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            guard buf.count >= 2 else {
                self.readGreeting(connection, buffer: buf)
                return
            }
            let base = buf.startIndex
            let nMethods = Int(buf[base + 1])
            let total = 2 + nMethods
            guard buf.count >= total else {
                self.readGreeting(connection, buffer: buf)
                return
            }
            let remainder = Data(buf[(base + total)...])

            if self.closeBeforeMethodSelection {
                connection.cancel()
                return
            }
            if self.rejectAuth {
                connection.send(content: Data([0x05, 0xFF]), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            connection.send(content: Data([0x05, 0x00]), completion: .contentProcessed { [weak self] _ in
                self?.readRequest(connection, buffer: remainder)
            })
        }
    }

    private enum RequestParseResult {
        case needMoreData
        case parsed(command: UInt8)
    }

    private static func parseRequestHeader(_ data: Data) -> RequestParseResult {
        let base = data.startIndex
        guard data.count >= 4 else { return .needMoreData }
        let cmd = data[base + 1]
        let atyp = data[base + 3]
        var offset = base + 4
        switch atyp {
        case 0x01:
            guard data.count >= (offset - base) + 4 + 2 else { return .needMoreData }
            offset += 4
        case 0x03:
            guard data.count > offset - base else { return .needMoreData }
            let len = Int(data[offset])
            offset += 1
            guard data.count >= (offset - base) + len + 2 else { return .needMoreData }
            offset += len
        case 0x04:
            guard data.count >= (offset - base) + 16 + 2 else { return .needMoreData }
            offset += 16
        default:
            return .parsed(command: cmd)
        }
        return .parsed(command: cmd)
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self, error == nil else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            switch Self.parseRequestHeader(buf) {
            case .needMoreData:
                self.readRequest(connection, buffer: buf)
            case .parsed(let command):
                if command == 0x01 {
                    self.completeConnect(connection)
                } else if command == 0x03 {
                    self.completeAssociate(connection)
                } else {
                    connection.send(content: Self.buildReply(code: 0x07), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    // MARK: - CONNECT

    private func completeConnect(_ connection: NWConnection) {
        let reply = Self.buildReply(code: connectReplyCode)
        connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            if self.connectReplyCode == 0x00 {
                self.echoLoop(connection)
            } else {
                connection.cancel()
            }
        })
    }

    private func echoLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if error == nil && !isComplete {
                self.echoLoop(connection)
            }
        }
    }

    // MARK: - UDP ASSOCIATE

    private func completeAssociate(_ connection: NWConnection) {
        guard associateReplyCode == 0x00 else {
            connection.send(content: Self.buildReply(code: associateReplyCode), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        do {
            let udpListener = try NWListener(using: .udp, on: .any)
            self.udpListener = udpListener
            udpListener.newConnectionHandler = { [weak self] conn in
                self?.acceptUDPClient(conn)
            }
            // Event-driven, not blocking: this whole method already runs on
            // `queue` (the connection's callback queue), and this listener's
            // own state updates are also dispatched on `queue` — a
            // `DispatchSemaphore.wait()` here for `.ready` would deadlock
            // the very queue needed to deliver that state change.
            udpListener.stateUpdateHandler = { [weak self] state in
                guard self != nil else { return }
                switch state {
                case .ready:
                    let udpPort = udpListener.port.map { UInt16($0.rawValue) } ?? 0
                    let reply = Self.buildAssociateReply(host: "127.0.0.1", port: udpPort)
                    connection.send(content: reply, completion: .contentProcessed { _ in })
                    // Control connection stays open (no further reads) so
                    // the client can only observe a close when the test
                    // explicitly drops it via `dropControlConnection()`.
                case .failed:
                    connection.send(content: Self.buildReply(code: 0x01), completion: .contentProcessed { _ in connection.cancel() })
                default:
                    break
                }
            }
            udpListener.start(queue: queue)
        } catch {
            connection.send(content: Self.buildReply(code: 0x01), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func acceptUDPClient(_ connection: NWConnection) {
        udpClientConnection = connection
        connection.start(queue: queue)
        receiveUDP(connection)
    }

    /// Echoes each wrapped datagram back verbatim, unless its payload is the
    /// `"TRIGGER_MALFORMED"` marker (used to test that the client silently
    /// drops an unparseable reply instead of crashing), in which case it
    /// replies with a too-short, unparseable datagram instead.
    private func receiveUDP(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, error == nil else { return }
            if let data = data, !data.isEmpty {
                if Self.unwrapIPv4Payload(data) == Data("TRIGGER_MALFORMED".utf8) {
                    connection.send(content: Data([0, 0]), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
                } else {
                    connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
                }
            }
            self.receiveUDP(connection)
        }
    }

    /// Extracts the payload from a client-built datagram whose DST.ADDR is
    /// IPv4 (the only address type this test suite sends) — enough for the
    /// malformed-reply trigger above; not a general-purpose parser.
    private static func unwrapIPv4Payload(_ data: Data) -> Data? {
        let base = data.startIndex
        guard data.count >= 10, data[base + 3] == 0x01 else { return nil }
        return Data(data[(base + 10)...])
    }

    // MARK: - Reply building (server role — hand-rolled here, not shared
    // with `Socks5ClientWire`, which only builds the client role's frames)

    private static func buildReply(code: UInt8) -> Data {
        Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    private static func buildAssociateReply(host: String, port: UInt16) -> Data {
        var out = Data([0x05, 0x00, 0x00, 0x01])
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        out.append(contentsOf: octets.count == 4 ? octets : [0, 0, 0, 0])
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }
}
