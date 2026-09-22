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
    @AppStorage(EgressInterface.defaultsKey) private var egressInterface = EgressInterface.automatic.rawValue
    @AppStorage(EgressInterface.bindVPNKey) private var bindVPN = false
    @AppStorage(AntiDPI.enabledKey) private var antiDPIEnabled = false
    @AppStorage(AntiDPITuning.defaultsKey) private var antiDPITuning = AntiDPITuning.light.rawValue
    @State private var vpnInterfaceName: String? = VPNProbe.activeName()
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
                egressSection
                vpnSection
                antiDpiSection
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
        .onChange(of: bindVPN) { on in server.egressPathChanged(on ? "Bind to VPN on" : "Bind to VPN off") }
        .onChange(of: egressInterface) { value in server.egressPathChanged("outbound interface -> \(value)") }
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
        vpnInterfaceName = VPNProbe.activeName()
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

    private var egressSection: some View {
        Section {
            Picker("Outbound interface", selection: $egressInterface) {
                ForEach(EgressInterface.pickerCases) { option in Text(option.label).tag(option.rawValue) }
            }
            .disabled(bindVPN)
        } header: {
            Text("Outbound Network")
        } footer: {
            Text("Which network the proxy uses to reach the internet. Automatic lets iOS decide. Choosing a specific type never falls back: if that network is unavailable, connections fail after a few seconds. Changing it closes open connections so clients reconnect on the new network. With custom DNS (DoH) on, the DNS lookup itself may still use another network, and UDP hostnames are resolved by system DNS.")
        }
    }

    private var vpnSection: some View {
        Section {
            Toggle("Bind to VPN", isOn: $bindVPN)
            InfoRow(label: "VPN interface", value: vpnInterfaceName ?? "None detected")
        } header: {
            Text("VPN")
        } footer: {
            Text("Sends the proxy's outbound traffic through the phone's active VPN tunnel instead of Wi-Fi or cellular, and overrides the choice above. Turn your VPN on first; if none is up, connections are refused rather than leaving unprotected. TCP and UDP both go through the tunnel. Open connections are closed when this changes or the VPN connects or drops, so nothing keeps running outside it. While this is on, custom DNS (DoH) is skipped and hostnames — TCP and UDP — are resolved inside the tunnel instead, so nothing is looked up outside it.")
        }
    }

    private var antiDpiSection: some View {
        Section {
            Toggle("Anti-DPI", isOn: $antiDPIEnabled)
            Picker("Tuning", selection: $antiDPITuning) {
                ForEach(AntiDPITuning.allCases) { option in Text(option.label).tag(option.rawValue) }
            }
            .disabled(!antiDPIEnabled)
        } header: {
            Text("Evasion")
        } footer: {
            Text("Splits and paces outbound traffic to resist deep packet inspection and pattern-based throttling. Light keeps most of your speed; Aggressive disrupts patterns harder at a real throughput cost. Neither can hide total data used.")
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
