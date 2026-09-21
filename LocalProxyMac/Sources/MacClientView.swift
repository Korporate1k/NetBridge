import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NetworkExtension

/// The Mac counterpart of the iOS "Client" tab (`ClientTabView`): the same
/// sections — remote SOCKS5 server, connect, pairing, diagnostics — with the
/// camera scanner replaced by paste / image import / drag-and-drop.
struct MacClientView: View {
    @EnvironmentObject private var model: MacClientModel
    @State private var showingQRCode = false

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                connectSection
                pairingSection
                testSection
            }
            .formStyle(.grouped)
            .navigationTitle("Client")
            .dropDestination(for: URL.self) { urls, _ in
                importQR(from: urls)
            }
        }
        .sheet(isPresented: $showingQRCode) {
            ConfigQRSheet(uri: model.config.uriString, hasPassword: !model.config.password.isEmpty)
        }
    }

    private var serverSection: some View {
        Section {
            TextField("Host", text: $model.config.host)
                .disableAutocorrection(true)
            TextField("Port", text: $model.portText)
                .onChange(of: model.portText) { _, newValue in
                    if let port = UInt16(newValue) { model.config.port = port }
                }
            TextField("Username (optional)", text: $model.config.username)
                .disableAutocorrection(true)
            SecureField("Password (optional)", text: $model.config.password)
        } header: {
            Text("Remote SOCKS5 Server")
        } footer: {
            Text("The server this Mac's traffic will route through when connected — someone else's LocalProxy, or any standard SOCKS5 server.")
        }
    }

    private var connectSection: some View {
        Section {
            Button {
                model.connectOrDisconnect()
            } label: {
                HStack {
                    Text(model.isConnectedOrConnecting ? "Disconnect" : "Connect")
                    Spacer()
                    if model.tunnel.status == .connecting || model.tunnel.status == .disconnecting {
                        ProgressView().controlSize(.small)
                    }
                    StatusBadge(status: model.tunnel.status)
                }
            }
            .disabled(!model.canConnect)
            .keyboardShortcut(.return, modifiers: .command)

            if let error = model.tunnel.lastError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.footnote)
            }

            // "Connected" alone cannot tell you the tunnel works: the status only reflects that the tunnel's
            // settings were installed, so a proxy that has stopped answering still shows green. Say so here too,
            // not only on the Dashboard.
            if case .unreachable = model.proxyHealth {
                Label("Connected, but the proxy isn't answering — traffic is going nowhere.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Connection")
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                if let text = NSPasteboard.general.string(forType: .string) {
                    model.apply(uri: text)
                } else {
                    model.pairingMessage = "The clipboard has no text."
                }
            } label: {
                Label("Paste socks5:// Address", systemImage: "doc.on.clipboard")
            }
            Button {
                chooseQRImage()
            } label: {
                Label("Import QR Code Image…", systemImage: "qrcode.viewfinder")
            }
            Button {
                showingQRCode = true
            } label: {
                Label("Show QR Code", systemImage: "qrcode")
            }
            .disabled(model.config.host.isEmpty)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.config.uriString, forType: .string)
                model.pairingMessage = "Copied \(model.config.host):\(model.config.port) to the clipboard."
            } label: {
                Label("Copy socks5:// Address", systemImage: "link")
            }
            .disabled(model.config.host.isEmpty)

            if let message = model.pairingMessage {
                Text(message).font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text("Fill in the server from another device's QR code: paste its address, import a screenshot of the code, or drop the image anywhere on this window. Show QR Code lets a phone scan this server instead.")
        }
    }

    private var testSection: some View {
        Section {
            NavigationLink("Test This Connection") {
                Socks5ClientTestView(proxyHost: model.config.host, proxyPort: model.portText)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Exercise CONNECT and UDP ASSOCIATE against the configured server above before relying on it.")
        }
    }

    // MARK: - QR import

    private func chooseQRImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image containing a QR code"
        if panel.runModal() == .OK { _ = importQR(from: panel.urls) }
    }

    @discardableResult
    private func importQR(from urls: [URL]) -> Bool {
        for url in urls {
            if let text = QRSupport.decode(imageAt: url) {
                return model.apply(uri: text)
            }
        }
        model.pairingMessage = "No QR code found in that image."
        return false
    }
}

/// Coloured dot + label for the tunnel state.
struct StatusBadge: View {
    let status: NEVPNStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundColor(.secondary)
        }
    }

    private var label: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Disconnected"
        case .invalid: return "Not configured"
        @unknown default: return "Unknown"
        }
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        default: return .gray
        }
    }
}

/// Shows the configured server as a `socks5://` QR so a phone can scan it.
private struct ConfigQRSheet: View {
    let uri: String
    let hasPassword: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan to Connect").font(.headline)
            if let image = QRSupport.image(for: uri) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Text("Couldn't generate a QR code.").foregroundColor(.secondary)
            }
            if hasPassword {
                Text("This code includes the server password — only show it to your own devices.")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 340)
    }
}
