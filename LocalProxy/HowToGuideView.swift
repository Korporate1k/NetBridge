import SwiftUI

/// A permanent, in-app guide covering how to point another device at
/// LocalProxy. Each section is plain OS-level proxy-configuration steps —
/// where to find the address/port field on that platform — with no claims
/// about hiding traffic from a carrier or ISP.
struct HowToGuideView: View {
    @ObservedObject var server: ProxyServer

    private var address: String { "\(server.localIP ?? "detecting…"):\(server.port)" }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                    overviewCard
                    deviceCard(title: "Windows PC", systemImage: "pc",
                               steps: [
                                "Open Settings → Network & Internet → Proxy.",
                                "Under Manual proxy setup, turn on \"Use a proxy server.\"",
                                "Address: \(server.localIP ?? "this device's address")   Port: \(server.port)",
                                "Save."
                               ])
                    deviceCard(title: "Mac", systemImage: "laptopcomputer",
                               steps: [
                                "Open System Settings → Network → Wi-Fi → Details… → Proxies.",
                                "Enable Web Proxy (HTTP) and/or SOCKS Proxy.",
                                "Server: \(server.localIP ?? "this device's address")   Port: \(server.port)",
                                "Click OK, then Apply."
                               ])
                    deviceCard(title: "PlayStation", systemImage: "gamecontroller",
                               steps: [
                                "Settings → Network → Set Up Internet Connection, select your connection.",
                                "Choose Custom → Advanced Settings.",
                                "Proxy Server: Use.",
                                "Address: \(server.localIP ?? "this device's address")   Port: \(server.port)"
                               ])
                    deviceCard(title: "iPhone & iPad", systemImage: "ipad.and.iphone",
                               steps: [
                                "Install NetBridge on the other iPhone or iPad and join the same Wi-Fi or this phone's Personal Hotspot.",
                                "On this phone, open the Client tab → Show QR Code.",
                                "On the other device, open the Client tab → Scan QR Code and point it at the code.",
                                "It connects automatically. Allow the VPN configuration the first time iOS asks."
                               ],
                               footnote: "All of that device's apps and traffic (TCP and UDP) go through this phone. Tap Disconnect on its Client tab to stop.")
                } .padding(16)
            }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("How To")
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What LocalProxy does", systemImage: "network")
                .font(.headline)
            Text("NetBridge runs a local HTTP CONNECT and SOCKS5 (TCP + UDP) proxy on this device. Point another device's proxy setting at the address and port below, and its traffic routes through this phone — useful for testing, debugging, content filtering, or general local-network relaying.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack {
                Text(address)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Spacer()
                if !server.isRunning {
                    Text("Start the proxy on the Dashboard tab first")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func deviceCard(title: String, systemImage: String, steps: [String], footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.accentColor))
                    Text(step)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let footnote = footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
