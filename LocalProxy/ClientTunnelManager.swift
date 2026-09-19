import Foundation
import NetworkExtension

/// Wraps `NETunnelProviderManager` to configure and control the
/// `LocalProxyTunnel` Network Extension — the app-side half of the SOCKS5
/// *client* feature (`ClientTabView`), mirroring how SocksTunnel's
/// `VPNKit/TunnelManager` drives the same API.
///
/// The non-secret fields (`host`/`port`/`username`) go into the saved
/// `NETunnelProviderProtocol.providerConfiguration`, which iOS persists to
/// disk in a place any process can eventually enumerate; the password goes
/// into the shared Keychain access group instead (`KeychainStore`), the same
/// split SocksTunnel's own `TunnelManager`/`KeychainStore` use.
///
/// This environment has no code-signing identity or Team ID configured at
/// all (see `HANDOFF-QA-PASS.md`/`HANDOFF.md`), so `save`/`start` below are
/// expected to fail here with a real `NSError` from `NetworkExtension` — the
/// UI surfaces `lastError` rather than crashing or hanging, since that
/// failure is the correct, expected outcome until real signing exists.
@MainActor
final class ClientTunnelManager: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var lastError: String?

    /// Runtime access-group value — see the comment on `KeychainStore`'s
    /// `accessGroup` parameter for why this is a literal rather than
    /// derived from `$(AppIdentifierPrefix)`.
    private static let keychainAccessGroup = "com.Korporate1k.LocalProxy.shared"
    private static let passwordKey = "client_password"
    private static let providerBundleIdentifier = "com.Korporate1k.LocalProxy.Tunnel"

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let connection = notification.object as? NEVPNConnection else { return }
            let status = connection.status
            // Delivered on `queue: .main`, so this is already the main actor —
            // the observer closure is just typed as a plain Sendable closure.
            MainActor.assumeIsolated {
                DebugLog.important("client", "VPN status -> \(status.rawValue) (\(String(describing: status)))")
                self.status = status
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    /// Loads a previously saved configuration, if any, so `status` reflects
    /// reality on launch instead of defaulting to `.invalid` even when a
    /// tunnel is already configured/connected from a prior session.
    func loadOrCreate(completion: @escaping (Result<Void, Error>) -> Void) {
        // `loadAllFromPreferences`'s completion isn't documented to land on
        // any particular queue — hop back to main explicitly before touching
        // `@Published` state, rather than relying on it happening to be main.
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                    return
                }
                let manager = managers?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
                }) ?? NETunnelProviderManager()
                self.manager = manager
                self.status = manager.connection.status
                completion(.success(()))
            }
        }
    }

    /// Saves `config` as this device's SOCKS5 client server, creating the
    /// tunnel configuration if one doesn't exist yet.
    func save(_ config: ClientConfiguration, completion: @escaping (Result<Void, Error>) -> Void) {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleIdentifier
        proto.serverAddress = config.host
        proto.providerConfiguration = [
            "host": config.host,
            "port": config.port,
            "username": config.username
        ]
        KeychainStore.save(Data(config.password.utf8), key: Self.passwordKey, accessGroup: Self.keychainAccessGroup)

        let manager = self.manager ?? NETunnelProviderManager()
        self.manager = manager

        manager.protocolConfiguration = proto
        manager.localizedDescription = "LocalProxy Client"
        manager.isEnabled = true

        manager.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                } else {
                    self.lastError = nil
                    completion(.success(()))
                }
            }
        }
    }

    func start() {
        guard let manager else {
            lastError = "No saved configuration to start — save one first."
            return
        }
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }
}
