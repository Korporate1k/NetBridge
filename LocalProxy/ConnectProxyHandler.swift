import Foundation
import Network

/// Handles one client connection end-to-end over Network.framework: parses the
/// request via a `Frontend` (today, `HTTPFrontend` — see `Frontend.swift`),
/// dials the outbound connection via a `DirectTCPTransport` (see
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
        case egressChanged(String)
        case udpAssociateClosed(String)
        case authenticationFailed

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
            case .egressChanged(let why): return "egressChanged(\(why))"
            case .udpAssociateClosed(let d): return "udpAssociateClosed(\(d))"
            case .authenticationFailed: return "authenticationFailed (SOCKS5 RFC1929 auth rejected)"
            }
        }
    }

    let id: Int
    let client: NWConnection
    let queue: DispatchQueue
    let stats: ProxyStats
    let transport: DirectTCPTransport
    private let forcedProtocol: ListenerMode
    let rateLimiter: RateLimiter?
    /// Opt-in RFC 1929 credential requirement for this connection's SOCKS5
    /// greeting — `nil` (the default) means no-auth only, identical to this
    /// project's original behavior. Set from `ProxyServer.requiredUsername`/
    /// `requiredPassword` when both are non-empty.
    let requiredCredentials: (username: String, password: String)?
    /// Remote-configurable outbound dial resiliency — see `ProxyServer.outboundRetryAttempts`/`outboundRetryBaseSeconds`.
    let retryAttempts: Int
    let retryBaseSeconds: Double
    var onClose: (() -> Void)?
    var onActivity: ((String) -> Void)?
    /// Called once per request with the destination host (used to recognize devices).
    var onTarget: ((String) -> Void)?
    /// Called once, when the tunnel finishes, with a summary for `ConnectionHistory`.
    var onSummary: ((ConnectionSummary) -> Void)?
    /// Supplied by `ProxyServer` so failure lines record how many tunnels were open.
    var openTunnelCount: () -> Int = { 0 }

    var server: NWConnection?
    var udpRelay: UDPRelay?
    private var requestBuffer = Data()
    var socks5Buffer = Data()
    var didOpen = false
    var cleanedUp = false
    var clientFinished = false
    var serverFinished = false

    // MARK: Diagnostics state (all mutated on `queue`)

    let acceptedAt = DispatchTime.now()
    var requestAt: DispatchTime?
    var readyAt: DispatchTime?
    var target = "?"
    var modeName = "?"
    var remoteAddress = "?"
    var serverInterfaces = "?"
    /// Only set for `.connect` requests whose host is an IP literal (a domain
    /// host is already human-readable, so sniffing adds nothing there). See
    /// `TrafficSniffer`.
    var sniffedHost: String?
    /// True until the first upstream chunk has been offered to the sniffer.
    /// One-shot: only the very first chunk is inspected, never later ones.
    var sniffPending = false
    /// Raw dialed remote IP (no port/brackets), for GeoIP lookup.
    var destinationIP: String?
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0
    var chunksUp = 0
    var chunksDown = 0
    var firstByteDownAt: DispatchTime?
    var firstByteToClientAt: DispatchTime?
    var lastDataAt = DispatchTime.now()
    var sendsInFlight = 0
    var heartbeat: DispatchSourceTimer?
    var beatBytesUp: UInt64 = 0
    var beatBytesDown: UInt64 = 0
    var stalled = false
    var transferReport: NWConnection.PendingDataTransferReport?
    var clientTransferReport: NWConnection.PendingDataTransferReport?

    static let maxHeaderBytes = 64 * 1024
    static let crlfcrlf = Data("\r\n\r\n".utf8)
    static let stallThresholdMs = 2000.0

    init(id: Int, client: NWConnection, queue: DispatchQueue, stats: ProxyStats, transport: DirectTCPTransport,
         forcedProtocol: ListenerMode = .auto, rateLimiter: RateLimiter? = nil,
         retryAttempts: Int = 3, retryBaseSeconds: Double = 1,
         requiredCredentials: (username: String, password: String)? = nil) {
        self.id = id
        self.client = client
        self.queue = queue
        self.stats = stats
        self.transport = transport
        self.forcedProtocol = forcedProtocol
        self.rateLimiter = rateLimiter
        self.retryAttempts = max(0, retryAttempts)
        self.retryBaseSeconds = max(0, retryBaseSeconds)
        self.requiredCredentials = requiredCredentials
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

    func cancel(reason: CloseReason = .proxyStopped) {
        queue.async { self.cleanup(reason) }
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
}
