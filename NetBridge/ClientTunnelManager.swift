import Foundation
@preconcurrency import NetworkExtension

/// Wraps `NETunnelProviderManager` to configure and control the
/// `NetBridgeTunnel` Network Extension — the app-side half of the SOCKS5
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
    #if os(macOS)
    // macOS shares Keychain items between the app and its extension only through
    // the data-protection keychain, and there the group must be team-prefixed.
    static let keychainAccessGroup = "DS8AMC8BSV.com.Korporate1k.LocalProxy.shared"
    #else
    static let keychainAccessGroup = "com.Korporate1k.LocalProxy.shared"
    #endif
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
                // Only our own connection. NE posts this for every VPN configuration alive in this process, and
                // `loadOrCreate` briefly holds all of them (including the duplicates it removes), so without this
                // check a foreign VPN's status would overwrite ours — and on macOS it could drive the app's
                // reconnect logic into starting our tunnel.
                guard connection === self.manager?.connection else { return }
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
                let matching = managers?.filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
                } ?? []
                #if os(macOS)
                // Saving before the first load finished used to create a second
                // configuration ("NetBridge Client 2"...). Keep one, drop the rest.
                for extra in matching.dropFirst() {
                    extra.removeFromPreferences { _ in }
                }
                #endif
                let manager = matching.first ?? NETunnelProviderManager()
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
        manager.localizedDescription = "NetBridge Client"
        manager.isEnabled = true

        manager.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                } else {
                    #if os(macOS)
                    // A freshly saved configuration must be reloaded before
                    // `startVPNTunnel()` accepts it — without this, macOS
                    // reports NEVPNErrorDomain error 1 (configurationInvalid)
                    // and `status` stays `.invalid`.
                    manager.loadFromPreferences { [weak self] loadError in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if let loadError {
                                self.lastError = loadError.localizedDescription
                                completion(.failure(loadError))
                            } else {
                                self.status = manager.connection.status
                                self.lastError = nil
                                completion(.success(()))
                            }
                        }
                    }
                    #else
                    self.lastError = nil
                    completion(.success(()))
                    #endif
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

    #if os(macOS)
    /// When the current tunnel session came up, straight from NetworkExtension.
    var connectedDate: Date? { manager?.connection.connectedDate }

    /// The error that ended the last session, or `nil` if it ended cleanly (user / `scutil --nc stop`). A tunnel
    /// extension that dies on its own ("The VPN session failed because an internal error occurred") reports one.
    func fetchLastDisconnectError(_ completion: @escaping @Sendable (Error?) -> Void) {
        guard let manager else {
            completion(nil)
            return
        }
        manager.connection.fetchLastDisconnectError(completionHandler: completion)
    }

    /// Asks the running packet-tunnel extension for its live counters
    /// (`PacketTunnelProvider.handleAppMessage`). `nil` if it isn't running.
    func requestStats(_ completion: @escaping (Data?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(nil)
            return
        }
        do {
            try session.sendProviderMessage(Data("stats".utf8), responseHandler: completion)
        } catch {
            completion(nil)
        }
    }
    #endif
}
