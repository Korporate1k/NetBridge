import SwiftUI
import NetworkExtension

/// The "Client" tab: the mirror image of everything else in this app. Every
/// other tab configures LocalProxy as a *server* other devices dial into;
/// this one configures LocalProxy as a *client* of someone else's SOCKS5
/// server, routing this device's own system-wide traffic out through it via
/// the `LocalProxyTunnel` Network Extension (see `ClientTunnelManager`).
///
/// Also hosts the SOCKS5 diagnostic tester (`Socks5ClientTestView`), moved
/// here from Settings' old `toolsSection` — it now defaults to checking
/// *this* configured remote server instead of the local listener, which is
/// the more useful pairing now that both live in the same tab.
struct ClientTabView: View {
    /// This device's own proxy server — the "Show QR Code" button shares its
    /// `ip:port` (same as the Dashboard's), not the remote config below.
    @ObservedObject var server: ProxyServer
    @ObservedObject var tunnelManager: ClientTunnelManager
    @State var config: ClientConfiguration
    /// Mirrors `RemoteConfigManager.showSocks5Tester` — the same gist-driven
    /// kill switch that used to gate this tool in Settings' `toolsSection`
    /// still applies now that it lives here.
    let showTester: Bool

    @State private var portText: String
    @State private var showingQRCode = false
    @State private var showingScanner = false

    init(server: ProxyServer, config: ClientConfiguration, tunnelManager: ClientTunnelManager, showTester: Bool) {
        self.server = server
        self._config = State(initialValue: config)
        self._portText = State(initialValue: String(config.port))
        self.tunnelManager = tunnelManager
        self.showTester = showTester
    }

    var body: some View {
        NavigationView {
            Form {
                serverSection
                connectSection
                pairingSection
                if showTester {
                    testSection
                }
            }
            .navigationTitle("Client")
            .keyboardDoneButton()
            .onAppear {
                tunnelManager.loadOrCreate { _ in }
                #if DEBUG
                // QA_CLIENT_URI/QA_CLIENT_AUTOCONNECT now drive
                // ClientTunnelManager directly from DashboardView.init() (see
                // there), independent of whether this tab is ever shown — but
                // still mirror a parsed QA_CLIENT_URI into this view's own
                // @State so the text fields visually reflect it if a QA pass
                // does land on this tab.
                if let uri = ProcessInfo.processInfo.environment["QA_CLIENT_URI"],
                   let parsed = ClientConfiguration(uriString: uri) {
                    config = parsed
                    portText = String(parsed.port)
                }
                #endif
            }
        }
        .sheet(isPresented: $showingQRCode) {
            QRCodeSheet(server: server)
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerSheet { scanned in
                config = scanned
                portText = String(scanned.port)
                showingScanner = false
            }
        }
    }

    private var serverSection: some View {
        Section {
            TextField("Host", text: $config.host)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            TextField("Port", text: $portText)
                .keyboardType(.numberPad)
                .onChange(of: portText) { _, newValue in
                    if let port = UInt16(newValue) { config.port = port }
                }
            TextField("Username (optional)", text: $config.username)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            SecureField("Password (optional)", text: $config.password)
        } header: {
            Text("Remote SOCKS5 Server")
        } footer: {
            Text("The server this device's traffic will route through when connected — someone else's LocalProxy, or any standard SOCKS5 server.")
        }
    }

    private var connectSection: some View {
        Section {
            Button {
                connectOrDisconnect()
            } label: {
                HStack {
                    Text(isConnectedOrConnecting ? "Disconnect" : "Connect")
                    Spacer()
                    if tunnelManager.status == .connecting || tunnelManager.status == .disconnecting {
                        ProgressView()
                    }
                }
            }
            .disabled(!isConnectedOrConnecting && config.host.isEmpty)

            if let error = tunnelManager.lastError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.footnote)
            }
        } header: {
            Text("Connection")
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                showingQRCode = true
            } label: {
                Label("Show QR Code", systemImage: "qrcode")
            }
            Button {
                showingScanner = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text("Show QR Code shares this device's own proxy server (ip:port) so another device can scan it and connect here. Scan QR Code fills in the server above from another device's code.")
        }
    }

    private var testSection: some View {
        Section {
            NavigationLink("Test This Connection", destination: Socks5ClientTestView(
                proxyHost: config.host,
                proxyPort: portText
            ))
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Exercise CONNECT and UDP ASSOCIATE against the configured server above before relying on it.")
        }
    }

    private var isConnectedOrConnecting: Bool {
        switch tunnelManager.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    private func connectOrDisconnect() {
        if isConnectedOrConnecting {
            tunnelManager.stop()
        } else {
            tunnelManager.save(config) { result in
                if case .success = result {
                    tunnelManager.start()
                }
            }
        }
    }
}
