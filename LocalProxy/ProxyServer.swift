import Foundation
import Combine
import Network

/// Runs the HTTP CONNECT proxy on Network.framework's `NWListener` — the
/// sandbox-sanctioned way to listen on iOS (raw POSIX `bind` to a non-loopback
/// address is rejected in the app sandbox).
///
/// The primary listener (`port`, always `.auto`-sniffing) behaves exactly as
/// the original single-listener design; `additionalListeners` are optional
/// extra ports (each with its own forced or auto protocol mode) started and
/// stopped alongside it.
final class ProxyServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var activeConnections = 0
    @Published private(set) var bytesUp: UInt64 = 0
    @Published private(set) var bytesDown: UInt64 = 0
    @Published private(set) var rateUp: Double = 0
    @Published private(set) var rateDown: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastActivity: String = "Idle"

    @Published var port: Int { didSet { saveLastSettings() } }
    @Published var additionalListeners: [ListenerConfig] = [] { didSet { saveLastSettings() } }
    @Published var autoRestartEnabled = true { didSet { saveLastSettings() } }
    /// Opt-in RFC 1929 SOCKS5 auth requirement — empty (the default) means
    /// no-auth only, identical to this project's original behavior. Both
    /// must be non-empty for auth to actually be required (see `accept(_:mode:)`).
    @Published var requiredUsername: String = "" { didSet { saveLastSettings() } }
    @Published var requiredPassword: String = "" { didSet { saveLastSettings() } }

    /// The address shown/used everywhere in the UI (Dashboard, QR code, How
    /// To guide) — single source of truth so every screen always agrees on
    /// what "the server address" is, including a manually picked interface.
    @Published private(set) var localIP: String?
    @Published private(set) var availableAddresses: [InterfaceAddress] = []

    let history = ConnectionHistory()
    let usageHistory = UsageHistory()
    let dailyUsage = DailyUsageTracker()

    /// Set by `DashboardView` from its `PurchaseManager`/`TrialManager` —
    /// kept as a closure rather than a hard dependency so `ProxyServer`
    /// doesn't need to know anything about StoreKit or trial tracking.
    /// True for a Pro purchase OR an active free trial; either bypasses
    /// `dailyUsage`'s cap entirely.
    var bypassesDailyCap: () -> Bool = { false }

    // MARK: - Remote-controlled reliability/safety settings
    // All set by `RemoteConfigManager`; each defaults to today's exact
    // behavior so an unreachable/not-yet-published config changes nothing.

    /// Global kill switch — when this returns `false`, `start()` refuses to
    /// start (and a live `RemoteConfigManager` fetch calls `stop()` directly
    /// if already running). For an emergency/legal takedown without an app
    /// update.
    var relayEnabled: () -> Bool = { true }
    @Published var maxRestartAttempts = 5
    @Published var restartWindow: TimeInterval = 60
    /// `0` means unlimited (today's behavior) — no cap existed before this.
    @Published var maxConcurrentTunnels = 0
    @Published var outboundRetryAttempts = 3
    @Published var outboundRetryBaseSeconds: Double = 1

    // Dedicated to the listener/accept loop only — tunnel I/O never runs here, so
    // accepting new connections is never delayed behind another tunnel's traffic.
    private let listenerQueue = DispatchQueue(label: "localproxy.listener", qos: .userInitiated)
    private let stats = ProxyStats()
    let devices = DeviceRegistry()
    private let outboundTransport = DirectTCPTransport()
    private let tunnelsLock = NSLock()
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]
    private var tunnelHighWater = 0
    private var listener: NWListener?
    private var extraListeners: [Int: NWListener] = [:] // keyed by port
    private var refreshTimer: Timer?
    private var throughputLogTimer: DispatchSourceTimer?
    private var usageSampleTimer: DispatchSourceTimer?
    private var lastLoggedBytesUp: UInt64 = 0
    private var lastLoggedBytesDown: UInt64 = 0
    private var isStarting = false
    private var nextTunnelID = 0
    private var userRequestedStop = false
    private var addressTimer: Timer?
    private var lastRateSample: (up: UInt64, down: UInt64, at: Date)?
    private var loadingLastSettings = false

    /// Restart bookkeeping, keyed by port (unique among concurrently running
    /// listeners) since a listener has no other stable identity once started.
    private struct RestartState { var attempts = 0; var windowStart = Date() }
    private var restartState: [Int: RestartState] = [:]

    private static let lastSettingsKey = "server.lastSettings"
    private struct LastSettings: Codable {
        var port: Int
        var additionalListeners: [ListenerConfig]
        var autoRestartEnabled: Bool
        var requiredUsername: String
        var requiredPassword: String

        // Both init(from:) and encode(to:) below are hand-written, so Swift
        // no longer auto-synthesizes this either — must be explicit.
        private enum CodingKeys: String, CodingKey {
            case port, additionalListeners, autoRestartEnabled, requiredUsername, requiredPassword
        }

        init(port: Int, additionalListeners: [ListenerConfig], autoRestartEnabled: Bool,
             requiredUsername: String = "", requiredPassword: String = "") {
            self.port = port
            self.additionalListeners = additionalListeners
            self.autoRestartEnabled = autoRestartEnabled
            self.requiredUsername = requiredUsername
            self.requiredPassword = requiredPassword
        }

        // Custom decode so settings saved before `requiredUsername`/
        // `requiredPassword` existed (missing keys) still decode successfully
        // instead of failing the whole blob and silently reverting port/
        // listeners/auto-restart to defaults too.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            port = try container.decode(Int.self, forKey: .port)
            additionalListeners = try container.decode([ListenerConfig].self, forKey: .additionalListeners)
            autoRestartEnabled = try container.decode(Bool.self, forKey: .autoRestartEnabled)
            requiredUsername = try container.decodeIfPresent(String.self, forKey: .requiredUsername) ?? ""
            requiredPassword = try container.decodeIfPresent(String.self, forKey: .requiredPassword) ?? ""
        }

        // A custom init(from:) in the primary declaration disables Swift's
        // automatic synthesis of encode(to:) too, so this must be explicit.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(port, forKey: .port)
            try container.encode(additionalListeners, forKey: .additionalListeners)
            try container.encode(autoRestartEnabled, forKey: .autoRestartEnabled)
            try container.encode(requiredUsername, forKey: .requiredUsername)
            try container.encode(requiredPassword, forKey: .requiredPassword)
        }
    }

    init(port: Int = 8080) {
        self.port = port
        NetworkDiagnostics.shared.openTunnelCount = { [weak self] in self?.openTunnelCount() ?? 0 }
        loadLastSettings()
        refreshAddresses()
        addressTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshAddresses()
        }
    }

    // MARK: - Last-used settings (relaunch persistence, not anti-abuse —
    // plain UserDefaults, unlike the Keychain-backed trial/usage trackers)

    /// Loads the last-used port/listeners/auto-restart, if any were saved.
    /// Runs before `didSet` observers matter (still inside `init()`, where
    /// Swift doesn't fire property observers for a type's own initial
    /// assignments), so this never immediately re-triggers a save.
    private func loadLastSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastSettingsKey) else {
            DebugLog.important("server", "loadLastSettings: no data found for key \(Self.lastSettingsKey)")
            return
        }
        guard let saved = try? JSONDecoder().decode(LastSettings.self, from: data) else {
            DebugLog.important("server", "loadLastSettings: decode FAILED, raw=\(String(data: data, encoding: .utf8) ?? "?")")
            return
        }
        DebugLog.important("server", "loadLastSettings: decoded port=\(saved.port) autoRestart=\(saved.autoRestartEnabled) listeners=\(saved.additionalListeners.count) — applying now (current port=\(port))")
        port = saved.port
        additionalListeners = saved.additionalListeners
        autoRestartEnabled = saved.autoRestartEnabled
        requiredUsername = saved.requiredUsername
        requiredPassword = saved.requiredPassword
        DebugLog.important("server", "loadLastSettings: applied — port is now \(port)")
    }

    private func saveLastSettings() {
        let settings = LastSettings(port: port, additionalListeners: additionalListeners, autoRestartEnabled: autoRestartEnabled,
                                     requiredUsername: requiredUsername, requiredPassword: requiredPassword)
        DebugLog.important("server", "saveLastSettings: writing port=\(port) autoRestart=\(autoRestartEnabled) listeners=\(additionalListeners.count)")
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.lastSettingsKey)
        }
    }

    // MARK: - Address selection

    /// Refreshes `availableAddresses`. Keeps the current `localIP` if it's
    /// still valid (e.g. the user picked a specific interface); otherwise
    /// falls back to the first available address. Runs continuously
    /// (independent of `isRunning`) so every tab always shows the same,
    /// current address — not just the Dashboard.
    private func refreshAddresses() {
        let all = LocalAddress.allIPv4()
        availableAddresses = all
        if let current = localIP, all.contains(where: { $0.ip == current }) {
            return
        }
        localIP = all.first?.ip
    }

    func selectAddress(_ ip: String) {
        localIP = ip
    }

    func start() {
        guard !isRunning else { return }
        guard relayEnabled() else {
            DebugLog.important("listener", "start refused — relay disabled remotely")
            lastError = "This service is temporarily unavailable. Please try again later."
            return
        }
        userRequestedStop = false
        listenerQueue.async { [self] in
            if self.isStarting { return }
            self.isStarting = true
            defer { self.isStarting = false }

            DebugLog.important("listener", "start requested, primary port \(self.port), \(self.additionalListeners.count) additional listener(s)")
            let permissionStart = DispatchTime.now()
            let permission = self.requestLocalNetworkPermission()
            let permissionMs = Double(DispatchTime.now().uptimeNanoseconds - permissionStart.uptimeNanoseconds) / 1_000_000
            DebugLog.important("listener", "local network permission: \(permission) (took \(String(format: "%.0f", permissionMs))ms)")
            guard permission == .granted else {
                DispatchQueue.main.async {
                    self.lastError = permission == .denied
                        ? "Local network access is required. Enable it in Settings → Privacy & Security → Local Network → LocalProxy, then tap Start again."
                        : "Waiting for local network permission. Tap Start again after answering the prompt."
                }
                return
            }

            self.startOneListener(port: self.port, mode: .auto, isPrimary: true)
            for config in self.additionalListeners {
                self.startOneListener(port: config.port, mode: config.mode, isPrimary: false)
            }
        }
    }

    func stop() {
        userRequestedStop = true
        DebugLog.important("listener", "stop requested, closing \(openTunnelCount()) open tunnel(s); session high-water mark \(tunnelHighWater) concurrent")
        let l = listener
        listener = nil
        l?.cancel()
        for (_, extra) in extraListeners { extra.cancel() }
        extraListeners.removeAll()
        restartState.removeAll()
        closeAllTunnels()
        stats.reset()
        refreshTimer?.invalidate()
        refreshTimer = nil
        throughputLogTimer?.cancel()
        throughputLogTimer = nil
        usageSampleTimer?.cancel()
        usageSampleTimer = nil
        usageHistory.reset()
        devices.refresh(isRunning: false)
        devices.save()
        isRunning = false
        activeConnections = 0
        bytesUp = 0
        bytesDown = 0
        rateUp = 0
        rateDown = 0
        lastRateSample = nil
    }

    /// Called by `RemoteConfigManager` when `relayEnabled` flips to `false`
    /// while the proxy is already running — stops it immediately rather
    /// than waiting for the user to notice.
    func stopIfDisallowed() {
        guard isRunning, !relayEnabled() else { return }
        DebugLog.important("listener", "stopping — relay disabled remotely while running")
        lastError = "This service is temporarily unavailable. Please try again later."
        stop()
    }

    // MARK: - Listener lifecycle

    private func startOneListener(port: Int, mode: ListenerMode, isPrimary: Bool) {
        guard let listenPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            DebugLog.important("listener", "invalid port \(port)")
            if isPrimary { DispatchQueue.main.async { self.lastError = "Invalid port \(port)." } }
            return
        }
        do {
            // `.tunedTCP()` (OutboundTransport.swift) applies the same
            // TCP tuning (TCP_NODELAY, no ACK stretching, prohibitExpensivePaths
            // pinned false, `.responsiveData` service class) to inbound
            // accepted connections that `DirectTCPTransport` applies to
            // outbound dials, so both legs of a relayed connection match.
            let listener = try NWListener(using: .tunedTCP(), on: listenPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, mode: mode)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, port: port, mode: mode, isPrimary: isPrimary, listener: listener)
            }
            listener.start(queue: self.listenerQueue)
            if isPrimary {
                self.listener = listener
            } else {
                self.extraListeners[port] = listener
            }
        } catch {
            DebugLog.important("listener", "NWListener init threw for port \(port): \(ErrorDescription.describe(error))")
            if isPrimary {
                DispatchQueue.main.async { self.lastError = "Failed to start: \(error.localizedDescription)" }
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: Int, mode: ListenerMode, isPrimary: Bool, listener: NWListener) {
        let tag = isPrimary ? "primary" : "extra(\(mode.label))"
        switch state {
        case .setup:
            DebugLog.debug("listener", "\(tag) port \(port) state setup")
        case .ready:
            DebugLog.important("listener", "\(tag) READY on port \(port) (listener.port=\(listener.port.map { "\($0)" } ?? "nil"))")
            restartState[port] = nil
            if isPrimary {
                startThroughputLogging()
                startUsageSampling()
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.lastError = nil
                    self.startRefreshing()
                }
            }
        case .waiting(let error):
            DebugLog.important("listener", "\(tag) port \(port) state WAITING \(ErrorDescription.describe(error))")
        case .failed(let error):
            DebugLog.important("listener", "\(tag) port \(port) state FAILED \(ErrorDescription.describe(error))")
            let isConflict = { if case .posix(let code) = error, code.rawValue == EADDRINUSE { return true }; return false }()
            if isPrimary {
                DispatchQueue.main.async {
                    if isConflict {
                        self.lastError = "Port \(port) is already in use. Fully quit the app (swipe it away) and relaunch, or choose a different port."
                    } else {
                        self.lastError = "Failed to start: \(error.localizedDescription)"
                    }
                }
            }
            self.maybeAutoRestart(port: port, mode: mode, isPrimary: isPrimary, isConflict: isConflict)
        case .cancelled:
            DebugLog.important("listener", "\(tag) port \(port) state cancelled")
        @unknown default:
            DebugLog.important("listener", "\(tag) port \(port) state unknown \(state)")
        }
    }

    /// Retries a listener that failed unexpectedly (not a user-initiated
    /// `stop()`, not a port conflict — looping on `EADDRINUSE` would never
    /// succeed). Capped at `maxRestartAttempts` within a rolling
    /// `restartWindow`, reset once a listener has been `.ready` again
    /// (see the `.ready` case above, which clears `restartState[port]`).
    private func maybeAutoRestart(port: Int, mode: ListenerMode, isPrimary: Bool, isConflict: Bool) {
        guard autoRestartEnabled, !userRequestedStop, !isConflict else { return }
        var state = restartState[port] ?? RestartState()
        if Date().timeIntervalSince(state.windowStart) > restartWindow {
            state = RestartState()
        }
        guard state.attempts < maxRestartAttempts else {
            DebugLog.important("listener", "port \(port) exceeded \(maxRestartAttempts) restart attempts within \(Int(restartWindow))s, giving up")
            return
        }
        state.attempts += 1
        restartState[port] = state
        let delay = 2.0
        DebugLog.important("listener", "auto-restarting port \(port) in \(delay)s (attempt \(state.attempts) of \(maxRestartAttempts))")
        listenerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.userRequestedStop else { return }
            self.startOneListener(port: port, mode: mode, isPrimary: isPrimary)
        }
    }

    private func accept(_ connection: NWConnection, mode: ListenerMode) {
        let deviceKey = DeviceRegistry.deviceKey(for: connection.endpoint)
        guard !devices.isBlocked(deviceKey) else {
            DebugLog.important("listener", "refused connection from blocked device \(deviceKey)")
            connection.cancel()
            return
        }
        // Free-tier daily cap: refuse *new* connections once today's total is
        // hit; already-open tunnels are left to finish rather than cut mid-
        // transfer. Pro users bypass this entirely.
        guard bypassesDailyCap() || !dailyUsage.isOverLimit else {
            DebugLog.important("listener", "refused connection — daily free-tier cap reached")
            connection.cancel()
            return
        }
        // Remote-configurable concurrency ceiling — `0` (default) means
        // unlimited, same as the original no-cap design.
        if maxConcurrentTunnels > 0 && openTunnelCount() >= maxConcurrentTunnels {
            DebugLog.important("listener", "refused connection — at max concurrent tunnels (\(maxConcurrentTunnels))")
            connection.cancel()
            return
        }
        // Each tunnel gets its own dedicated serial queue instead of sharing one
        // global queue across every connection, so concurrent tunnels can't stall
        // each other or the accept loop. Ordering within a tunnel is preserved.
        nextTunnelID += 1
        let id = nextTunnelID
        let tunnelQueue = DispatchQueue(label: "localproxy.tunnel.\(id)", qos: .userInitiated)
        let deviceStats = devices.stats(forDevice: deviceKey, parent: stats)
        let rateLimiter = devices.rateLimiter(forDevice: deviceKey)
        let credentials: (username: String, password: String)? =
            (requiredUsername.isEmpty || requiredPassword.isEmpty) ? nil : (requiredUsername, requiredPassword)
        let tunnel = Tunnel(id: id, client: connection, queue: tunnelQueue, stats: deviceStats,
                             transport: outboundTransport, forcedProtocol: mode, rateLimiter: rateLimiter,
                             retryAttempts: outboundRetryAttempts, retryBaseSeconds: outboundRetryBaseSeconds,
                             requiredCredentials: credentials)
        tunnel.openTunnelCount = { [weak self] in self?.openTunnelCount() ?? 0 }
        track(tunnel)
        tunnel.onClose = { [weak self, weak tunnel] in
            if let tunnel = tunnel { self?.untrack(tunnel) }
        }
        tunnel.onActivity = { [weak self] message in
            DispatchQueue.main.async { self?.lastActivity = message }
        }
        tunnel.onSummary = { [weak self] summary in
            self?.history.record(summary)
        }
        tunnel.start()
    }

    private func openTunnelCount() -> Int {
        tunnelsLock.lock(); defer { tunnelsLock.unlock() }
        return tunnels.count
    }

    private func track(_ tunnel: Tunnel) {
        tunnelsLock.lock()
        tunnels[ObjectIdentifier(tunnel)] = tunnel
        let count = tunnels.count
        let newHighWater = count > tunnelHighWater
        if newHighWater { tunnelHighWater = count }
        tunnelsLock.unlock()
        if newHighWater {
            DebugLog.important("listener", "new concurrent tunnel high-water mark: \(count)")
        }
    }

    private func untrack(_ tunnel: Tunnel) {
        tunnelsLock.lock(); tunnels.removeValue(forKey: ObjectIdentifier(tunnel)); tunnelsLock.unlock()
    }

    private func closeAllTunnels() {
        tunnelsLock.lock(); let snapshot = Array(tunnels.values); tunnelsLock.unlock()
        for tunnel in snapshot { tunnel.cancel() }
    }

    private enum PermissionResult { case granted, denied, timedOut }

    /// Triggers the iOS local-network consent prompt via a Bonjour browse (the
    /// canonical trigger; a raw socket bind does not surface the prompt).
    private func requestLocalNetworkPermission() -> PermissionResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: PermissionResult = .timedOut

        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            DebugLog.debug("listener", "permission browser state \(state)")
            switch state {
            case .ready:
                result = .granted
                browser.cancel()
                semaphore.signal()
            case .failed(let error):
                if case .posix(let code) = error, code.rawValue == EPERM {
                    result = .denied
                } else {
                    result = .granted
                }
                browser.cancel()
                semaphore.signal()
            case .waiting:
                break
            default:
                break
            }
        }
        browser.start(queue: .main)
        _ = semaphore.wait(timeout: .now() + 25)
        browser.cancel()
        return result
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        lastRateSample = nil
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.activeConnections = self.stats.activeConnections
            self.bytesUp = self.stats.bytesUp
            self.bytesDown = self.stats.bytesDown
            self.updateRates()
            self.devices.refresh()
        }
    }

    /// Owned by this class's own `refreshTimer` rather than a View-level
    /// `Timer.publish` — a per-View timer gets torn down and recreated every
    /// time SwiftUI reconstructs that View (which happens on every one of
    /// this class's `@Published` updates), so it can end up never actually
    /// firing if reconstructions happen faster than the timer's own period.
    private func updateRates() {
        let now = Date()
        defer { lastRateSample = (bytesUp, bytesDown, now) }
        guard let last = lastRateSample else { return }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed > 0 else { return }
        rateUp = bytesUp >= last.up ? Double(bytesUp - last.up) / elapsed : 0
        rateDown = bytesDown >= last.down ? Double(bytesDown - last.down) / elapsed : 0
    }

    /// App-level aggregate throughput, once/sec on `listenerQueue` — deliberately
    /// a separate 1Hz timer (not a reuse of the 0.5s UI-refresh timer above) so its
    /// rate lines up exactly with `NetworkDiagnostics`' existing 1Hz NIC-level
    /// `[iface] bytes/s` line, making the two directly comparable: the gap between
    /// them is LocalProxy's own relay overhead vs. whatever the NIC actually moved.
    private func startThroughputLogging() {
        throughputLogTimer?.cancel()
        lastLoggedBytesUp = 0
        lastLoggedBytesDown = 0
        let timer = DispatchSource.makeTimerSource(queue: listenerQueue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tickThroughputLog() }
        timer.resume()
        throughputLogTimer = timer
    }

    private func tickThroughputLog() {
        let up = stats.bytesUp
        let down = stats.bytesDown
        let tunnels = openTunnelCount()
        guard tunnels > 0 else {
            lastLoggedBytesUp = up
            lastLoggedBytesDown = down
            return
        }
        let deltaUp = up &- lastLoggedBytesUp
        let deltaDown = down &- lastLoggedBytesDown
        lastLoggedBytesUp = up
        lastLoggedBytesDown = down
        DebugLog.debug("throughput", "app bytes/s tunnels=\(tunnels) up=\(deltaUp) down=\(deltaDown) | totals up=\(up) down=\(down)")
        DispatchQueue.main.async { self.dailyUsage.add(deltaUp &+ deltaDown) }
    }

    /// Feeds the "Historical usage" graph — a slower-cadence, UI-facing
    /// cousin of `startThroughputLogging()` above.
    private func startUsageSampling() {
        usageSampleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: listenerQueue)
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let up = self.stats.bytesUp
            let down = self.stats.bytesDown
            DispatchQueue.main.async { self.usageHistory.sample(bytesUp: up, bytesDown: down) }
        }
        timer.resume()
        usageSampleTimer = timer
    }
}
