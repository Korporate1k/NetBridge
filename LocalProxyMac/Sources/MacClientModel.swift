import Foundation
import Combine
import NetworkExtension

/// One point on the dashboard's throughput chart (bytes per second).
struct ThroughputSample: Identifiable {
    let id = UUID()
    let date: Date
    let up: Double
    let down: Double
}

/// App-wide state for the Mac client: the saved SOCKS5 server, the tunnel
/// (`ClientTunnelManager`, shared with iOS) and live stats polled from the
/// packet-tunnel extension once a second while connected.
@MainActor
final class MacClientModel: ObservableObject {
    @Published var config: ClientConfiguration {
        didSet { persistNonSecrets() }
    }
    @Published var portText: String
    @Published private(set) var stats: TunnelStats = .zero
    @Published private(set) var samples: [ThroughputSample] = []
    @Published private(set) var connectedSince: Date?
    @Published var pairingMessage: String?

    let tunnel = ClientTunnelManager()

    private var pollTimer: Timer?
    private var lastStats: TunnelStats?
    private var lastPoll: Date?
    private var cancellables = Set<AnyCancellable>()

    // Auto-reconnect state (see `sessionEnded()`).
    private var userRequestedStop = false
    /// Set while `connect()` is mid-flight: saving a configuration tears down any running session, and that
    /// teardown is indistinguishable from a crash to `sessionEnded()`.
    private var suppressReconnect = false
    private var sessionWasUp = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private static let reconnectDelays = [2, 5, 15]  // seconds; one entry per attempt
    /// How long a session must last — *and* carry traffic — before earlier reconnect attempts are forgiven.
    private static let healthySeconds: TimeInterval = 60
    private static let lastHandledKey = "mac.client.lastHandledFailureID"

    private static let hostKey = "mac.client.host"
    private static let portKey = "mac.client.port"
    private static let userKey = "mac.client.username"
    private static let passwordKey = "client_password"
    private static let maxSamples = 60

    init() {
        let defaults = UserDefaults.standard
        let savedPort = defaults.integer(forKey: Self.portKey)
        let password = KeychainStore.load(key: Self.passwordKey, accessGroup: ClientTunnelManager.keychainAccessGroup)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let loaded = ClientConfiguration(
            host: defaults.string(forKey: Self.hostKey) ?? "",
            port: UInt16(clamping: savedPort > 0 ? savedPort : 1080),
            username: defaults.string(forKey: Self.userKey) ?? "",
            password: password
        )
        self.config = loaded
        self.portText = String(loaded.port)

        tunnel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &cancellables)
        // `tunnel` is a nested ObservableObject; republish so views observing
        // this model also refresh on status / error changes.
        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        tunnel.loadOrCreate { _ in }

        #if DEBUG
        // Same QA hooks as the iOS app: QA_CLIENT_URI fills the server,
        // QA_CLIENT_AUTOCONNECT=1 connects on launch (`connect()` loads the
        // saved configuration first, so this can't race the initial load).
        let env = ProcessInfo.processInfo.environment
        if let uri = env["QA_CLIENT_URI"], let parsed = ClientConfiguration(uriString: uri) {
            config = parsed
            portText = String(parsed.port)
            if env["QA_CLIENT_AUTOCONNECT"] == "1" {
                connect()
            }
        }
        #endif
    }

    /// Whether the proxy behind a "Connected" tunnel is actually answering.
    ///
    /// `NEVPNStatus.connected` only means the tunnel's network settings were installed — nothing in the stack ever
    /// checks the proxy, and the engine does not exit when it stops responding. So a relay that has gone away looks
    /// exactly like a healthy one from the status alone. The extension probes it and reports the verdict in
    /// `TunnelStats`; this turns that into something the UI can show.
    enum ProxyHealth {
        case notConnected
        /// Connected, but no probe has reported yet (the first lands a few seconds in).
        case checking
        case healthy
        /// Connected, and the proxy is not answering — traffic is going nowhere.
        case unreachable
    }

    var proxyHealth: ProxyHealth {
        guard tunnel.status == .connected || tunnel.status == .reasserting else { return .notConnected }
        guard stats.lastProbe > 0, let reachable = stats.serverReachable else { return .checking }
        return reachable ? .healthy : .unreachable
    }

    var isConnectedOrConnecting: Bool {
        switch tunnel.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    var canConnect: Bool {
        isConnectedOrConnecting || (!config.host.trimmingCharacters(in: .whitespaces).isEmpty && UInt16(portText) != nil)
    }

    func connectOrDisconnect() {
        if isConnectedOrConnecting {
            userRequestedStop = true
            cancelReconnect()
            tunnel.stop()
        } else {
            connect()
        }
    }

    func connect() {
        userRequestedStop = false
        reconnectAttempts = 0
        cancelReconnect()
        if let port = UInt16(portText) { config.port = port }
        config.host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always (re)load the saved configuration first: saving while the launch
        // load is still in flight would create a duplicate VPN configuration.
        // Saving writes the configuration, which ends any session already running. Suppress the reconnect logic
        // across the whole save/start window so that teardown is not mistaken for an unexpected drop.
        suppressReconnect = true
        tunnel.loadOrCreate { [weak self] _ in
            guard let self else { return }
            self.tunnel.save(self.config) { [weak self] result in
                guard let self else { return }
                if case .success = result { self.tunnel.start() }
                self.suppressReconnect = false
            }
        }
    }

    // MARK: - Pairing

    /// Applies a scanned/pasted `socks5://` URI (or bare `host:port`) to the form and connects to it,
    /// matching the iOS scanner. `connect()` saves the new configuration, which ends any session already
    /// running (with auto-reconnect suppressed), so this also switches servers while connected.
    @discardableResult
    func apply(uri: String) -> Bool {
        guard let parsed = ClientConfiguration(uriString: uri) else {
            pairingMessage = "That isn't a valid socks5://host:port address."
            return false
        }
        config = parsed
        portText = String(parsed.port)
        pairingMessage = "Connecting to \(parsed.host):\(parsed.port)…"
        connect()
        return true
    }

    // MARK: - Stats

    private func statusChanged(_ status: NEVPNStatus) {
        if status == .connected {
            sessionWasUp = true
            startPolling()
        } else {
            stopPolling()
            if status == .disconnected || status == .invalid {
                stats = .zero
                samples = []
                connectedSince = nil
            }
            if status == .disconnected { sessionEnded() }
        }
    }

    // MARK: - Auto-reconnect

    /// The tunnel extension can die on its own (NetworkExtension reports "The VPN session failed because an
    /// internal error occurred"). That is not something the user asked for, so bring the VPN back — but only for
    /// a session that was up and ended WITH an error: the Disconnect button and outside stops such as
    /// `scutil --nc stop` end cleanly with no error and are left alone.
    private func sessionEnded() {
        let dropped = sessionWasUp && !userRequestedStop && !suppressReconnect
        sessionWasUp = false
        guard dropped else { return }
        tunnel.fetchLastDisconnectError { [weak self] error in
            Task { @MainActor in
                guard let self, let error = error as NSError? else { return }
                self.considerReconnect(after: error)
            }
        }
    }

    /// `fetchLastDisconnectError` is documented only as returning "the most recent error that caused the VPN to
    /// disconnect" — it promises nothing about being cleared, or about being scoped to the session that just
    /// ended. Rather than trust its freshness, only act on errors our own extension raised (it stamps each one
    /// with a per-session `sessionID`) and only once per ID. A stale error is by definition one already handled,
    /// and the ID is persisted so an app relaunch cannot replay it either.
    ///
    /// The cost of being this strict: if the extension is killed outright it never gets to stamp an error and NE
    /// records its own "Plugin failed" instead, so we will not reconnect. That is the safe direction to fail —
    /// it matches the behaviour before auto-reconnect existed, instead of risking a loop against an unknown cause.
    private func considerReconnect(after error: NSError) {
        guard error.domain == "LocalProxyTunnel", let id = error.userInfo["sessionID"] as? String else {
            DebugLog.important("client", "VPN ended with \(error.domain)/\(error.code) — not one of ours, not reconnecting")
            return
        }
        let defaults = UserDefaults.standard
        guard id != defaults.string(forKey: Self.lastHandledKey) else {
            DebugLog.important("client", "disconnect error for session \(id) already handled; treating as stale")
            return
        }
        defaults.set(id, forKey: Self.lastHandledKey)
        scheduleReconnect(after: error)
    }

    private func scheduleReconnect(after error: Error) {
        guard !userRequestedStop, reconnectAttempts < Self.reconnectDelays.count else {
            DebugLog.important("client", "VPN dropped (\(error.localizedDescription)); not reconnecting (attempts=\(reconnectAttempts))")
            return
        }
        let delay = Self.reconnectDelays[reconnectAttempts]
        reconnectAttempts += 1
        DebugLog.important("client", "VPN dropped (\(error.localizedDescription)); reconnecting in \(delay)s (attempt \(reconnectAttempts))")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self, !Task.isCancelled, !self.userRequestedStop, self.tunnel.status == .disconnected else { return }
            self.tunnel.start()
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        lastStats = nil
        lastPoll = nil
        connectedSince = tunnel.connectedDate
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        tunnel.requestStats { [weak self] data in
            guard let data, let decoded = try? JSONDecoder().decode(TunnelStats.self, from: data) else { return }
            Task { @MainActor in self?.record(decoded) }
        }
    }

    private func record(_ new: TunnelStats) {
        let now = Date()
        if let last = lastStats, let lastPoll, now.timeIntervalSince(lastPoll) > 0.2 {
            let dt = now.timeIntervalSince(lastPoll)
            samples.append(ThroughputSample(
                date: now,
                up: Double(max(0, new.up - last.up)) / dt,
                down: Double(max(0, new.down - last.down)) / dt
            ))
            if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        }
        lastStats = new
        lastPoll = now
        stats = new
        if new.connectedSince > 0 { connectedSince = Date(timeIntervalSince1970: new.connectedSince) }

        // Forgive earlier reconnect attempts only for a session that has lasted a while AND actually carried
        // traffic. Clearing the counter on `.connected` alone was wrong: the tunnel reports connected even when
        // the proxy is unreachable and nothing flows, so any fault spaced more than a minute apart could retry
        // for ever without the cap biting.
        if reconnectAttempts > 0, new.down > 0, let since = connectedSince,
           now.timeIntervalSince(since) >= Self.healthySeconds {
            DebugLog.important("client", "session healthy (\(Int(now.timeIntervalSince(since)))s up, \(new.down) B down); clearing reconnect attempts")
            reconnectAttempts = 0
        }
    }

    private func persistNonSecrets() {
        let defaults = UserDefaults.standard
        defaults.set(config.host, forKey: Self.hostKey)
        defaults.set(Int(config.port), forKey: Self.portKey)
        defaults.set(config.username, forKey: Self.userKey)
    }
}
