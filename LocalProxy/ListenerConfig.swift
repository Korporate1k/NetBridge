import Foundation

/// How a listener decides which protocol a connecting client is speaking.
/// `.auto` is the original behavior (sniff the first byte); `.httpOnly`/
/// `.socks5Only` skip the sniff for a listener dedicated to one protocol.
enum ListenerMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case httpOnly
    case socks5Only

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .httpOnly: return "HTTP only"
        case .socks5Only: return "SOCKS5 only"
        }
    }
}

/// One additional listener beyond the primary port (`ProxyServer.port`,
/// always `.auto` — unchanged from the original single-listener design).
struct ListenerConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var port: Int
    var mode: ListenerMode
}
