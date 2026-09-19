import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// RFC 1928 SOCKS5 wire-format — client role only: builds the greeting and
/// request, parses the server's method-selection and reply. This is the
/// inverse of LocalProxy's own server-side `Socks5Handler` (which parses
/// requests and builds replies) — kept as a separate, self-contained
/// implementation rather than shared code, since `Socks5Handler` lives in
/// the app target and isn't importable from a package, and the two roles
/// don't actually share much beyond byte-layout constants.
enum Socks5ClientWire {
    // MARK: - Greeting / method selection

    /// `VER(1)=0x05 | NMETHODS(1)=2 | METHODS(2)=[0x00, 0x02]` — offer no-auth or username/password.
    /// If `credentials` are present, offer both methods; otherwise offer no-auth only.
    static func buildGreeting(withAuth: Bool = false) -> Data {
        if withAuth {
            // Offer both no-auth (0x00) and username/password (0x02)
            return Data([0x05, 0x02, 0x00, 0x02])
        } else {
            // Offer no-auth only
            return Data([0x05, 0x01, 0x00])
        }
    }

    enum MethodSelectionResult {
        case needMoreData
        case ok(method: UInt8)  // 0x00 = no-auth, 0x02 = username/password
        case rejected(method: UInt8)
        case invalidVersion(UInt8)
    }

    /// `data` is `VER(1) | METHOD(1)`.
    static func parseMethodSelection(_ data: Data) -> MethodSelectionResult {
        guard data.count >= 2 else { return .needMoreData }
        let base = data.startIndex
        guard data[base] == 0x05 else { return .invalidVersion(data[base]) }
        let method = data[base + 1]
        // Accept both 0x00 (no-auth) and 0x02 (username/password)
        return (method == 0x00 || method == 0x02) ? .ok(method: method) : .rejected(method: method)
    }

    // MARK: - Request

    enum Command: UInt8 {
        case connect = 0x01
        case udpAssociate = 0x03
    }

    /// `VER(1)=0x05 | CMD(1) | RSV(1)=0x00 | ATYP | DST.ADDR | DST.PORT(2, big-endian)`.
    /// `host`'s address type is chosen automatically: IPv4 dotted-quad, then
    /// IPv6 literal, else treated as a domain name (ATYP 0x03).
    static func buildRequest(command: Command, host: String, port: UInt16) -> Data {
        var out = Data([0x05, command.rawValue, 0x00])
        out.append(encodeAddress(host))
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }

    // MARK: - Reply

    enum ReplyResult {
        case needMoreData
        case invalid
        case invalidVersion(UInt8)
        case parsed(code: UInt8, bindHost: String, bindPort: UInt16, consumed: Int)
    }

    /// `data` is `VER(1)=0x05 | REP(1) | RSV(1)=0x00 | ATYP(1) | BND.ADDR | BND.PORT(2)`.
    static func parseReply(_ data: Data) -> ReplyResult {
        let base = data.startIndex
        guard data.count >= 4 else { return .needMoreData }
        guard data[base] == 0x05 else { return .invalidVersion(data[base]) }
        let rep = data[base + 1]
        // data[base + 2] is RSV, ignored.
        let atyp = data[base + 3]
        var offset = base + 4
        let host: String

        switch atyp {
        case 0x01:
            guard data.count >= (offset - base) + 4 + 2 else { return .needMoreData }
            host = data[offset..<offset + 4].map { String($0) }.joined(separator: ".")
            offset += 4
        case 0x03:
            guard data.count > offset - base else { return .needMoreData }
            let len = Int(data[offset])
            offset += 1
            guard data.count >= (offset - base) + len + 2 else { return .needMoreData }
            guard let name = String(data: data[offset..<offset + len], encoding: .utf8) else { return .invalid }
            host = name
            offset += len
        case 0x04:
            guard data.count >= (offset - base) + 16 + 2 else { return .needMoreData }
            host = ipv6String(Array(data[offset..<offset + 16]))
            offset += 16
        default:
            return .invalid
        }

        guard data.count >= (offset - base) + 2 else { return .needMoreData }
        let port = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        return .parsed(code: rep, bindHost: host, bindPort: port, consumed: offset - base)
    }

    // MARK: - UDP ASSOCIATE datagram framing

    enum UDPDatagramResult {
        case invalid
        case parsed(host: String, port: UInt16, payload: Data)
    }

    /// `RSV(2)=0x0000 | FRAG(1)=0x00 | ATYP | DST.ADDR | DST.PORT(2) | DATA`.
    /// Unlike the server's fixed-dummy-address reply shortcut, the client's
    /// destination address here is load-bearing — it's what tells the
    /// server's relay where to actually send the payload.
    static func buildUDPDatagram(host: String, port: UInt16, payload: Data) -> Data {
        var out = Data([0, 0, 0])
        out.append(encodeAddress(host))
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        out.append(payload)
        return out
    }

    /// Fragmentation (`FRAG != 0`) is not supported and treated as invalid.
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

    // MARK: - RFC 1929 Username/Password Authentication

    enum AuthReplyResult {
        case needMoreData
        case success
        case failure(status: UInt8)
        case invalidVersion(UInt8)
    }

    /// Build RFC 1929 auth request: `VER(1)=0x01 | ULEN(1) | UNAME(ULEN) | PLEN(1) | PASSWD(PLEN)`.
    /// Both username and password must be ≤ 255 bytes in UTF-8; raises an error if either exceeds that.
    static func buildAuthRequest(username: String, password: String) -> Result<Data, Socks5ClientError> {
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)

        guard usernameBytes.count <= 255 else {
            return .failure(.credentialTooLong("username exceeds 255 bytes"))
        }
        guard passwordBytes.count <= 255 else {
            return .failure(.credentialTooLong("password exceeds 255 bytes"))
        }

        var out = Data([0x01])  // Version = 1 (RFC 1929)
        out.append(UInt8(usernameBytes.count))
        out.append(contentsOf: usernameBytes)
        out.append(UInt8(passwordBytes.count))
        out.append(contentsOf: passwordBytes)

        return .success(out)
    }

    /// Parse RFC 1929 auth reply: `VER(1)=0x01 | STATUS(1)` where STATUS=0x00 is success.
    static func parseAuthReply(_ data: Data) -> AuthReplyResult {
        guard data.count >= 2 else { return .needMoreData }
        let base = data.startIndex
        guard data[base] == 0x01 else { return .invalidVersion(data[base]) }
        let status = data[base + 1]
        return status == 0x00 ? .success : .failure(status: status)
    }

    // MARK: - Address encoding/decoding helpers

    private static func encodeAddress(_ host: String) -> Data {
        if let v4 = ipv4Bytes(host) {
            return Data([0x01] + v4)
        } else if let v6 = ipv6Bytes(host) {
            return Data([0x04] + v6)
        } else {
            let nameBytes = Array(host.utf8.prefix(255))
            return Data([0x03, UInt8(nameBytes.count)] + nameBytes)
        }
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        let result = host.withCString { cstr in
            inet_pton(AF_INET6, cstr, &addr)
        }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// Uncompressed (no `::` shortening) but valid IPv6 literal — sufficient
    /// for `NWEndpoint.Host`/DNS resolution, which don't require canonical form.
    private static func ipv6String(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2)
            .map { String((UInt16(bytes[$0]) << 8) | UInt16(bytes[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }
}
