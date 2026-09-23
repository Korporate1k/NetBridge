import Foundation

/// RFC 1928 SOCKS5 wire-format parsing/reply-building — pure data
/// transformation, no networking. `Tunnel` drives the actual `NWConnection`
/// receive/send calls (in `ConnectProxyHandler.swift`) and feeds accumulated
/// bytes in here; kept separate and I/O-free so it can be hand-traced against
/// RFC 1928's byte layouts without a device or test target.
///
/// No-auth (`0x00`) is always accepted; RFC 1929 username/password (`0x02`)
/// is additionally supported when a connection is configured to require it
/// (see `ConnectProxyHandler.swift`'s `requiredCredentials` and
/// `ProxyServer.swift`'s opt-in `requiredUsername`/`requiredPassword`) —
/// matches the project's existing no-auth-by-default stance for its HTTP
/// front end, auth is opt-in only. Only `CONNECT` is implemented here;
/// `UDP ASSOCIATE` is parsed (so a client gets a clean "not supported" reply
/// instead of a hang) but not yet relayed.
enum Socks5 {
    // MARK: - Greeting / method selection

    enum GreetingResult {
        case needMoreData
        case selectedNoAuth(consumed: Int)
        case selectedUserPass(consumed: Int)
        case noAcceptableMethod(consumed: Int)
    }

    /// `data` is `VER(1)=0x05 | NMETHODS(1) | METHODS(NMETHODS)`. When
    /// `requireAuth` is true, only a client offering method `0x02`
    /// (username/password) is accepted; otherwise only `0x00` (no-auth) is —
    /// this project never negotiates down from required auth to no-auth.
    static func parseGreeting(_ data: Data, requireAuth: Bool) -> GreetingResult {
        let base = data.startIndex
        guard data.count >= 2 else { return .needMoreData }
        guard data[base] == 0x05 else { return .noAcceptableMethod(consumed: data.count) }
        let nMethods = Int(data[base + 1])
        let total = 2 + nMethods
        guard data.count >= total else { return .needMoreData }
        let methods = data[(base + 2)..<(base + total)]
        if requireAuth {
            return methods.contains(0x02) ? .selectedUserPass(consumed: total) : .noAcceptableMethod(consumed: total)
        }
        return methods.contains(0x00) ? .selectedNoAuth(consumed: total) : .noAcceptableMethod(consumed: total)
    }

    static let methodSelectionOK = Data([0x05, 0x00])
    static let methodSelectionRequireAuth = Data([0x05, 0x02])
    static let methodSelectionNoAcceptable = Data([0x05, 0xFF])

    // MARK: - RFC 1929 username/password auth sub-negotiation

    enum AuthRequestResult {
        case needMoreData
        case parsed(username: String, password: String, consumed: Int)
        case invalid
    }

    /// `data` is `VER(1)=0x01 | ULEN(1) | UNAME(ULEN) | PLEN(1) | PASSWD(PLEN)`
    /// — the exact layout `Socks5ClientWire.buildAuthRequest` (client package)
    /// produces.
    static func parseAuthRequest(_ data: Data) -> AuthRequestResult {
        let base = data.startIndex
        guard data.count >= 2 else { return .needMoreData }
        guard data[base] == 0x01 else { return .invalid }
        let uLen = Int(data[base + 1])
        var offset = base + 2
        guard data.count >= (offset - base) + uLen else { return .needMoreData }
        guard let username = String(data: data[offset..<offset + uLen], encoding: .utf8) else { return .invalid }
        offset += uLen
        guard data.count > offset - base else { return .needMoreData }
        let pLen = Int(data[offset])
        offset += 1
        guard data.count >= (offset - base) + pLen else { return .needMoreData }
        guard let password = String(data: data[offset..<offset + pLen], encoding: .utf8) else { return .invalid }
        offset += pLen
        return .parsed(username: username, password: password, consumed: offset - base)
    }

    /// `VER(1)=0x01 | STATUS(1)` — `0x00` success, non-zero failure. Matches
    /// what `Socks5ClientWire.parseAuthReply` (client package) expects.
    static func authReply(success: Bool) -> Data {
        Data([0x01, success ? 0x00 : 0x01])
    }

    // MARK: - Request

    enum Command {
        case connect
        case bind
        case udpAssociate
    }

    enum RequestResult {
        case needMoreData
        case invalid
        case parsed(command: Command, host: String, port: UInt16, consumed: Int)
    }

    /// `data` is `VER(1)=0x05 | CMD(1) | RSV(1)=0x00 | ATYP(1) | DST.ADDR | DST.PORT(2, big-endian)`.
    /// `ATYP` 0x01 (IPv4, 4 bytes), 0x03 (domain, `LEN(1) | LEN bytes`), 0x04 (IPv6, 16 bytes).
    static func parseRequest(_ data: Data) -> RequestResult {
        let base = data.startIndex
        guard data.count >= 4 else { return .needMoreData }
        guard data[base] == 0x05 else { return .invalid }
        let cmdByte = data[base + 1]
        // data[base + 2] is RSV, ignored.
        let atyp = data[base + 3]
        var offset = base + 4
        let host: String

        switch atyp {
        case 0x01: // IPv4
            guard data.count >= (offset - base) + 4 + 2 else { return .needMoreData }
            host = data[offset..<offset + 4].map { String($0) }.joined(separator: ".")
            offset += 4
        case 0x03: // domain name
            guard data.count > offset - base else { return .needMoreData }
            let len = Int(data[offset])
            offset += 1
            guard data.count >= (offset - base) + len + 2 else { return .needMoreData }
            guard let name = String(data: data[offset..<offset + len], encoding: .utf8) else { return .invalid }
            host = name
            offset += len
        case 0x04: // IPv6
            guard data.count >= (offset - base) + 16 + 2 else { return .needMoreData }
            host = ipv6String(Array(data[offset..<offset + 16]))
            offset += 16
        default:
            return .invalid
        }

        guard data.count >= (offset - base) + 2 else { return .needMoreData }
        let port = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2

        let command: Command
        switch cmdByte {
        case 0x01: command = .connect
        case 0x02: command = .bind
        case 0x03: command = .udpAssociate
        default: return .invalid
        }
        return .parsed(command: command, host: host, port: port, consumed: offset - base)
    }

    /// Uncompressed (no `::` shortening) but valid IPv6 literal — sufficient
    /// for `NWEndpoint.Host`/DNS resolution, which don't require canonical form.
    private static func ipv6String(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2)
            .map { String((UInt16(bytes[$0]) << 8) | UInt16(bytes[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }

    // MARK: - Reply

    enum ReplyCode: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case networkUnreachable = 0x03
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    /// `VER(1)=0x05 | REP(1) | RSV(1)=0x00 | ATYP(1)=0x01 | BND.ADDR(4)=0.0.0.0 | BND.PORT(2)=0`.
    /// This proxy never reports a real local bind address — real-world SOCKS5
    /// clients check REP for CONNECT, not BND.ADDR/BND.PORT.
    static func reply(_ code: ReplyCode) -> Data {
        Data([0x05, code.rawValue, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    /// Success reply for UDP ASSOCIATE — unlike `reply(_:)`'s fixed dummy
    /// address (fine for CONNECT, which clients ignore), this one is
    /// load-bearing: the client must send its UDP datagrams to exactly this
    /// host:port. `host` is always IPv4-dotted (from `LocalAddress`); falls
    /// back to `0.0.0.0` only if that's somehow unavailable.
    static func associateReply(host: String, port: UInt16) -> Data {
        var out: Data
        var v6 = in6_addr()
        if host.contains(":"), inet_pton(AF_INET6, host, &v6) == 1 {
            // Client reached us over IPv6: advertise that IPv6 address (ATYP 4).
            out = Data([0x05, 0x00, 0x00, 0x04])
            out.append(contentsOf: withUnsafeBytes(of: &v6) { Array($0) })
        } else {
            out = Data([0x05, 0x00, 0x00, 0x01])
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            out.append(contentsOf: octets.count == 4 ? octets : [0, 0, 0, 0])
        }
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }

    // MARK: - UDP ASSOCIATE datagram framing

    enum UDPDatagramResult {
        case invalid
        case parsed(host: String, port: UInt16, payload: Data)
    }

    /// `RSV(2)=0x0000 | FRAG(1) | ATYP(1) | DST.ADDR | DST.PORT(2) | DATA`. A
    /// UDP datagram always arrives whole in one `receiveMessage()` call (no
    /// partial-read concept), so unlike `parseRequest` this has no
    /// `.needMoreData` case — a short/malformed datagram is just invalid and
    /// dropped. Fragmentation (`FRAG != 0`) is not supported.
    static func parseUDPDatagram(_ data: Data) -> UDPDatagramResult {
        let base = data.startIndex
        guard data.count >= 4 else { return .invalid }
        let frag = data[base + 2]
        guard frag == 0 else { return .invalid }
        let atyp = data[base + 3]
        var offset = base + 4
        let host: String

        switch atyp {
        case 0x01:
            guard data.count >= (offset - base) + 4 + 2 else { return .invalid }
            host = data[offset..<offset + 4].map { String($0) }.joined(separator: ".")
            offset += 4
        case 0x03:
            guard data.count > offset - base else { return .invalid }
            let len = Int(data[offset])
            offset += 1
            guard data.count >= (offset - base) + len + 2 else { return .invalid }
            guard let name = String(data: data[offset..<offset + len], encoding: .utf8) else { return .invalid }
            host = name
            offset += len
        case 0x04:
            guard data.count >= (offset - base) + 16 + 2 else { return .invalid }
            host = ipv6String(Array(data[offset..<offset + 16]))
            offset += 16
        default:
            return .invalid
        }

        guard data.count >= (offset - base) + 2 else { return .invalid }
        let port = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        return .parsed(host: host, port: port, payload: Data(data[offset...]))
    }

    /// `RSV(2)=0x0000 | FRAG(1)=0x00 | ATYP | SRC.ADDR | SRC.PORT(2) | payload`.
    /// RFC 1928 §7: in a relay-to-client datagram the address fields carry the
    /// remote host the payload came from, so a client that shares one
    /// association across several destinations can tell replies apart. `host`
    /// is echoed exactly as the client named it (IPv4/IPv6 literal, or a
    /// domain name sent as ATYP 3).
    static func buildUDPDatagram(host: String, port: UInt16, payload: Data) -> Data {
        var out = Data([0, 0, 0])
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            out.append(0x01)
            out.append(contentsOf: withUnsafeBytes(of: &v4) { Array($0) })
        } else if inet_pton(AF_INET6, host, &v6) == 1 {
            out.append(0x04)
            out.append(contentsOf: withUnsafeBytes(of: &v6) { Array($0) })
        } else {
            let name = Array(host.utf8.prefix(255))
            out.append(0x03)
            out.append(UInt8(name.count))
            out.append(contentsOf: name)
        }
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        out.append(payload)
        return out
    }
}
