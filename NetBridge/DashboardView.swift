import SwiftUI
import Combine
import CoreLocation

struct DashboardView: View {
    @StateObject private var server: ProxyServer
    @StateObject private var keeper = BackgroundKeeper()
    @StateObject private var purchases = PurchaseManager()
    @StateObject private var trial: TrialManager
    @StateObject private var remoteConfig: RemoteConfigManager
    @StateObject private var clientTunnelManager: ClientTunnelManager
    @State private var clientConfig = ClientConfiguration(host: "", port: 1080)
    @State private var selectedTab = 0
    @State private var markCount = 0
    @State private var lastMark: String?
    @Environment(\.scenePhase) private var scenePhase

    private static var wroteSessionHeader = false

    /// Builds `BackgroundKeeper.onDisableRequested` with `keeper` captured
    /// weakly — that static property is a genuinely long-lived reference and
    /// shouldn't keep this particular `keeper` instance alive forever. Kept
    /// as a separate function (rather than a `weak var` local in `onAppear`)
    /// so the capture list is the only place `keeper` is weak — `onAppear`
    /// itself still needs it strongly a few lines below for the immediate
    /// `keeper.authorizationStatus`/`keeper.isKeepingAlive` reads.
    private static func makeDisableHandler(for keeper: BackgroundKeeper) -> () -> Void {
        { [weak keeper] in keeper?.stop() }
    }

    init() {
        // `RemoteConfigManager` needs a live `ProxyServer` (for the relay
        // kill switch, daily cap, retry/restart tuning, etc.) and
        // `TrialManager` (for trial management) — build those first and
        // hand them in.
        let serverInstance = ProxyServer()
        let trialManager = TrialManager()
        let clientTunnelManagerInstance = ClientTunnelManager()
        _server = StateObject(wrappedValue: serverInstance)
        _trial = StateObject(wrappedValue: trialManager)
        _remoteConfig = StateObject(wrappedValue: RemoteConfigManager(trial: trialManager, server: serverInstance))
        _clientTunnelManager = StateObject(wrappedValue: clientTunnelManagerInstance)
        #if DEBUG
        // QA automation hook: no Mac Accessibility permission is available in some
        // testing environments to drive simulator taps, so a launch-time env var
        // (set via `SIMCTL_CHILD_QA_TAB=<0-4> xcrun simctl launch ...`) lets a
        // terminal-only QA pass select a starting tab without any tap. DEBUG-only,
        // compiled out of Release/IPA builds entirely. 0=Dashboard 1=Client
        // 2=Devices 3=Settings.
        if let tabString = ProcessInfo.processInfo.environment["QA_TAB"], let tab = Int(tabString) {
            _selectedTab = State(initialValue: tab)
        }
        // Sets the primary listener port before `start()` fires below, so a
        // QA pass can exercise a non-default port without typing into the
        // Settings port stepper by hand. Must be set before QA_AUTOSTART's
        // `start()` call, since `port` can only change while stopped.
        if let portString = ProcessInfo.processInfo.environment["QA_SERVER_PORT"], let port = Int(portString) {
            serverInstance.port = port
        }
        // Opt-in RFC 1929 SOCKS5 auth requirement — same rationale as the
        // other QA_* hooks, lets a QA pass exercise the auth round-trip
        // without a Settings-tab tap. Both must be set for auth to actually
        // be required (see `ProxyServer.accept(_:mode:)`).
        if let user = ProcessInfo.processInfo.environment["QA_SERVER_SOCKS5_USER"] {
            serverInstance.requiredUsername = user
        }
        if let pass = ProcessInfo.processInfo.environment["QA_SERVER_SOCKS5_PASS"] {
            serverInstance.requiredPassword = pass
        }
        // Same rationale as QA_TAB: starts the proxy without a tap, for a
        // terminal-only QA pass (`SIMCTL_CHILD_QA_AUTOSTART=1 xcrun simctl launch ...`).
        if ProcessInfo.processInfo.environment["QA_AUTOSTART"] != nil {
            serverInstance.start()
        }
        #endif
    }

    var body: some View {
        Group {
            if isBelowMinimumVersion {
                UpdateRequiredView()
            } else {
                TabView(selection: $selectedTab) {
                    HomeTabView(server: server, keeper: keeper, purchases: purchases, trial: trial,
                                remoteConfig: remoteConfig)
                        .tabItem { Label("Dashboard", systemImage: "bolt.horizontal.circle") }
                        .tag(0)

                    ClientTabView(server: server, config: clientConfig, tunnelManager: clientTunnelManager,
                                  showTester: remoteConfig.showSocks5Tester)
                        .tabItem { Label("Client", systemImage: "network") }
                        .tag(1)

                    DevicesView(registry: server.devices, history: server.history,
                                showControls: remoteConfig.showDeviceBandwidthControls)
                        .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                        .tag(2)

                    SettingsView(server: server, keeper: keeper, purchases: purchases, trial: trial,
                                 remoteConfig: remoteConfig, markCount: $markCount, lastMark: $lastMark)
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(3)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // A subscription can lapse (or be renewed/refunded elsewhere) while the app is in the background.
            if phase == .active { Task { await purchases.refresh() } }
        }
        .onAppear {
            server.bypassesDailyCap = { !remoteConfig.paywallEnabled || purchases.isPro || trial.isInTrial }
            BackgroundKeeper.onDisableRequested = Self.makeDisableHandler(for: keeper)
            if !Self.wroteSessionHeader {
                Self.wroteSessionHeader = true
                DebugLog.writeSessionHeader(port: server.port,
                                            locationStatus: BackgroundKeeper.describe(keeper.authorizationStatus),
                                            keepAlive: keeper.isKeepingAlive)
            }
            #if DEBUG
            // QA automation hook, same rationale as QA_TAB above: taps "Start" from
            // Terminal with no UI automation available. Delayed so the first remote
            // config fetch (which can flip relayEnabled) has a chance to land first.
            if ProcessInfo.processInfo.environment["QA_AUTOSTART"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    DebugLog.important("qa", "QA_AUTOSTART firing server.start()")
                    server.start()
                }
            }
            // Client-tab VPN autoconnect, independent of QA_TAB: this is the
            // top-level view's own onAppear (fires once per real appearance,
            // unlike `init()` which SwiftUI can call more than once — an
            // earlier version of this hook lived in `init()` and called
            // `.save()` on a locally-constructed `ClientTunnelManager()`
            // that could differ from the one `@StateObject` actually retains
            // across reconstructions, so the real UI-observed instance never
            // saw the save/start calls. Using `self.clientTunnelManager`
            // here is the stable, correct reference. Lets a QA pass bring
            // the system VPN up regardless of which tab is initially
            // selected (e.g. landing on Settings' Upload Throughput Test).
            //
            // `loadOrCreate` must run first: `ClientTunnelManager.save()`
            // creates a brand-new `NETunnelProviderManager()` whenever its
            // own `manager` is still nil, which it always is until
            // `loadOrCreate` populates it from `loadAllFromPreferences`. If
            // `ClientTabView` also happens to be mounted (QA_TAB=1), its own
            // onAppear calls `loadOrCreate` too — calling `save()` here
            // without loading first raced that call and could leave
            // `manager` pointing at a different object than the one actually
            // saved/started, intermittently breaking the whole autoconnect.
            if let uri = ProcessInfo.processInfo.environment["QA_CLIENT_URI"],
               let parsed = ClientConfiguration(uriString: uri) {
                clientTunnelManager.loadOrCreate { _ in
                    clientTunnelManager.save(parsed) { result in
                        if case .success = result, ProcessInfo.processInfo.environment["QA_CLIENT_AUTOCONNECT"] == "1" {
                            clientTunnelManager.start()
                        }
                    }
                }
            }
            QATraffic.startIfRequested()
            #endif
        }
    }

    /// `remoteConfig.minSupportedVersion` empty means "no gate" — compares
    /// dotted version strings component-by-component (not lexically, so
    /// "1.10" correctly beats "1.9").
    private var isBelowMinimumVersion: Bool {
        let minVersion = remoteConfig.minSupportedVersion
        guard !minVersion.isEmpty,
              let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return false }
        return currentVersion.compare(minVersion, options: .numeric) == .orderedAscending
    }
}

private struct UpdateRequiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Update Required")
                .font(.title2.weight(.bold))
            Text("A newer version of this app is required to continue. Please update from the App Store.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

#if DEBUG
/// QA-only (env `QA_TRAFFIC=<seconds>`): keeps the screen awake and fetches a rotating list of
/// HTTPS hosts every N seconds through the system network path — i.e. through the VPN whenever
/// it is up — logging each result under `[qa]`. Lets a tunnel soak run with no Safari/screen
/// interaction (a locked phone can't launch or foreground anything).
enum QATraffic {
    static func startIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["QA_TRAFFIC"], let interval = Double(raw), interval > 0 else { return }
        let hosts = ["www.iana.org", "www.wikipedia.org", "www.python.org", "www.gnu.org", "www.kernel.org", "www.debian.org",
                     "www.openbsd.org", "www.ietf.org", "www.w3.org", "example.com", "example.org", "example.net"]
        UIApplication.shared.isIdleTimerDisabled = true
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        var index = 0
        DebugLog.important("qa", "QA_TRAFFIC every \(interval)s over \(hosts.count) hosts, screen kept awake")
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            let host = hosts[index % hosts.count]
            index += 1
            let n = index
            let started = Date()
            session.dataTask(with: URL(string: "https://\(host)/")!) { data, response, error in
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let http = response as? HTTPURLResponse {
                    DebugLog.important("qa", "traffic #\(n) https://\(host)/ -> \(http.statusCode) bytes=\(data?.count ?? 0) \(ms)ms")
                } else {
                    DebugLog.important("qa", "traffic #\(n) https://\(host)/ FAILED \(error?.localizedDescription ?? "?") \(ms)ms")
                }
            }.resume()
        }
    }
}
#endif
