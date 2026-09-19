import Foundation
import Network

extension Tunnel {
    // MARK: - Diagnostics helpers

    func startHeartbeat() {
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

    func logEstablishmentReport(_ server: NWConnection) {
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

    func progressText() -> String {
        "sinceRequest=\(msSinceRequest()) sinceReady=\(msSinceReady()) up=\(bytesUp)B down=\(bytesDown)B"
    }

    func msSinceRequest() -> String { requestAt.map { Self.ms(since: $0) } ?? "n/a" }
    func msSinceReady() -> String { readyAt.map { Self.ms(since: $0) } ?? "n/a" }

    static func ms(since start: DispatchTime) -> String {
        ms(from: start, to: DispatchTime.now())
    }

    static func ms(from start: DispatchTime, to end: DispatchTime) -> String {
        String(format: "%.1fms", Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    static func ms(_ interval: TimeInterval) -> String {
        String(format: "%.1fms", interval * 1000)
    }

    /// Request line + headers on one line, with credential-bearing header values redacted.
    static func headerText(_ data: Data) -> String {
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

    static func escaped(_ data: Data) -> String {
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
