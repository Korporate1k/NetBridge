import Foundation
import Network

struct InterfaceAddress: Identifiable, Equatable {
    let name: String
    let ip: String
    var id: String { "\(name)-\(ip)" }

    /// Plain-English label for the OS's raw interface name, for display in the UI.
    /// Falls back to the raw name for anything unrecognized (e.g. `utun3`, `llw0`).
    var displayName: String {
        if name == "en0" { return "Wi-Fi" }
        if name.hasPrefix("en") { return "Ethernet" } // en1+ on iPhone: USB Ethernet adapters
        if name.hasPrefix("pdp_ip") { return "Cellular" }
        if name.hasPrefix("bridge") { return "Personal Hotspot" }
        if name.hasPrefix("awdl") { return "AirDrop" }
        return name
    }
}

enum LocalAddress {
    /// The local address an ACCEPTED connection is actually using — i.e. the address the client connected to — as a printable
    /// IP literal (IPv4 dotted, or IPv6; an IPv4-mapped `::ffff:a.b.c.d` is returned as plain IPv4). This is what a SOCKS5
    /// UDP ASSOCIATE reply must advertise as the relay address: it is by construction reachable from that client, whereas
    /// `primaryIPv4()` is just the first active interface in the OS's list. On a phone that is also running a hotspot the
    /// first one was `192.0.0.3` (a cellular translation interface), so hotspot clients were told to send their UDP to an
    /// address they could never reach. `nil` if the connection has no usable local endpoint yet.
    static func localAddress(of connection: NWConnection) -> String? {
        guard case let .hostPort(host, _)? = connection.currentPath?.localEndpoint else { return nil }
        switch host {
        case .ipv4(let address):
            let b = [UInt8](address.rawValue)
            return b.count == 4 ? "\(b[0]).\(b[1]).\(b[2]).\(b[3])" : nil
        case .ipv6(let address):
            let b = [UInt8](address.rawValue)
            guard b.count == 16 else { return nil }
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return "\(b[12]).\(b[13]).\(b[14]).\(b[15])" }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: b) }
            return inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)) != nil ? String(cString: text) : nil
        default:
            return nil
        }
    }

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
