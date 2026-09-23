import SwiftUI
import Charts

/// Connection status and live traffic for the Mac client: state, server, uptime,
/// totals and a 60-second throughput chart fed by the tunnel extension's counters.
struct MacDashboardView: View {
    @EnvironmentObject private var model: MacClientModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if case .unreachable = model.proxyHealth { unreachableBanner }
                statGrid
                chartCard
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                StatusBadge(status: model.tunnel.status)
                    .font(.title2.weight(.semibold))
                Text(serverLine)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(model.isConnectedOrConnecting ? "Disconnect" : "Connect") {
                model.connectOrDisconnect()
            }
            .disabled(!model.canConnect)
        }
    }

    private var serverLine: String {
        model.config.host.isEmpty ? "No server configured — set one in Client" : "\(model.config.host):\(model.config.port)"
    }

    /// The case the status badge cannot express: the tunnel is up, so everything looks fine, but the proxy is not
    /// answering and nothing is getting through. Without this the only symptom is that the internet "stopped".
    private var unreachableBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connected, but the proxy isn't answering")
                    .font(.headline)
                Text("\(model.config.host):\(model.config.port) stopped responding\(lastCheckedText). Traffic through the tunnel is going nowhere — check that the server is running and reachable from this network.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "just now" / "12s ago", or nil when no probe has reported yet.
    private var lastCheckedAgo: String? {
        guard model.stats.lastProbe > 0 else { return nil }
        let age = Int(Date().timeIntervalSince1970 - model.stats.lastProbe)
        return age <= 1 ? "just now" : "\(age)s ago"
    }

    private var lastCheckedText: String {
        guard let ago = lastCheckedAgo else { return "" }
        return ago == "just now" ? " (just checked)" : " (checked \(ago))"
    }

    private var statGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                StatTile(title: "Proxy", value: proxyText, detail: proxyDetail)
                StatTile(title: "Connected for", value: uptimeText)
            }
            GridRow {
                StatTile(title: "Extension memory", value: memoryText)
                StatTile(title: "Server", value: model.config.host.isEmpty ? "—" : model.config.host,
                         detail: model.config.host.isEmpty ? nil : "port \(model.config.port)")
            }
            GridRow {
                StatTile(title: "Downloaded", value: Self.bytes(model.stats.down),
                         detail: "\(model.stats.pktDown) packets")
                StatTile(title: "Uploaded", value: Self.bytes(model.stats.up),
                         detail: "\(model.stats.pktUp) packets")
            }
        }
    }

    private var proxyText: String {
        switch model.proxyHealth {
        case .notConnected: return "—"
        case .checking: return "Checking…"
        case .healthy: return "Answering"
        case .unreachable: return "Not answering"
        }
    }

    private var proxyDetail: String? {
        switch model.proxyHealth {
        case .notConnected: return nil
        case .checking: return "first check within a few seconds"
        case .healthy, .unreachable: return lastCheckedAgo.map { "last checked \($0)" }
        }
    }

    /// Recomputed on every render; `model.stats` republishes once a second while
    /// connected, which is what keeps this ticking.
    private var uptimeText: String {
        guard model.tunnel.status == .connected, let since = model.connectedSince else { return "—" }
        return Self.duration(Date().timeIntervalSince(since))
    }

    private var memoryText: String {
        model.stats.footprintMB > 0 ? String(format: "%.1f MB", model.stats.footprintMB) : "—"
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Throughput (last 60 s)").font(.headline)
                Spacer()
                if let last = model.samples.last {
                    Text("↓ \(Self.rate(last.down))   ↑ \(Self.rate(last.up))")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            if model.samples.isEmpty {
                Text(model.tunnel.status == .connected ? "Collecting samples…" : "Connect to see live traffic.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    ForEach(model.samples) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("Rate", sample.down),
                                 series: .value("Direction", "Down"))
                            .foregroundStyle(by: .value("Direction", "Down"))
                        LineMark(x: .value("Time", sample.date), y: .value("Rate", sample.up),
                                 series: .value("Direction", "Up"))
                            .foregroundStyle(by: .value("Direction", "Up"))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let rate = value.as(Double.self) { Text(Self.rate(rate)) }
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Formatting

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
