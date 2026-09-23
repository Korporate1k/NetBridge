import SwiftUI
import Combine
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var server: ProxyServer
    @ObservedObject var keeper: BackgroundKeeper
    @ObservedObject var purchases: PurchaseManager
    @ObservedObject var trial: TrialManager
    @ObservedObject var remoteConfig: RemoteConfigManager
    @Binding var markCount: Int
    @Binding var lastMark: String?

    // Read here only to show each subpage's current value on its row and to react to
    // egress changes; the controls themselves live on the subpages below.
    @AppStorage("doh.enabled") private var dohEnabled = false
    @AppStorage(EgressInterface.defaultsKey) private var egressInterface = EgressInterface.automatic.rawValue
    @AppStorage(EgressInterface.bindVPNKey) private var bindVPN = false
    @AppStorage(AntiDPI.enabledKey) private var antiDPIEnabled = false
    @AppStorage(AntiDPITuning.defaultsKey) private var antiDPITuning = AntiDPITuning.light.rawValue
    #if DEBUG
    // QA automation hook, same rationale/pattern as QA_TAB/QA_AUTOSTART in
    // DashboardView.init/onAppear: no Mac Accessibility permission available
    // to tap into a NavigationLink, so an env var drives an `isActive`
    // binding to push straight into the Upload Throughput Test screen.
    // DEBUG-only, compiled out of Release/IPA builds entirely.
    @State private var qaPushUploadTest = false
    #endif

    @State private var showUpgrade = false
    @State private var vpnInterfaceName: String? = VPNProbe.activeName()

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                if remoteConfig.paywallEnabled {
                    proSection
                }
                proxySection
                networkSection
                advancedSection
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
            UpgradeView(purchases: purchases, trial: trial,
                        usedTodayBytes: server.dailyUsage.bytesUsedToday,
                        dailyLimitBytes: server.dailyUsage.dailyLimitBytes)
        }
        .onChange(of: bindVPN) { _, on in server.egressPathChanged(on ? "Bind to VPN on" : "Bind to VPN off") }
        .onChange(of: egressInterface) { _, value in server.egressPathChanged("outbound interface -> \(value)") }
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
    }

    private var proSection: some View {
        Section {
            // One row; plans, Restore and Manage Subscription all live on the paywall it opens.
            Button { showUpgrade = true } label: {
                HStack {
                    Label("NetBridge Pro", systemImage: purchases.isPro ? "checkmark.seal.fill" : "bolt.circle")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(proValue)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .onAppear { trial.refresh() }
    }

    private var proValue: String {
        switch purchases.proSource {
        case .lifetime:
            return "Lifetime"
        case .subscription:
            guard let expires = purchases.subscriptionExpires else { return "Monthly" }
            let date = expires.formatted(.dateTime.month(.abbreviated).day())
            return "Monthly · \(purchases.willAutoRenew == false ? "ends" : "renews") \(date)"
        case nil:
            if trial.isInTrial { return "Trial · \(trial.remainingDescription) left" }
            return "Free · \(DailyUsageTracker.formatDecimalGB(server.dailyUsage.bytesUsedToday)) of \(DailyUsageTracker.formatDecimalGB(server.dailyUsage.dailyLimitBytes)) today"
        }
    }

    private var proxySection: some View {
        Section {
            Stepper("Port \(String(server.port))", value: $server.port, in: 1024...65535)
                .monospacedDigit()
                .disabled(server.isRunning)

            Toggle("Auto-restart if a listener drops", isOn: $server.autoRestartEnabled)

            if remoteConfig.backgroundKeepAliveEnabled {
                switch keeper.authorizationStatus {
                case .authorizedAlways:
                    Toggle("Background keep-alive", isOn: Binding(
                        get: { keeper.isKeepingAlive },
                        set: { enabled in enabled ? keeper.start() : keeper.stop() }
                    ))
                case .denied, .restricted:
                    Text("Location access is off. Enable it in Settings → NetBridge → Location → Always to use background keep-alive.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                default:
                    Button("Enable background keep-alive") { keeper.requestAlways() }
                }
            }

            ValueLink("Authentication", value: authValue) {
                AuthenticationSettingsView(server: server)
            }

            if remoteConfig.showProfiles {
                NavigationLink("Profiles", destination: ProfilesView(server: server, keeper: keeper))
            }
        } header: {
            Text("Proxy")
        } footer: {
            Text("The port can only be changed while stopped.")
        }
    }

    private var networkSection: some View {
        Section {
            ValueLink("Outbound", value: outboundValue) {
                OutboundSettingsView()
            }
            ValueLink("DNS", value: dohEnabled ? "DoH" : "System") {
                DNSSettingsView()
            }
            ValueLink("DPI Settings", value: antiDPIValue) {
                AntiDPISettingsView()
            }
            Toggle("Bind to VPN", isOn: $bindVPN)
            if bindVPN {
                InfoRow(label: "VPN interface", value: vpnInterfaceName ?? "None detected")
            }
        } header: {
            Text("Network")
        } footer: {
            Text("Bind to VPN sends the proxy's outbound traffic through the phone's active VPN tunnel instead of Wi-Fi or cellular, and overrides the Outbound choice. Turn your VPN on first; if none is up, connections are refused rather than leaving unprotected. TCP and UDP both go through the tunnel. Open connections are closed when this changes or the VPN connects or drops, so nothing keeps running outside it. While this is on, custom DNS (DoH) is skipped and hostnames are resolved inside the tunnel instead, so nothing is looked up outside it.")
        }
        .onAppear { vpnInterfaceName = VPNProbe.activeName() }
        .onReceive(refreshTimer) { _ in vpnInterfaceName = VPNProbe.activeName() }
    }

    private var advancedSection: some View {
        Section {
            if remoteConfig.showAdditionalListeners {
                ValueLink("Additional Listeners",
                          value: server.additionalListeners.isEmpty ? "None" : "\(server.additionalListeners.count)") {
                    ListenersSettingsView(server: server)
                }
            }
            if remoteConfig.showUploadTest {
                NavigationLink("Upload Throughput Test", destination: UploadThroughputTestView())
            }
            NavigationLink("Diagnostics & Logs") {
                DiagnosticsSettingsView(server: server, markCount: $markCount, lastMark: $lastMark)
            }
        } header: {
            Text("Advanced")
        }
    }

    private var authValue: String {
        server.requiredUsername.isEmpty && server.requiredPassword.isEmpty ? "Off" : "On"
    }

    private var outboundValue: String {
        if bindVPN { return EgressInterface.vpn.label }
        return EgressInterface(rawValue: egressInterface)?.label ?? EgressInterface.automatic.label
    }

    private var antiDPIValue: String {
        guard antiDPIEnabled else { return "Off" }
        return AntiDPITuning(rawValue: antiDPITuning)?.label ?? AntiDPITuning.light.label
    }
}

/// A navigation row that shows the destination's current setting on the trailing side.
private struct ValueLink<Destination: View>: View {
    let title: String
    let value: String
    let destination: () -> Destination

    init(_ title: String, value: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.value = value
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Subpages

private struct AuthenticationSettingsView: View {
    @ObservedObject var server: ProxyServer

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $server.requiredUsername)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                SecureField("Password", text: $server.requiredPassword)
            } footer: {
                Text("Leave both blank for open access. Fill in both to require SOCKS5 clients to sign in.")
            }
        }
        .navigationTitle("Authentication")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
    }
}

private struct OutboundSettingsView: View {
    @AppStorage(EgressInterface.defaultsKey) private var egressInterface = EgressInterface.automatic.rawValue
    @AppStorage(EgressInterface.bindVPNKey) private var bindVPN = false

    var body: some View {
        Form {
            Section {
                Picker("Outbound interface", selection: $egressInterface) {
                    ForEach(EgressInterface.pickerCases) { option in Text(option.label).tag(option.rawValue) }
                }
                .disabled(bindVPN)
            } footer: {
                Text(bindVPN
                     ? "Bind to VPN is on, so traffic goes through the VPN tunnel. Turn it off on the Settings page to choose a network here."
                     : "Automatic lets iOS decide. A specific network never falls back: if it's unavailable, connections fail. Changing this closes open connections.")
            }
        }
        .navigationTitle("Outbound")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DNSSettingsView: View {
    @AppStorage("doh.enabled") private var dohEnabled = false
    @AppStorage("doh.upstreamURL") private var dohUpstreamURL = "https://cloudflare-dns.com/dns-query"

    var body: some View {
        Form {
            Section {
                Toggle("Custom DNS (DoH)", isOn: $dohEnabled)
                if dohEnabled {
                    TextField("DoH upstream URL", text: $dohUpstreamURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            } footer: {
                Text("Resolves hostnames over DNS-over-HTTPS instead of the system resolver. Skipped while Bind to VPN is on.")
            }
        }
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
    }
}

private struct AntiDPISettingsView: View {
    @AppStorage(AntiDPI.enabledKey) private var antiDPIEnabled = false
    @AppStorage(AntiDPITuning.defaultsKey) private var antiDPITuning = AntiDPITuning.light.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("DPI Settings", isOn: $antiDPIEnabled)
                Picker("Tuning", selection: $antiDPITuning) {
                    ForEach(AntiDPITuning.allCases) { option in Text(option.label).tag(option.rawValue) }
                }
                .disabled(!antiDPIEnabled)
            } footer: {
                Text("Sends outgoing data in smaller, evenly spaced pieces. Light keeps most of your speed; Aggressive lowers throughput further.")
            }
        }
        .navigationTitle("DPI Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ListenersSettingsView: View {
    @ObservedObject var server: ProxyServer
    @State private var newListenerPort = ""
    @State private var newListenerMode: ListenerMode = .httpOnly

    var body: some View {
        Form {
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
            } footer: {
                Text("Extra ports beyond the primary one, e.g. one for HTTP-only clients and one for SOCKS5-only. Can only be changed while stopped.")
            }
        }
        .navigationTitle("Additional Listeners")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
    }
}

private struct DiagnosticsSettingsView: View {
    @ObservedObject var server: ProxyServer
    @Binding var markCount: Int
    @Binding var lastMark: String?

    @State private var verbose = DebugLog.shared.verbose
    @State private var traceData = DebugLog.shared.trace
    @State private var logSize: UInt64 = 0
    @State private var mirrorStatus = LogMirror.shared.status
    @State private var showShare = false
    @State private var showFolderPicker = false
    @State private var confirmClear = false

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
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
            } header: {
                Text("Logging")
            } footer: {
                Text("Add a mark the moment something goes wrong so it's easy to find in the log.")
            }

            Section {
                InfoRow(label: "Log size", value: ByteCountFormatter.string(fromByteCount: Int64(logSize), countStyle: .file))
                Button("Share logs…") { showShare = true }

                Button("Copy logs to iCloud Drive folder…") { showFolderPicker = true }
                InfoRow(label: "iCloud copy", value: mirrorStatus)
                if mirrorStatus != "Not set" {
                    Button("Stop copying to folder", role: .destructive) {
                        LogMirror.shared.clearFolder()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() }
                    }
                }

                Button("Clear log", role: .destructive) { confirmClear = true }
                    .alert("Clear the current log?", isPresented: $confirmClear) {
                        Button("Clear", role: .destructive) {
                            DebugLog.clear()
                            refresh()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            } header: {
                Text("Log File")
            } footer: {
                Text("Logs are also in Files → On My iPhone → NetBridge.")
            }
        }
        .navigationTitle("Diagnostics & Logs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
        .sheet(isPresented: $showShare) {
            ActivityView(items: DebugLog.fileURLs)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                LogMirror.shared.setFolder(url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
            }
        }
    }

    private func refresh() {
        logSize = DebugLog.logSizeBytes
        mirrorStatus = LogMirror.shared.status
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
