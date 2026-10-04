import Foundation

/// Front-end-specific metadata for a `.connect` request: what to call this
/// mode in logs/the dashboard, and what bytes to send the client once the
/// outbound dial resolves. Both HTTP CONNECT and SOCKS5 CONNECT produce a
/// `.connect` request and share `Tunnel`'s dial/pipe machinery — only these
/// reply bytes differ.
struct ConnectMeta {
    let label: String
    let successReply: Data
    /// `nil` preserves HTTP CONNECT's original behavior: on a connect
    /// failure, the connection is simply closed with no reply sent.
    let failureReply: Data?
}

/// What a client's initial request means, independent of which front-end
/// protocol produced it. Replaces the old private `Tunnel.Mode` enum so the
/// SOCKS5 front end can produce the same `.connect` case HTTP does without
/// `Tunnel`'s outbound-dial logic needing to know which front end a request
/// came from.
enum ProxyRequest {
    /// CONNECT-style: reply per `meta`, then relay opaque bytes both ways.
    /// `earlyData` is any client bytes already buffered past the request
    /// itself (e.g. a TLS ClientHello sent immediately after CONNECT).
    case connect(host: String, port: UInt16, earlyData: Data, meta: ConnectMeta)
    /// Plain-HTTP absolute-URI forward: no synthetic reply — `rawRequest` is
    /// forwarded to the origin verbatim, and the origin's real response is
    /// what flows back once relaying starts.
    case httpForward(host: String, port: UInt16, rawRequest: Data)
    /// An `https://` absolute-URI request sent to us in the clear: this device
    /// makes the TLS connection to the origin itself (Network.framework, i.e.
    /// the iOS ClientHello) and relays the plaintext response back. `rawRequest`
    /// is already rewritten to origin-form with an iOS-style header set — see
    /// `HTTPSOffload`.
    case httpsForward(host: String, port: UInt16, rawRequest: Data)
}

/// Rewrites a client's `GET https://host/path HTTP/1.1` request into what an iOS
/// HTTP client would send to the origin: origin-form request line and the
/// CFNetwork-style header set/order. Headers that carry meaning for the transfer
/// (`Range`, `If-Range`, `Cookie`, `Authorization`, `Referer`, body headers ...)
/// pass through unchanged; the client's own `User-Agent`, `Accept`,
/// `Accept-Language`, `Connection` and proxy headers are replaced.
///
/// `Accept-Encoding` stays `identity` on purpose: the client writes the body
/// straight to disk and never decodes it, and a compressed response to a
/// `Range` request would corrupt the file.
enum HTTPSOffload {
    private static let crlfcrlf = Data("\r\n\r\n".utf8)
    private static let replaced: Set<String> = [
        "host", "user-agent", "accept", "accept-language", "accept-encoding",
        "connection", "proxy-connection", "proxy-authorization", "keep-alive",
    ]

    static var userAgent: String {
        #if os(iOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion)_\(v.minorVersion)"
        let safari = "\(v.majorVersion).\(v.minorVersion)"
        #else
        let os = "18_6", safari = "18.6"
        #endif
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Mobile/15E148 Safari/604.1"
    }

    /// `nil` if `block` is not a parseable absolute-form `https://` request.
    static func parse(_ block: Data) -> (host: String, port: UInt16)? {
        guard let line = requestLine(block),
              line.target.lowercased().hasPrefix("https://"),
              let comps = URLComponents(string: line.target),
              let host = comps.host, !host.isEmpty,
              let port = UInt16(exactly: comps.port ?? 443) else { return nil }
        return (host, port)
    }

    static func rewrite(_ block: Data) -> Data {
        guard let end = block.range(of: crlfcrlf),
              let head = String(data: block[..<end.lowerBound], encoding: .utf8),
              let line = requestLine(block),
              let comps = URLComponents(string: line.target), let host = comps.host else { return block }
        var path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let q = comps.percentEncodedQuery { path += "?" + q }
        let port = comps.port ?? 443
        let hostName = host.contains(":") ? "[\(host)]" : host
        let hostHeader = port == 443 ? hostName : "\(hostName):\(port)"

        var out = "\(line.method) \(path) \(line.version)\r\n"
        out += "Host: \(hostHeader)\r\nAccept: */*\r\n"
        for header in head.components(separatedBy: "\r\n").dropFirst() where !header.isEmpty {
            guard let colon = header.firstIndex(of: ":") else { continue }
            if replaced.contains(header[..<colon].lowercased()) { continue }
            out += header + "\r\n"
        }
        out += "User-Agent: \(userAgent)\r\nAccept-Language: en-US,en;q=0.9\r\n"
        out += "Accept-Encoding: identity\r\nConnection: keep-alive\r\n\r\n"
        var data = Data(out.utf8)
        data.append(block[end.upperBound...])   // any body bytes read along with the headers
        return data
    }

    private static func requestLine(_ block: Data) -> (method: String, target: String, version: String)? {
        guard let end = block.range(of: crlfcrlf),
              let first = String(data: block[..<end.lowerBound], encoding: .utf8)?
                .components(separatedBy: "\r\n").first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] != "CONNECT" else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }
}

/// HTTP CONNECT / plain-HTTP absolute-URI request-line parsing, moved out of
/// `Tunnel` verbatim (no behavior change) so it can live alongside future
/// front ends (e.g. SOCKS5) as a peer instead of being buried inside the
/// tunnel's I/O code.
enum HTTPFrontend {
    private static let crlfcrlf = Data("\r\n\r\n".utf8)

    /// `headerBlock` must already contain a full `\r\n\r\n`-terminated header
    /// section — the caller (`Tunnel`) buffers until then itself, since that
    /// buffering is shared with logging/size-limit checks that apply
    /// regardless of what kind of request this turns out to be.
    static func parse(_ headerBlock: Data) -> ProxyRequest? {
        if let target = parseConnect(from: headerBlock) {
            let meta = ConnectMeta(
                label: "CONNECT",
                successReply: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                failureReply: nil
            )
            return .connect(host: target.host, port: target.port, earlyData: dataAfterHeaders(in: headerBlock), meta: meta)
        }
        if let target = HTTPSOffload.parse(headerBlock) {
            return .httpsForward(host: target.host, port: target.port, rawRequest: HTTPSOffload.rewrite(headerBlock))
        }
        if let target = parseAbsoluteURI(from: headerBlock) {
            return .httpForward(host: target.host, port: target.port, rawRequest: headerBlock)
        }
        return nil
    }

    static func parseConnect(from data: Data) -> (host: String, port: UInt16)? {
        guard let headerEnd = data.range(of: crlfcrlf) else { return nil }
        guard let requestLine = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)?
            .split(separator: "\r\n", omittingEmptySubsequences: true)
            .first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "CONNECT" else { return nil }

        var authority = String(parts[1])
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let host = authority[authority.index(after: authority.startIndex)..<close]
            let rest = authority[authority.index(after: close)...]
            authority = String(host) + String(rest)
        }

        guard let colon = authority.lastIndex(of: ":") else { return nil }
        let host = String(authority[..<colon])
        let portString = String(authority[authority.index(after: colon)...])
        guard let port = UInt16(portString), port > 0 else { return nil }
        return (host, port)
    }

    /// Parses a proxy-style absolute-URI request line, e.g. `GET http://host/path
    /// HTTP/1.1` — what a client sends to an explicit HTTP proxy for a plain-HTTP
    /// (non-CONNECT) target.
    static func parseAbsoluteURI(from data: Data) -> (host: String, port: UInt16)? {
        guard let headerEnd = data.range(of: crlfcrlf) else { return nil }
        guard let requestLine = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)?
            .split(separator: "\r\n", omittingEmptySubsequences: true)
            .first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] != "CONNECT" else { return nil }

        let uriString = String(parts[1])
        guard uriString.lowercased().hasPrefix("http://"),
              let url = URL(string: uriString),
              let host = url.host,
              let port = UInt16(exactly: url.port ?? 80) else { return nil }

        return (host, port)
    }

    static func dataAfterHeaders(in data: Data) -> Data {
        guard let headerEnd = data.range(of: crlfcrlf) else { return Data() }
        return Data(data[headerEnd.upperBound...])
    }
}
