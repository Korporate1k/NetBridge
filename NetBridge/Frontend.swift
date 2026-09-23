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
