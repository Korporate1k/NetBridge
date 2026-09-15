import SwiftUI
import Combine
import CoreLocation
import UniformTypeIdentifiers

struct DashboardView: View {
    @StateObject private var server = ProxyServer()
    @StateObject private var keeper = BackgroundKeeper()
    @State private var selectedTab = 0
    @State private var markCount = 0
    @State private var lastMark: String?

    private static var wroteSessionHeader = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTabView(server: server, keeper: keeper, selectedTab: $selectedTab)
                .tabItem { Label("Dashboard", systemImage: "bolt.horizontal.circle") }
                .tag(0)

            DevicesView(registry: server.devices)
                .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                .tag(1)

            ConnectionHistoryListView(history: server.history)
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
                .tag(2)

            SettingsView(server: server, keeper: keeper, markCount: $markCount, lastMark: $lastMark)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)

            HowToGuideView(server: server)
                .tabItem { Label("How To", systemImage: "questionmark.circle") }
                .tag(4)
        }
        .onAppear {
            if !Self.wroteSessionHeader {
                Self.wroteSessionHeader = true
                DebugLog.writeSessionHeader(port: server.port,
                                            locationStatus: BackgroundKeeper.describe(keeper.authorizationStatus),
                                            keepAlive: keeper.isKeepingAlive)
            }
        }
    }
}

// MARK: - Dashboard tab

private struct HomeTabView: View {
    @ObservedObject var server: ProxyServer
    @ObservedObject var keeper: BackgroundKeeper
    @Binding var selectedTab: Int

    @State private var showQRCode = false
    @State private var copied = false
    @State private var rateUp: Double = 0
    @State private var rateDown: Double = 0
    @State private var lastSample: (up: UInt64, down: UInt64, at: Date)?

    private let rateTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var address: String { "\(server.localIP ?? "detecting…"):\(server.port)" }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    statsGrid
                    UsageGraphView(samples: server.usageHistory.samples)
                    helpCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("LocalProxy")
        }
        .onReceive(rateTimer) { _ in sampleRates() }
        .sheet(isPresented: $showQRCode) {
            QRCodeSheet(address: address)
        }
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
                        Image(systemName: "network")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Choose network interface")
                }
                Button { showQRCode = true } label: {
                    Image(systemName: "qrcode")
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Show QR code")
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

    // MARK: Stats

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatTile(title: "Download", value: formatRate(rateDown), systemImage: "arrow.down.circle.fill", tint: .blue)
                StatTile(title: "Upload", value: formatRate(rateUp), systemImage: "arrow.up.circle.fill", tint: .indigo)
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

    // MARK: Help

    private var helpCard: some View {
        Button {
            selectedTab = 4
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

    private func sampleRates() {
        let now = Date()
        let up = server.bytesUp
        let down = server.bytesDown
        if server.isRunning, let last = lastSample {
            let elapsed = now.timeIntervalSince(last.at)
            if elapsed > 0 {
                rateUp = up >= last.up ? Double(up - last.up) / elapsed : 0
                rateDown = down >= last.down ? Double(down - last.down) / elapsed : 0
            }
        } else {
            rateUp = 0
            rateDown = 0
        }
        lastSample = (up, down, now)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var server: ProxyServer
    @ObservedObject var keeper: BackgroundKeeper
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

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Form {
                proxySection
                listenersSection
                dohSection
                toolsSection
                diagnosticsSection
            }
            .navigationTitle("Settings")
        }
        .onAppear(perform: refreshDiagnostics)
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

    private var proxySection: some View {
        Section {
            Stepper("Port \(server.port)", value: $server.port, in: 1024...65535)
                .monospacedDigit()
                .disabled(server.isRunning)

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

            Toggle("Auto-restart if a listener drops", isOn: $server.autoRestartEnabled)

            NavigationLink("Profiles", destination: ProfilesView(server: server, keeper: keeper))
        } header: {
            Text("Proxy")
        } footer: {
            Text("The port can only be changed while stopped. Keep-alive uses \"Always\" location to help the proxy survive in the background — keeping the app open is the reliable mode.")
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
            NavigationLink("SOCKS5 Client Test", destination: Socks5ClientTestView(
                proxyHost: LocalAddress.primaryIPv4() ?? "127.0.0.1",
                proxyPort: String(server.port)
            ))
        } header: {
            Text("Tools")
        } footer: {
            Text("Dial another SOCKS5 server — this device's own, or a second device running LocalProxy — to exercise CONNECT and UDP ASSOCIATE without a laptop.")
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

private struct ConnectionHistoryListView: View {
    @ObservedObject var history: ConnectionHistory

    var body: some View {
        NavigationView {
            List {
                if history.entries.isEmpty {
                    Text("No connections closed yet this session.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.target)
                                .font(.body.weight(.semibold))
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
            .navigationTitle("Recent Connections")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { history.clear() }
                        .disabled(history.entries.isEmpty)
                }
            }
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
