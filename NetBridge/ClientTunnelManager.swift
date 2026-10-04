import Foundation
@preconcurrency import NetworkExtension
import Security

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
    /// Set by `stop()`, cleared by `start()`: a disconnect the user asked for carries no failure worth showing.
    private var userRequestedStop = false
    #if os(iOS) || os(tvOS)
    private static let lastShownFailureKey = "client.lastShownFailureID"
    #endif

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
                let previous = self.status
                self.status = status
                #if os(iOS) || os(tvOS)
                if status == .disconnected, previous != .disconnected, previous != .invalid, !self.userRequestedStop {
                    self.showProviderFailure()
                }
                #endif
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

    /// The stored SOCKS5 password: the value, `""` when none is stored, or `nil` when the Keychain read FAILED
    /// (so the caller knows it does not know, and must not write an empty field back over it).
    static func loadStoredPassword() -> String? {
        switch KeychainStore.loadResult(key: passwordKey, accessGroup: keychainAccessGroup) {
        case .found(let data): return String(data: data, encoding: .utf8) ?? ""
        case .notFound: return ""
        case .failed: return nil
        }
    }

    /// The configuration last saved to NetworkExtension (host/port/username) plus the Keychain password, for
    /// filling a form. `nil` when nothing has been saved yet or `loadOrCreate` has not finished. The `password`
    /// half is `nil` when the Keychain read failed; pass it back to `save(_:loadedPassword:)` unchanged.
    func savedConfiguration() -> (config: ClientConfiguration, password: String?)? {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let stored = proto.providerConfiguration,
              let host = stored["host"] as? String, !host.isEmpty
        else { return nil }
        let port = (stored["port"] as? NSNumber)?.uint16Value ?? 1080
        let password = Self.loadStoredPassword()
        let config = ClientConfiguration(host: host, port: port, username: stored["username"] as? String ?? "",
                                         password: password ?? "")
        return (config, password)
    }

    /// Saves `config` as this device's SOCKS5 client server, creating the
    /// tunnel configuration if one doesn't exist yet.
    ///
    /// `loadedPassword` is the password the caller's form was filled with from the Keychain (`nil` = the form never
    /// loaded one, e.g. the read failed or the form was filled from elsewhere). The Keychain is written only when
    /// the password actually changed, and never with an empty password the form did not load: an empty field is
    /// then "unknown", not "cleared", and writing it would silently wipe the stored password.
    func save(_ config: ClientConfiguration, loadedPassword: String?,
              completion: @escaping (Result<Void, Error>) -> Void) {
        let keychainError = persistPassword(config.password, loadedPassword: loadedPassword)
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleIdentifier
        proto.serverAddress = config.host
        proto.providerConfiguration = [
            "host": config.host,
            "port": config.port,
            "username": config.username
        ]

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
                                self.lastError = keychainError
                                completion(.success(()))
                            }
                        }
                    }
                    #else
                    self.lastError = keychainError
                    completion(.success(()))
                    #endif
                }
            }
        }
    }

    /// Returns a message for the UI when the Keychain write failed, else nil.
    private func persistPassword(_ password: String, loadedPassword: String?) -> String? {
        if let loadedPassword, loadedPassword == password { return nil }  // unchanged
        if loadedPassword == nil, password.isEmpty {
            DebugLog.important("client", "password field empty and no stored password was loaded; leaving the Keychain untouched")
            return nil
        }
        let status = KeychainStore.save(Data(password.utf8), key: Self.passwordKey, accessGroup: Self.keychainAccessGroup)
        return status == errSecSuccess ? nil : "Couldn't save the password to the Keychain (OSStatus \(status))."
    }

    func start() {
        userRequestedStop = false
        guard let manager else {
            lastError = "No saved configuration to start — save one first."
            return
        }
        do {
            try manager.connection.startVPNTunnel()
            if lastError?.hasPrefix("Couldn't save the password") != true { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        userRequestedStop = true
        manager?.connection.stopVPNTunnel()
    }

    #if os(iOS) || os(tvOS)
    /// iOS has no auto-reconnect, so when our extension ends a session itself (engine died, lost the path to the
    /// server after a network change, could not start) the least it owes the user is the reason. Only errors our
    /// extension stamped with a session ID are shown, each once: `fetchLastDisconnectError` is documented only as
    /// "the most recent error", so without the ID a stale one could be shown after a clean stop.
    private func showProviderFailure() {
        fetchLastDisconnectError { [weak self] error in
            guard let error = error as NSError?, error.domain == "NetBridgeTunnel",
                  let id = error.userInfo["sessionID"] as? String else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                guard let self, self.status == .disconnected else { return }
                let defaults = UserDefaults.standard
                guard defaults.string(forKey: Self.lastShownFailureKey) != id else { return }
                defaults.set(id, forKey: Self.lastShownFailureKey)
                DebugLog.important("client", "VPN ended by the extension: \(message)")
                self.lastError = message
            }
        }
    }
    #endif

    /// The error that ended the last session, or `nil` if it ended cleanly (user / `scutil --nc stop`). A tunnel
    /// extension that dies on its own ("The VPN session failed because an internal error occurred") reports one.
    func fetchLastDisconnectError(_ completion: @escaping @Sendable (Error?) -> Void) {
        guard let manager else {
            completion(nil)
            return
        }
        manager.connection.fetchLastDisconnectError(completionHandler: completion)
    }

    #if os(macOS) || os(tvOS)
    /// When the current tunnel session came up, straight from NetworkExtension.
    var connectedDate: Date? { manager?.connection.connectedDate }

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
