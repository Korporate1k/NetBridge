import SwiftUI
import AppKit

/// The menu bar item's popover: tunnel state at a glance plus Connect/Disconnect, so the
/// VPN can be watched and driven without keeping the main window open.
struct MacMenuBarView: View {
    @EnvironmentObject private var model: MacClientModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusBadge(status: model.tunnel.status)
                    .font(.headline)
                Spacer()
                if model.tunnel.status == .connecting || model.tunnel.status == .disconnecting {
                    ProgressView().controlSize(.small)
                }
            }

            Text(model.config.host.isEmpty ? "No server configured" : "\(model.config.host):\(String(model.config.port))")
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)

            if model.tunnel.status == .connected, let last = model.samples.last {
                Text("↓ \(MacDashboardView.rate(last.down))   ↑ \(MacDashboardView.rate(last.up))")
                    .font(.system(.callout, design: .monospaced))
            }

            if case .unreachable = model.proxyHealth {
                Label("Connected, but the proxy isn't answering.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.connectOrDisconnect()
            } label: {
                Text(model.isConnectedOrConnecting ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isConnectedOrConnecting ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!model.canConnect)

            Divider()

            HStack {
                Button("Open NetBridge") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit NetBridge")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 280)
    }
}
