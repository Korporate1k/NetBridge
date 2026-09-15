import Foundation

/// Minimal RFC 8484 DNS-over-HTTPS client: resolves a hostname to an IPv4
/// address by POSTing a hand-built DNS wire-format A-record query to a
/// configurable upstream. Reads its settings directly from `UserDefaults`
/// (the same store `@AppStorage("doh.enabled")`/`@AppStorage("doh.upstreamURL")`
/// use in `DashboardView`'s Settings), so no config needs threading through
/// `ProxyServer`/`Tunnel`.
final class DoHResolver {
    static let shared = DoHResolver()

    private struct CacheEntry { let ip: String; let expiresAt: Date }
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        session = URLSession(configuration: config)
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "doh.enabled")
    }

    private var upstreamURL: URL? {
        let stored = UserDefaults.standard.string(forKey: "doh.upstreamURL")
        let text = (stored?.isEmpty == false) ? stored! : "https://cloudflare-dns.com/dns-query"
        return URL(string: text)
    }

    /// Resolves `host` to a dotted-quad IPv4 string, or `nil` if `host` is
    /// already a literal address, resolution fails, or DoH is disabled —
    /// callers should fall back to dialing `host` directly (system DNS) in
    /// every `nil` case.
    func resolve(_ host: String, completion: @escaping (String?) -> Void) {
        guard isEnabled, !isIPv4Literal(host), let upstream = upstreamURL else {
            completion(nil)
            return
        }
        lock.lock()
        if let cached = cache[host], cached.expiresAt > Date() {
            lock.unlock()
            completion(cached.ip)
            return
        }
        lock.unlock()

        guard let query = Self.buildQuery(name: host) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: upstream)
        request.httpMethod = "POST"
        request.httpBody = query
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil,
                  let (ip, ttl) = Self.parseFirstA(data) else {
                DebugLog.debug("doh", "resolve \(host) failed \(ErrorDescription.describe(error))")
                completion(nil)
                return
            }
            self.lock.lock()
            self.cache[host] = CacheEntry(ip: ip, expiresAt: Date().addingTimeInterval(TimeInterval(max(ttl, 30))))
            self.lock.unlock()
            DebugLog.debug("doh", "resolved \(host) -> \(ip) ttl=\(ttl)")
            completion(ip)
        }.resume()
    }

    private func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - DNS wire format (A record query only)

    private static func buildQuery(name: String) -> Data? {
        var data = Data([0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in name.split(separator: ".") {
            guard label.utf8.count <= 63 else { return nil }
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(0x00)
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // QTYPE=A, QCLASS=IN
        return data
    }

    /// Parses just enough of the response to pull the first A record's
    /// address and TTL — skips the question section by name-pointer-aware
    /// walking, then scans answers for `TYPE == 1 (A)`.
    private static func parseFirstA(_ data: Data) -> (ip: String, ttl: UInt32)? {
        guard data.count > 12 else { return nil }
        let qdcount = Int(data[4]) << 8 | Int(data[5])
        let ancount = Int(data[6]) << 8 | Int(data[7])
        guard ancount > 0 else { return nil }

        var offset = 12
        for _ in 0..<qdcount {
            guard let next = skipName(data, offset) else { return nil }
            offset = next + 4 // QTYPE + QCLASS
        }

        for _ in 0..<ancount {
            guard let nameEnd = skipName(data, offset) else { return nil }
            offset = nameEnd
            guard offset + 10 <= data.count else { return nil }
            let type = Int(data[offset]) << 8 | Int(data[offset + 1])
            let ttl = UInt32(data[offset + 4]) << 24 | UInt32(data[offset + 5]) << 16
                | UInt32(data[offset + 6]) << 8 | UInt32(data[offset + 7])
            let rdlength = Int(data[offset + 8]) << 8 | Int(data[offset + 9])
            let rdataStart = offset + 10
            guard rdataStart + rdlength <= data.count else { return nil }
            if type == 1, rdlength == 4 {
                let octets = data[rdataStart..<rdataStart + 4]
                let ip = octets.map { String($0) }.joined(separator: ".")
                return (ip, ttl)
            }
            offset = rdataStart + rdlength
        }
        return nil
    }

    /// Advances past a DNS name starting at `offset` (handles compression
    /// pointers) and returns the offset immediately after it.
    private static func skipName(_ data: Data, _ offset: Int) -> Int? {
        var pos = offset
        while pos < data.count {
            let length = Int(data[pos])
            if length == 0 {
                return pos + 1
            } else if length & 0xC0 == 0xC0 {
                return pos + 2 // compression pointer: fixed 2-byte field, don't follow it
            } else {
                pos += 1 + length
            }
        }
        return nil
    }
}
