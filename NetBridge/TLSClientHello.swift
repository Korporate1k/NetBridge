import Foundation

/// Extracts the SNI hostname from a raw TLS ClientHello, for connections that
/// only supply the destination as an IP literal (so the "real" host isn't
/// known any other way). Pure data transformation, no networking — reads only
/// the bytes it's handed (normally the client's first upstream chunk after a
/// CONNECT/SOCKS5 handshake); never blocks or throws, and returns `nil` for
/// anything truncated, malformed, or simply not a TLS ClientHello. Kept
/// I/O-free like `Socks5Handler.swift` so it can be hand-traced against
/// RFC 8446 §4.1.2's byte layout without a device or test target.
enum TLSClientHello {
    static func extractSNI(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let extBody = serverNameExtensionBody(in: bytes) else { return nil }
        guard let nameRange = hostNameRange(inExtensionBody: bytes, bodyRange: extBody) else { return nil }
        return String(bytes: bytes[nameRange], encoding: .utf8)
    }

    /// Byte range (0-based, within `data`) of the raw SNI hostname bytes in a
    /// ClientHello, or `nil` if none is present / the buffer isn't a
    /// well-formed ClientHello. Used by `AntiDPI`'s fragmenter to split
    /// specifically around the hostname without decoding it.
    static func sniRange(in data: Data) -> Range<Int>? {
        let bytes = [UInt8](data)
        guard let extBody = serverNameExtensionBody(in: bytes) else { return nil }
        return hostNameRange(inExtensionBody: bytes, bodyRange: extBody)
    }

    /// Byte range of the `server_name` extension's body within `bytes`
    /// (record header through the extensions list), or `nil`.
    private static func serverNameExtensionBody(in bytes: [UInt8]) -> Range<Int>? {
        var r = Reader(bytes: bytes)

        // TLS record header: ContentType(1)=0x16 handshake | ProtocolVersion(2) | length(2)
        guard r.byte() == 0x16 else { return nil }
        guard r.skip(2) else { return nil }
        guard let recordLength = r.uint16() else { return nil }
        guard r.remaining >= Int(recordLength) else { return nil } // truncated — don't guess

        // Handshake header: HandshakeType(1)=0x01 ClientHello | length(3)
        guard r.byte() == 0x01 else { return nil }
        guard let helloLength = r.uint24() else { return nil }
        guard r.remaining >= helloLength else { return nil }

        // client_version(2) | random(32)
        guard r.skip(2 + 32) else { return nil }

        // session_id: length(1) | id
        guard let sessionIDLen = r.byte() else { return nil }
        guard r.skip(Int(sessionIDLen)) else { return nil }

        // cipher_suites: length(2) | suites
        guard let cipherSuitesLen = r.uint16() else { return nil }
        guard r.skip(Int(cipherSuitesLen)) else { return nil }

        // compression_methods: length(1) | methods
        guard let compressionLen = r.byte() else { return nil }
        guard r.skip(Int(compressionLen)) else { return nil }

        // extensions are optional — a ClientHello with nothing left has no SNI.
        guard r.remaining > 0 else { return nil }
        guard let extensionsLength = r.uint16() else { return nil }
        guard r.remaining >= Int(extensionsLength) else { return nil }
        let extensionsEnd = r.offset + Int(extensionsLength)

        while r.offset < extensionsEnd {
            guard let type = r.uint16() else { return nil }
            guard let length = r.uint16() else { return nil }
            guard r.remaining >= Int(length) else { return nil }
            if type == 0x0000 {
                return r.offset..<(r.offset + Int(length))
            }
            guard r.skip(Int(length)) else { return nil }
        }
        return nil
    }

    /// `server_name` extension body: server_name_list_length(2) | entries of
    /// { name_type(1)=0x00 host_name | name_length(2) | name }. Returns the
    /// host_name bytes' absolute range within the original buffer.
    private static func hostNameRange(inExtensionBody bytes: [UInt8], bodyRange: Range<Int>) -> Range<Int>? {
        var r = Reader(bytes: Array(bytes[bodyRange]))
        guard let listLength = r.uint16() else { return nil }
        guard r.remaining >= Int(listLength) else { return nil }
        while r.remaining >= 3 {
            guard let nameType = r.byte() else { return nil }
            guard let nameLength = r.uint16() else { return nil }
            guard r.remaining >= Int(nameLength) else { return nil }
            let start = bodyRange.lowerBound + r.offset
            guard r.skip(Int(nameLength)) else { return nil }
            if nameType == 0x00 {
                return start..<(start + Int(nameLength))
            }
        }
        return nil
    }

    /// Minimal bounds-checked cursor over a byte array — every read returns
    /// `nil`/`false` instead of trapping when it would run past the end.
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var remaining: Int { bytes.count - offset }

        mutating func byte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, remaining >= count else { return false }
            offset += count
            return true
        }

        mutating func uint16() -> UInt16? {
            guard remaining >= 2 else { return nil }
            let value = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            offset += 2
            return value
        }

        mutating func uint24() -> Int? {
            guard remaining >= 3 else { return nil }
            let value = (Int(bytes[offset]) << 16) | (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
            offset += 3
            return value
        }
    }
}
