import SwiftUI
import Combine
import CoreLocation
import UniformTypeIdentifiers

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

                    DevicesView(registry: server.devices, history: server.history)
                        .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                        .tag(2)

                    SettingsView(server: server, keeper: keeper, purchases: purchases, trial: trial,
                                 remoteConfig: remoteConfig, markCount: $markCount, lastMark: $lastMark)
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(3)
                }
            }
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

// MARK: - Dashboard tab

private struct HomeTabView: View {
    @ObservedObject var server: ProxyServer
    @ObservedObject var keeper: BackgroundKeeper
    @ObservedObject var purchases: PurchaseManager
    @ObservedObject var trial: TrialManager
    @ObservedObject var remoteConfig: RemoteConfigManager

    @State private var showQRCode = false
    @State private var showUpgrade = false
    @State private var copied = false

    private var address: String { "\(server.localIP ?? "detecting…"):\(server.port)" }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if remoteConfig.announcementActive && !remoteConfig.announcementMessage.isEmpty {
                        announcementBanner
                    }
                    statusCard
                    usageBanner
                    statsGrid
                    allTimeUsageCard
                    UsageGraphView(samples: server.usageHistory.samples)
                    helpCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("NetBridge")
        }
        .onAppear { trial.refresh() }
        .sheet(isPresented: $showQRCode) {
            QRCodeSheet(server: server)
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeView(purchases: purchases, dailyLimitBytes: server.dailyUsage.dailyLimitBytes)
        }
    }

    // MARK: Announcement

    private var announcementBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "megaphone.fill")
                .foregroundColor(.accentColor)
            Text(remoteConfig.announcementMessage)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard()
    }

    // MARK: Free-tier usage

    private var usageBanner: some View {
        Group {
            if !remoteConfig.paywallEnabled {
                unlimitedBanner
            } else if purchases.isPro {
                EmptyView()
            } else if trial.isInTrial {
                trialBanner
            } else {
                capBanner
            }
        }
    }

    private var unlimitedBanner: some View {
        HStack {
            Label("Unlimited — no daily limit", systemImage: "infinity")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(16)
        .glassCard()
    }

    private var trialBanner: some View {
        HStack {
            Label("Free trial: \(trial.remainingDescription) left — no daily limit",
                  systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(16)
        .glassCard()
    }

    private var capBanner: some View {
        let used = server.dailyUsage.bytesUsedToday
        let limit = server.dailyUsage.dailyLimitBytes
        let overLimit = server.dailyUsage.isOverLimit
        return Button {
            showUpgrade = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(overLimit ? "Daily free limit reached" : "\(DailyUsageTracker.formatDecimalGB(used)) of \(DailyUsageTracker.formatDecimalGB(limit)) used today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(overLimit ? .red : .primary)
                    Spacer()
                    Text("Upgrade")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(overLimit ? Color.red : Color.accentColor)
                            .frame(width: max(4, geometry.size.width * CGFloat(min(Double(used) / Double(limit), 1))))
                    }
                }
                .frame(height: 6)
            }
            .padding(16)
            .glassCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(server.isRunning ? "Running" : "Stopped")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(server.isRunning ? .green : .secondary)
                Spacer()
                if server.isRunning {
                    Text("\(server.activeConnections) active")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                if server.availableAddresses.count > 1 {
                    Menu {
                        ForEach(server.availableAddresses) { entry in
                            Button("\(entry.name): \(entry.ip)") { server.selectAddress(entry.ip) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text(selectedInterfaceName)
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .accessibilityLabel("Choose network interface")
                }
                if remoteConfig.showQRCode {
                    Button { showQRCode = true } label: {
                        Image(systemName: "qrcode")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Show QR code")
                }
            }

            Button(action: copyAddress) {
                VStack(spacing: 6) {
                    Text(address)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundColor(.primary)
                    Label(addressHint, systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button(action: toggleProxy) {
                Text(server.isRunning ? "Stop" : "Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
            .tint(server.isRunning ? .red : .accentColor)

            if let error = server.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .glassCard()
        .animation(.easeInOut(duration: 0.2), value: server.isRunning)
    }

    private var addressHint: String {
        if copied { return "Copied" }
        return server.localIP == nil ? "No active network detected" : "Tap to copy"
    }

    private var selectedInterfaceName: String {
        server.availableAddresses.first(where: { $0.ip == server.localIP })?.name ?? "Network"
    }

    // MARK: Stats

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatTile(title: "Download", value: formatRate(server.rateDown), systemImage: "arrow.down.circle.fill", tint: .blue)
                StatTile(title: "Upload", value: formatRate(server.rateUp), systemImage: "arrow.up.circle.fill", tint: .indigo)
                StatTile(title: "Downloaded", value: formatBytes(server.bytesDown), systemImage: "tray.and.arrow.down.fill", tint: .teal)
                StatTile(title: "Uploaded", value: formatBytes(server.bytesUp), systemImage: "tray.and.arrow.up.fill", tint: .purple)
            }
            if server.isRunning {
                Text(server.lastActivity)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: All-time usage

    private var allTimeUsageCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("All-Time Usage")
                    .font(.headline)
                Text("\(formatBytes(server.dailyUsage.allTimeBytes)) relayed since install — can't be reset")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .glassCard()
    }

    // MARK: Help

    private var helpCard: some View {
        NavigationLink {
            HowToGuideView(server: server)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Need help connecting a device?")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Step-by-step setup for PC, Mac, PlayStation, and iOS/iPadOS")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(20)
            .glassCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func toggleProxy() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if server.isRunning {
            server.stop()
        } else {
            server.start()
        }
    }

    private func copyAddress() {
        UIPasteboard.general.string = address
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var server: ProxyServer
    @ObservedObject var keeper: BackgroundKeeper
    @ObservedObject var purchases: PurchaseManager
    @ObservedObject var trial: TrialManager
    @ObservedObject var remoteConfig: RemoteConfigManager
    @Binding var markCount: Int
    @Binding var lastMark: String?

    @State private var verbose = DebugLog.shared.verbose
    @State private var traceData = DebugLog.shared.trace
    @State private var logSize: UInt64 = 0
    @State private var mirrorStatus = LogMirror.shared.status
    @State private var showShare = false
    @State private var showFolderPicker = false
    @State private var confirmClear = false
    @State private var newListenerPort = ""
    @State private var newListenerMode: ListenerMode = .httpOnly
    @AppStorage("doh.enabled") private var dohEnabled = false
    @AppStorage("doh.upstreamURL") private var dohUpstreamURL = "https://cloudflare-dns.com/dns-query"
    #if DEBUG
    // QA automation hook, same rationale/pattern as QA_TAB/QA_AUTOSTART in
    // DashboardView.init/onAppear: no Mac Accessibility permission available
    // to tap into a NavigationLink, so an env var drives an `isActive`
    // binding to push straight into the Upload Throughput Test screen.
    // DEBUG-only, compiled out of Release/IPA builds entirely.
    @State private var qaPushUploadTest = false
    #endif

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    @State private var showUpgrade = false

    var body: some View {
        NavigationStack {
            Form {
                if remoteConfig.paywallEnabled {
                    proSection
                }
                proxySection
                if remoteConfig.showAdditionalListeners {
                    listenersSection
                }
                dohSection
                if remoteConfig.showUploadTest {
                    toolsSection
                }
                diagnosticsSection
            }
            .navigationTitle("Settings")
            .keyboardDoneButton()
            #if DEBUG
            .navigationDestination(isPresented: $qaPushUploadTest) {
                UploadThroughputTestView()
            }
            #endif
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeView(purchases: purchases, dailyLimitBytes: server.dailyUsage.dailyLimitBytes)
        }
        .onAppear(perform: refreshDiagnostics)
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["QA_PUSH_UPLOAD_TEST"] == "1" {
                // A synchronous push here races the navigation stack's setup on
                // first appearance and gets silently dropped — a small delay
                // avoids that (same rationale as QA_AUTOSTART's delay).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    qaPushUploadTest = true
                }
            }
        }
        #endif
        .onReceive(refreshTimer) { _ in refreshDiagnostics() }
        .sheet(isPresented: $showShare) {
            ActivityView(items: DebugLog.fileURLs)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                LogMirror.shared.setFolder(url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshDiagnostics() }
            }
        }
    }

    private func refreshDiagnostics() {
        logSize = DebugLog.logSizeBytes
        mirrorStatus = LogMirror.shared.status
    }

    private var proSection: some View {
        Section {
            if purchases.isPro {
                Label("NetBridge Pro — daily cap removed", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            } else {
                if trial.isInTrial {
                    Label("Free trial — \(trial.remainingDescription) left, no daily limit",
                          systemImage: "sparkles")
                        .foregroundColor(.accentColor)
                } else {
                    InfoRow(label: "Today's usage", value: "\(DailyUsageTracker.formatDecimalGB(server.dailyUsage.bytesUsedToday)) of \(DailyUsageTracker.formatDecimalGB(server.dailyUsage.dailyLimitBytes))")
                }
                Button("Upgrade to Pro…") { showUpgrade = true }
                Button("Restore Purchases") { Task { await purchases.restore() } }
            }
        } header: {
            Text("NetBridge Pro")
        }
        .onAppear { trial.refresh() }
    }

    private var proxySection: some View {
        Section {
            Stepper("Port \(server.port)", value: $server.port, in: 1024...65535)
                .monospacedDigit()
                .disabled(server.isRunning)

            if remoteConfig.backgroundKeepAliveEnabled {
                switch keeper.authorizationStatus {
                case .authorizedAlways:
                    Toggle("Background keep-alive", isOn: Binding(
                        get: { keeper.isKeepingAlive },
                        set: { enabled in enabled ? keeper.start() : keeper.stop() }
                    ))
                case .denied, .restricted:
                    Text("Location access is off. Enable it in Settings → LocalProxy → Location → Always to use background keep-alive.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                default:
                    Button("Enable background keep-alive") { keeper.requestAlways() }
                }
            }

            Toggle("Auto-restart if a listener drops", isOn: $server.autoRestartEnabled)

            TextField("Require username (optional)", text: $server.requiredUsername)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            SecureField("Require password (optional)", text: $server.requiredPassword)

            if remoteConfig.showProfiles {
                NavigationLink("Profiles", destination: ProfilesView(server: server, keeper: keeper))
            }
        } header: {
            Text("Proxy")
        } footer: {
            Text("The port can only be changed while stopped. Keep-alive uses \"Always\" location to help the proxy survive in the background — keeping the app open is the reliable mode. Leave username/password blank for open (no-auth) access; fill in both to require SOCKS5 clients to authenticate.")
        }
    }

    private var listenersSection: some View {
        Section {
            ForEach(server.additionalListeners) { config in
                HStack {
                    Text("Port \(config.port)")
                    Spacer()
                    Text(config.mode.label)
                        .foregroundColor(.secondary)
                    Button(role: .destructive) {
                        server.additionalListeners.removeAll { $0.id == config.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { indexSet in
                server.additionalListeners.remove(atOffsets: indexSet)
            }
            .disabled(server.isRunning)

            if !server.isRunning {
                HStack {
                    TextField("Port", text: $newListenerPort)
                        .keyboardType(.numberPad)
                    Picker("Mode", selection: $newListenerMode) {
                        ForEach(ListenerMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.menu)
                    Button("Add") {
                        guard let port = Int(newListenerPort), (1024...65535).contains(port) else { return }
                        server.additionalListeners.append(ListenerConfig(port: port, mode: newListenerMode))
                        newListenerPort = ""
                    }
                    .disabled(Int(newListenerPort).map { !(1024...65535).contains($0) } ?? true)
                }
            }
        } header: {
            Text("Additional Listeners")
        } footer: {
            Text("Extra ports beyond the primary one above — e.g. one dedicated to HTTP-only clients and one to SOCKS5-only clients. Can only be changed while stopped.")
        }
    }

    private var dohSection: some View {
        Section {
            Toggle("Custom DNS (DoH)", isOn: $dohEnabled)
            if dohEnabled {
                TextField("DoH upstream URL", text: $dohUpstreamURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        } header: {
            Text("DNS")
        } footer: {
            Text("When on, hostnames are resolved via DNS-over-HTTPS instead of the system resolver before dialing out.")
        }
    }

    private var toolsSection: some View {
        Section {
            NavigationLink("Upload Throughput Test", destination: UploadThroughputTestView())
        } header: {
            Text("Tools")
        } footer: {
            Text("Send bounded test data to a server you control to measure upload throughput. The SOCKS5 client tester moved to the new Client tab.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Toggle("Verbose logging", isOn: Binding(
                get: { verbose },
                set: { verbose = $0; DebugLog.shared.verbose = $0 }
            ))
            Toggle("Trace every data chunk", isOn: Binding(
                get: { traceData },
                set: { traceData = $0; DebugLog.shared.trace = $0 }
            ))

            Button("Add log mark") {
                markCount += 1
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                let time = formatter.string(from: Date())
                DebugLog.mark("#\(markCount) tapped at \(time) — activeTunnels=\(server.activeConnections) lastActivity=\(server.lastActivity)")
                lastMark = "#\(markCount) at \(time)"
            }
            if let lastMark = lastMark {
                InfoRow(label: "Last mark", value: lastMark)
            }

            InfoRow(label: "Log size", value: ByteCountFormatter.string(fromByteCount: Int64(logSize), countStyle: .file))
            Button("Share logs…") { showShare = true }

            Button("Copy logs to iCloud Drive folder…") { showFolderPicker = true }
            InfoRow(label: "iCloud copy", value: mirrorStatus)
            if mirrorStatus != "Not set" {
                Button("Stop copying to folder", role: .destructive) {
                    LogMirror.shared.clearFolder()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshDiagnostics() }
                }
            }

            Button("Clear log", role: .destructive) { confirmClear = true }
                .alert("Clear the current log?", isPresented: $confirmClear) {
                    Button("Clear", role: .destructive) {
                        DebugLog.clear()
                        refreshDiagnostics()
                    }
                    Button("Cancel", role: .cancel) {}
                }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Logs are also in Files → On My iPhone → LocalProxy. Add a mark the moment something goes wrong so it's easy to find in the log.")
        }
    }
}

// MARK: - Components

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundColor(tint)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }
}

struct ConnectionHistoryListView: View {
    @ObservedObject var history: ConnectionHistory
    @State private var searchText = ""
    /// nil = All modes, "" = "No location" (entries with no country match).
    @State private var modeFilter: String?
    @State private var countryFilter: String?

    /// Modes actually present in history right now, sorted — so the filter
    /// menu never offers a mode (e.g. a removed listener type) with nothing
    /// to show for it.
    private var availableModes: [String] {
        Array(Set(history.entries.map(\.mode))).sorted()
    }

    private var availableCountries: [(code: String, name: String)] {
        var seen: [String: String] = [:]
        for entry in history.entries {
            guard let code = entry.countryCode else { continue }
            seen[code] = entry.countryName ?? code
        }
        return seen.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    private var filteredEntries: [ConnectionSummary] {
        history.entries.filter { entry in
            if let modeFilter, entry.mode != modeFilter { return false }
            if let countryFilter, entry.countryCode != countryFilter { return false }
            guard !searchText.isEmpty else { return true }
            let haystack = [entry.target, entry.destinationIP, entry.sniffedHost, entry.countryName, entry.city]
                .compactMap { $0 }
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filtersActive: Bool { modeFilter != nil || countryFilter != nil }

    var body: some View {
        List {
            if history.entries.isEmpty {
                    Text("No connections closed yet this session.")
                        .foregroundColor(.secondary)
                } else if filteredEntries.isEmpty {
                    Text("No connections match the current filters.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.target)
                                .font(.body.weight(.semibold))
                            if let ip = entry.destinationIP, !entry.target.hasPrefix(ip) {
                                Text(ip)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let sniffed = entry.sniffedHost, !entry.target.hasPrefix(sniffed) {
                                Label(sniffed, systemImage: "eye")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let country = entry.countryName ?? entry.countryCode {
                                Text("\(flagEmoji(entry.countryCode)) \(country)\(entry.city.map { ", \($0)" } ?? "")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(entry.mode) · \(formatBytes(entry.bytesUp)) up / \(formatBytes(entry.bytesDown)) down · \(String(format: "%.1fs", entry.durationMs / 1000))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatLastSeen(entry.closedAt))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Host, IP, or location")
            .safeAreaInset(edge: .bottom) {
                if !history.entries.isEmpty {
                    Text("IP geolocation © DB-IP.com, CC BY 4.0")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Recent Connections")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Mode", selection: $modeFilter) {
                            Text("All modes").tag(String?.none)
                            ForEach(availableModes, id: \.self) { mode in
                                Text(mode).tag(String?.some(mode))
                            }
                        }
                        Picker("Location", selection: $countryFilter) {
                            Text("All locations").tag(String?.none)
                            ForEach(availableCountries, id: \.code) { entry in
                                Text("\(flagEmoji(entry.code)) \(entry.name)").tag(String?.some(entry.code))
                            }
                        }
                        if filtersActive {
                            Button("Clear Filters", role: .destructive) {
                                modeFilter = nil
                                countryFilter = nil
                            }
                        }
                    } label: {
                        Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .disabled(history.entries.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { history.clear() }
                        .disabled(history.entries.isEmpty)
                }
            }
    }

    /// Regional-indicator-symbol trick: offsetting each ASCII letter by
    /// `0x1F1E6 - 'A'` composes the two-letter code into a flag emoji.
    private func flagEmoji(_ countryCode: String?) -> String {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return "🌐" }
        var scalars = String.UnicodeScalarView()
        for c in code.unicodeScalars {
            guard let scalar = Unicode.Scalar(0x1F1E6 + (c.value - Unicode.Scalar("A").value)) else { return "🌐" }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

/// Share sheet (ShareLink needs iOS 16; the deployment target is iOS 15).
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Folder picker for choosing where logs are copied (e.g. a folder in iCloud Drive).
private struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
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
