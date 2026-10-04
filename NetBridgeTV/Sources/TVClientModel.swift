import Foundation
import Combine
import NetworkExtension

/// App-wide state for the tvOS client: the saved SOCKS5 server, the tunnel (`ClientTunnelManager`, shared with
/// iOS and macOS) and live stats polled from the packet-tunnel extension once a second while connected.
///
/// Like iOS, nothing reconnects automatically: when the extension ends a session itself, `ClientTunnelManager`
/// puts the reason in `lastError` and the screen shows it.
@MainActor
final class TVClientModel: ObservableObject {
    /// What the user types or pastes: `socks5://[user[:pass]@]host:port`, or a bare `host:port`.
    @Published var linkText = ""
    @Published private(set) var config: ClientConfiguration?
    @Published private(set) var stats: TunnelStats = .zero
    @Published var message: String?
    /// True while a Connect is saving the configuration: a second press then must not start another save (on a first
    /// run that could create a duplicate VPN configuration, and the duplicate clean-up is macOS-only).
    @Published private(set) var isSaving = false

    let tunnel = ClientTunnelManager()

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    /// Stats requests go out one at a time, and replies from an earlier session are dropped (see MacClientModel).
    private var pollGeneration = 0
    private var pollInFlightSince: Date?
    /// The password last read from / written to the Keychain (`nil` = the read failed). See `ClientTunnelManager.save`.
    private var loadedPassword: String?

    init() {
        tunnel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.statusChanged($0) }
            .store(in: &cancellables)
        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        tunnel.loadOrCreate { [weak self] _ in
            guard let self, let saved = self.tunnel.savedConfiguration() else { return }
            self.loadedPassword = saved.password
            self.config = saved.config
            if self.linkText.isEmpty { self.linkText = Self.displayLink(saved.config) }
        }

        #if DEBUG
        // Same QA hooks as the iOS and Mac apps.
        let env = ProcessInfo.processInfo.environment
        if let uri = env["QA_CLIENT_URI"] {
            linkText = uri
            if env["QA_CLIENT_AUTOCONNECT"] == "1" { connect() }
        }
        #endif
    }

    /// The link without the password, so it is never drawn on a television. The username stays visible: submitting
    /// the field unchanged keeps the saved password; deleting `user@` means "no credentials" (see `connect()`).
    private static func displayLink(_ config: ClientConfiguration) -> String {
        var shown = config
        shown.password = ""
        return shown.uriString
    }

    var isConnectedOrConnecting: Bool {
        switch tunnel.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    var canConnect: Bool {
        !isSaving && (isConnectedOrConnecting || ClientConfiguration(uriString: linkText) != nil || config != nil)
    }

    /// Whether the proxy behind a "Connected" tunnel is actually answering (`NEVPNStatus.connected` only means
    /// the tunnel's network settings were installed). Same states as the Mac client.
    enum ProxyHealth {
        case notConnected
        case checking
        /// `udp`: whether the server granted UDP ASSOCIATE (`nil` = not reported).
        case healthy(udp: Bool?)
        case authRejected
        case unreachable
    }

    var proxyHealth: ProxyHealth {
        if tunnel.status == .reasserting { return .checking }   // stats polling pauses while reconnecting: no stale verdict
        guard tunnel.status == .connected else { return .notConnected }
        guard stats.lastProbe > 0, let reachable = stats.serverReachable else { return .checking }
        if !reachable { return .unreachable }
        if stats.authRejected == true { return .authRejected }
        return .healthy(udp: stats.udpRelayed)
    }

    func connectOrDisconnect() {
        if isConnectedOrConnecting {
            tunnel.stop()
        } else {
            connect()
        }
    }

    func connect() {
        guard !isSaving else { return }
        message = nil
        // A typed link wins; an empty field falls back to the saved server.
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        var target = config
        if !trimmed.isEmpty {
            guard var parsed = ClientConfiguration(uriString: trimmed) else {
                message = "That isn't a valid socks5://host:port address."
                return
            }
            // The field never shows the saved password. The same server with the same username and no password typed
            // keeps the saved password; a link without a username means no credentials at all (that is how they are
            // removed), so it is NOT filled back in.
            if parsed.password.isEmpty, !parsed.username.isEmpty, parsed.username == config?.username,
               parsed.host == config?.host, parsed.port == config?.port {
                parsed.password = config?.password ?? ""
            }
            target = parsed
        }
        guard let target else { return }
        config = target
        isSaving = true
        // Always reload the saved configuration before saving, so a launch-time load still in flight can't
        // lead to a duplicate VPN configuration.
        tunnel.loadOrCreate { [weak self] _ in
            guard let self else { return }
            let attempted = target.password
            self.tunnel.save(target, loadedPassword: self.loadedPassword) { [weak self] result in
                guard let self else { return }
                self.isSaving = false
                if case .success = result {
                    if !(self.loadedPassword == nil && attempted.isEmpty) { self.loadedPassword = attempted }
                    self.linkText = Self.displayLink(target)
                    self.tunnel.start()
                }
            }
        }
    }

    // MARK: - Stats

    private func statusChanged(_ status: NEVPNStatus) {
        if status == .connected {
            startPolling()
        } else {
            stopPolling()
            // reasserting too: polling is paused, so the last counters would sit frozen on screen
            if status == .disconnected || status == .invalid || status == .reasserting { stats = .zero }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollGeneration += 1
        pollInFlightSince = nil
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollGeneration += 1
        pollInFlightSince = nil
    }

    private func poll() {
        if let since = pollInFlightSince, Date().timeIntervalSince(since) < 5 { return }
        pollInFlightSince = Date()
        let generation = pollGeneration
        tunnel.requestStats { [weak self] data in
            let decoded = data.flatMap { try? JSONDecoder().decode(TunnelStats.self, from: $0) }
            Task { @MainActor in
                guard let self, generation == self.pollGeneration else { return }
                self.pollInFlightSince = nil
                if let decoded { self.stats = decoded }
            }
        }
    }
}
