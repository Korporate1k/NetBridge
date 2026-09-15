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
    @Published private(set) var lastError: String?
    @Published private(set) var lastActivity: String = "Idle"

    @Published var port: Int
    @Published var additionalListeners: [ListenerConfig] = []
    @Published var autoRestartEnabled = true

    /// The address shown/used everywhere in the UI (Dashboard, QR code, How
    /// To guide) — single source of truth so every screen always agrees on
    /// what "the server address" is, including a manually picked interface.
    @Published private(set) var localIP: String?
    @Published private(set) var availableAddresses: [InterfaceAddress] = []

    let history = ConnectionHistory()
    let usageHistory = UsageHistory()

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

    /// Restart bookkeeping, keyed by port (unique among concurrently running
    /// listeners) since a listener has no other stable identity once started.
    private struct RestartState { var attempts = 0; var windowStart = Date() }
    private var restartState: [Int: RestartState] = [:]
    private static let maxRestartAttempts = 5
    private static let restartWindow: TimeInterval = 60

    init(port: Int = 8080) {
        self.port = port
        NetworkDiagnostics.shared.openTunnelCount = { [weak self] in self?.openTunnelCount() ?? 0 }
        refreshAddresses()
        addressTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshAddresses()
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
        if Date().timeIntervalSince(state.windowStart) > Self.restartWindow {
            state = RestartState()
        }
        guard state.attempts < Self.maxRestartAttempts else {
            DebugLog.important("listener", "port \(port) exceeded \(Self.maxRestartAttempts) restart attempts within \(Int(Self.restartWindow))s, giving up")
            return
        }
        state.attempts += 1
        restartState[port] = state
        let delay = 2.0
        DebugLog.important("listener", "auto-restarting port \(port) in \(delay)s (attempt \(state.attempts) of \(Self.maxRestartAttempts))")
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
        // Each tunnel gets its own dedicated serial queue instead of sharing one
        // global queue across every connection, so concurrent tunnels can't stall
        // each other or the accept loop. Ordering within a tunnel is preserved.
        nextTunnelID += 1
        let id = nextTunnelID
        let tunnelQueue = DispatchQueue(label: "localproxy.tunnel.\(id)", qos: .userInitiated)
        let deviceStats = devices.stats(forDevice: deviceKey, parent: stats)
        let rateLimiter = devices.rateLimiter(forDevice: deviceKey)
        let tunnel = Tunnel(id: id, client: connection, queue: tunnelQueue, stats: deviceStats,
                             transport: outboundTransport, forcedProtocol: mode, rateLimiter: rateLimiter)
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

    // MARK: - Local-network permission

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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.activeConnections = self.stats.activeConnections
            self.bytesUp = self.stats.bytesUp
            self.bytesDown = self.stats.bytesDown
            self.devices.refresh()
        }
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
