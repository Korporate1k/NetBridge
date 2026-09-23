import Foundation
import Network

/// One client-side SOCKS5 UDP ASSOCIATE session: a TCP control connection
/// (kept open only to detect the server ending the association, per RFC
/// 1928 — a compliant server tears down its relay when this connection
/// closes) plus a UDP connection to the relay address the server named in
/// its ASSOCIATE reply.
///
/// If the control connection drops, the UDP leg is cancelled immediately
/// rather than left dangling for the caller to notice — continuing to send
/// on it past that point would silently blackhole.
public final class Socks5UDPAssociation {
    /// Fires once, when the association ends (control connection closed,
    /// UDP connection failed, or `cancel()` called with an explicit reason).
    public var onClose: ((Socks5ClientError?) -> Void)?

    private let controlConnection: NWConnection
    private let udpConnection: NWConnection
    private let queue: DispatchQueue
    private let logHandler: ((String) -> Void)?

    private var receiveHandler: ((String, UInt16, Data) -> Void)?

    /// Serialized sends on the one UDP connection this association owns —
    /// firing `NWConnection.send()` calls back-to-back before earlier ones
    /// complete does not queue reliably (the same issue NetBridge's own
    /// server-side `UDPRelay` documents and works around), so sends here are
    /// queued and drained one at a time.
    private var pendingSends: [(Data, (Socks5ClientError?) -> Void)] = []
    private var sendInFlight = false
    private var cancelled = false

    init(controlConnection: NWConnection, udpConnection: NWConnection, queue: DispatchQueue, logHandler: ((String) -> Void)?) {
        self.controlConnection = controlConnection
        self.udpConnection = udpConnection
        self.queue = queue
        self.logHandler = logHandler
    }

    func start() {
        udpConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .failed(let error) = state {
                self.log("UDP relay connection failed \(error)")
                self.cancel(reason: .receiveFailed(error))
            }
        }
        udpConnection.start(queue: queue)
        receiveFromRelay()
        watchControlConnectionForClose()
    }

    /// Sends one payload to `host:port` via the proxy's relay.
    public func send(payload: Data, to host: String, port: UInt16, completion: @escaping (Socks5ClientError?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.cancelled else {
                completion(.connectionClosed)
                return
            }
            let datagram = Socks5ClientWire.buildUDPDatagram(host: host, port: port, payload: payload)
            self.pendingSends.append((datagram, completion))
            self.sendNext()
        }
    }

    /// Registers the handler for incoming relayed datagrams. Set once;
    /// called repeatedly, one call per datagram.
    public func onReceive(_ handler: @escaping (String, UInt16, Data) -> Void) {
        queue.async { [weak self] in
            self?.receiveHandler = handler
        }
    }

    /// Tears down both the UDP connection and the TCP control connection.
    public func cancel() {
        queue.async { [weak self] in
            self?.cancel(reason: nil)
        }
    }

    // MARK: - Relay side

    private func receiveFromRelay() {
        udpConnection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, !self.cancelled else { return }
            if let error = error {
                self.log("UDP relay receive error \(error)")
                self.cancel(reason: .receiveFailed(error))
                return
            }
            if let data = data, !data.isEmpty {
                switch Socks5ClientWire.parseUDPDatagram(data) {
                case .invalid:
                    self.log("dropped unparseable UDP datagram from relay, \(data.count) bytes")
                case .parsed(let host, let port, let payload):
                    self.receiveHandler?(host, port, payload)
                }
            }
            self.receiveFromRelay()
        }
    }

    private func sendNext() {
        guard !sendInFlight, !pendingSends.isEmpty else { return }
        let (payload, completion) = pendingSends.removeFirst()
        sendInFlight = true
        udpConnection.send(content: payload, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            self.sendInFlight = false
            completion(error.map { .sendFailed($0) })
            self.sendNext()
        })
    }

    // MARK: - Control connection (detects server-side close only)

    private func watchControlConnectionForClose() {
        controlConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed(let error):
                self.cancel(reason: .receiveFailed(error))
            case .cancelled:
                self.cancel(reason: .connectionClosed)
            default:
                break
            }
        }
        // RFC 1928 defines no further traffic on the control connection
        // after the ASSOCIATE reply besides its eventual close — this read
        // exists purely to detect that close (EOF or error), never to
        // consume real data.
        controlConnection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self = self else { return }
            if error != nil || isComplete {
                self.cancel(reason: .connectionClosed)
            }
        }
    }

    // MARK: - Teardown

    private func cancel(reason: Socks5ClientError?) {
        guard !cancelled else { return }
        cancelled = true
        udpConnection.cancel()
        controlConnection.cancel()
        let sends = pendingSends
        pendingSends.removeAll()
        for (_, completion) in sends {
            completion(.connectionClosed)
        }
        onClose?(reason)
    }

    private func log(_ message: String) {
        logHandler?(message)
    }

    deinit {
        udpConnection.cancel()
        controlConnection.cancel()
    }
}
