import Foundation

/// The remote SOCKS5 server a device connects out to as a *client* (see
/// `ClientTunnelManager`/`ClientTabView`) — the mirror image of
/// `ProxyProfile`, which configures this device's own local listener.
///
/// Round-trips through a `socks5://user:pass@host:port` URI (userinfo
/// omitted when both `username`/`password` are empty) so it can be shown as
/// a QR code (`QRCodeView.swift`) and read back via the camera scanner
/// (`QRScannerView.swift`) for pairing a second device without typing.
struct ClientConfiguration: Codable, Equatable {
    var host: String
    var port: UInt16
    var username: String
    var password: String

    init(host: String, port: UInt16, username: String = "", password: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// Accepts a full `socks5://[user[:pass]@]host:port` URI, or a bare
    /// `host:port` — the form `QRCodeSheet` encodes for a device's own server.
    init?(uriString: String) {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "socks5://" + trimmed
        guard let components = URLComponents(string: normalized),
              components.scheme?.lowercased() == "socks5",
              let host = components.host,
              let port = components.port,
              (0...Int(UInt16.max)).contains(port)
        else { return nil }
        self.host = host
        self.port = UInt16(port)
        self.username = components.user ?? ""
        self.password = components.password ?? ""
    }

    var uriString: String {
        var components = URLComponents()
        components.scheme = "socks5"
        components.host = host
        components.port = Int(port)
        if !username.isEmpty {
            components.user = username
            // `URLComponents` only emits a password when a user is also
            // present — matches the URI grammar (`user:pass@`), so an empty
            // username can't accidentally carry a password along with it.
            if !password.isEmpty {
                components.password = password
            }
        }
        return components.string ?? "socks5://\(host):\(port)"
    }
}
