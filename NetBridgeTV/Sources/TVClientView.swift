import SwiftUI
import NetworkExtension

/// The whole tvOS app: one focus-driven screen with the server link, a Connect/Disconnect button and the live
/// tunnel state, including whether the server relays UDP.
struct TVClientView: View {
    @EnvironmentObject private var model: TVClientModel

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            Text("NetBridge")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                Text("Server")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                TextField("socks5://user:pass@host:port", text: $model.linkText)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                Text("The saved password is never shown. Keep user@ to keep it; remove user@ to connect without a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: model.connectOrDisconnect) {
                Text(model.isConnectedOrConnecting ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canConnect)

            statusSection

            Spacer()
        }
        .padding(80)
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("Status", statusText)
            if model.tunnel.status == .connected || model.tunnel.status == .reasserting {
                row("Server", healthText)
                row("UDP", udpText)
                row("Sent", Self.bytes(model.stats.up))
                row("Received", Self.bytes(model.stats.down))
            }
            if let message = model.message ?? model.tunnel.lastError {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.title3)
    }

    private var statusText: String {
        switch model.tunnel.status {
        case .invalid: return "Not set up"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }

    private var healthText: String {
        switch model.proxyHealth {
        case .notConnected: return "—"
        case .checking: return "Checking…"
        case .healthy: return "Answering"
        case .authRejected: return "Sign-in refused"
        case .unreachable: return "Not answering"
        }
    }

    private var udpText: String {
        if case .healthy(let udp) = model.proxyHealth {
            switch udp {
            case .some(true): return "Relayed"
            case .some(false): return "Refused by server"
            case .none: return "Unknown"
            }
        }
        return "—"
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
}
