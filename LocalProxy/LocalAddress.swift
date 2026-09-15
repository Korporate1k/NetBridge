import Foundation

struct InterfaceAddress: Identifiable, Equatable {
    let name: String
    let ip: String
    var id: String { "\(name)-\(ip)" }
}

enum LocalAddress {
    /// Returns the device's active local IPv4 address — whatever interface is
    /// actually up (Wi-Fi, Personal Hotspot, USB/Ethernet, ...), skipping
    /// loopback and link-local addresses. Display-only: the listener binds
    /// `0.0.0.0`, so the proxy works even if this probe comes back empty.
    static func primaryIPv4() -> String? {
        allIPv4().first?.ip
    }

    /// Every active local IPv4 address, one per interface, tagged with the
    /// OS's own interface name (`en0`, `pdp_ip0`, `bridge100`, ...). No
    /// interface is filtered or labeled by name — only by the same up/
    /// loopback/link-local criteria `primaryIPv4()` always used — so this is
    /// a plain enumeration, not targeting for any particular network.
    static func allIPv4() -> [InterfaceAddress] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var results: [InterfaceAddress] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = host.withUnsafeMutableBufferPointer { buf -> Int32 in
                getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                            buf.baseAddress, socklen_t(buf.count),
                            nil, 0, NI_NUMERICHOST)
            }
            guard result == 0 else { continue }

            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue } // link-local, not useful to show
            let name = String(cString: ifa.ifa_name)
            if !results.contains(where: { $0.name == name && $0.ip == ip }) {
                results.append(InterfaceAddress(name: name, ip: ip))
            }
        }
        return results
    }
}
