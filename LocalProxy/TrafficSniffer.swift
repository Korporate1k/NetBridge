import Foundation

/// Best-effort "what's the real destination host" guess for a connection
/// whose target was only ever given to the proxy as an IP literal. Looks at
/// a single already-buffered chunk (normally the client's first upstream
/// bytes after the CONNECT/SOCKS5 handshake) — never waits for more data, so
/// it adds no latency to the relay path (see `Tunnel`'s `sniffPending` in
/// `ConnectProxyHandler.swift`). Returns `nil` rather than a wrong guess for
/// anything it can't confidently parse from that one chunk.
enum TrafficSniffer {
    private static let crlfcrlf = Data("\r\n\r\n".utf8)

    static func extractHost(from data: Data) -> String? {
        if let sni = TLSClientHello.extractSNI(from: data) {
            return sni
        }
        return extractHTTPHost(from: data)
    }

    /// Plain-HTTP `Host:` header — only for cleartext HTTP CONNECT'd to a raw
    /// IP (the common HTTPS-via-SNI case is handled above). Requires a
    /// complete `\r\n\r\n`-terminated header block already present in `data`;
    /// a request whose headers straddle two chunks is simply not sniffed.
    private static func extractHTTPHost(from data: Data) -> String? {
        guard let headerEnd = data.range(of: crlfcrlf) else { return nil }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let requestLine = lines.first else { return nil }

        // Sanity-check it looks like an HTTP request line, to avoid treating
        // arbitrary binary that happens to contain CRLFCRLF as HTTP.
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/") else { return nil }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Host") == .orderedSame else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            // Strip a ":port" suffix if present, matching what a real Host
            // header carries; a bracketed IPv6 host has its brackets removed
            // too, same convention as `HTTPFrontend.parseConnect`.
            if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
                return String(value[value.index(after: value.startIndex)..<close])
            }
            if let colonIndex = value.lastIndex(of: ":") {
                return String(value[value.startIndex..<colonIndex])
            }
            return String(value)
        }
        return nil
    }
}
