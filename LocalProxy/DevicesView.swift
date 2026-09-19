import SwiftUI

struct DevicesView: View {
    @ObservedObject var registry: DeviceRegistry
    @ObservedObject var history: ConnectionHistory
    @State private var confirmReset = false

    var body: some View {
        NavigationView {
            List {
                if registry.devices.isEmpty {
                    Section {
                        Text("No devices yet — devices appear once they send traffic through LocalProxy.")
                            .foregroundColor(.secondary)
                    } footer: {
                        limitsFooter
                    }
                } else {
                    Section {
                        ForEach(registry.devices) { device in
                            NavigationLink(destination: DeviceDetailView(registry: registry, deviceID: device.id)) {
                                DeviceRow(device: device, share: share(of: device))
                            }
                        }
                    } header: {
                        Text("\(registry.connectedCount) connected · \(registry.devices.count) seen")
                    } footer: {
                        limitsFooter
                    }
                }

                Section("Activity") {
                    NavigationLink {
                        ConnectionHistoryListView(history: history)
                    } label: {
                        Label("Recent Connections", systemImage: "magnifyingglass")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reset") { confirmReset = true }
                        .disabled(registry.devices.isEmpty)
                }
            }
            .confirmationDialog("Reset data usage for all devices?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Usage", role: .destructive) { registry.resetUsage() }
            } message: {
                Text("Device names are kept.")
            }
        }
    }

    private var limitsFooter: some View {
        Text("Only traffic sent through LocalProxy is counted. Devices are identified by local IP address, so the same device on Wi-Fi and USB shows up twice.")
    }

    private func share(of device: DeviceSummary) -> Double {
        let total = registry.devices.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
        return total > 0 ? Double(device.totalBytes) / Double(total) : 0
    }
}

private struct DeviceRow: View {
    let device: DeviceSummary
    let share: Double

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.isBlocked ? "nosign" : "desktopcomputer")
                .font(.title3)
                .foregroundColor(device.isBlocked ? .red : (device.isConnected ? .accentColor : .secondary))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(device.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if device.capBytesPerSecond != nil {
                        Image(systemName: "speedometer")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(device.totalBytes))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(device.isConnected ? .green : .secondary)
                        .lineLimit(1)
                    Spacer()
                    if device.isConnected {
                        Text("↓ \(formatRate(device.rateDown))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
                ShareBar(fraction: share)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        let prefix = device.displayName == device.ip ? "" : "\(device.ip) · "
        if device.isConnected {
            let count = device.activeConnections
            return prefix + "\(count) connection\(count == 1 ? "" : "s")"
        }
        return prefix + "Last seen \(formatLastSeen(device.lastSeen))"
    }
}

private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(4, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 4)
    }
}

enum BandwidthPreset: Hashable {
    case unlimited
    case preset(UInt64) // bytes per second
    case custom

    /// Set by `RemoteConfigManager` from `bandwidthPresetsMbps` — the
    /// picker options shown in `DeviceDetailView` below.
    static var presets: [UInt64] = [125_000, 625_000, 1_250_000] // 1 / 5 / 10 Mbps

    static func configurePresets(mbpsValues: [Int]) {
        let bytesPerSecond = mbpsValues.filter { $0 > 0 }.map { UInt64($0) * 125_000 }
        guard !bytesPerSecond.isEmpty else { return }
        presets = bytesPerSecond
    }

    init(capBytesPerSecond: UInt64?) {
        guard let cap = capBytesPerSecond else { self = .unlimited; return }
        self = Self.presets.contains(cap) ? .preset(cap) : .custom
    }
}

struct DeviceDetailView: View {
    @ObservedObject var registry: DeviceRegistry
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loadedName = false
    @State private var confirmForget = false
    @State private var bandwidthSelection: BandwidthPreset = .unlimited
    @State private var customMbpsText = ""

    private var device: DeviceSummary? { registry.devices.first { $0.id == deviceID } }

    var body: some View {
        Form {
            if let device = device {
                Section {
                    TextField("Name", text: $name, prompt: Text(device.detectedName ?? device.ip))
                        .onSubmit(commitName)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Leave empty to use \(device.detectedName == nil ? "the IP address" : "the detected name").")
                }

                Section("Usage") {
                    InfoRow(label: "Downloaded", value: formatBytes(device.bytesDown))
                    InfoRow(label: "Uploaded", value: formatBytes(device.bytesUp))
                    if device.isConnected {
                        InfoRow(label: "Download speed", value: formatRate(device.rateDown))
                        InfoRow(label: "Upload speed", value: formatRate(device.rateUp))
                    }
                }

                Section("Details") {
                    InfoRow(label: "IP address", value: device.ip)
                    InfoRow(label: "Status", value: device.isConnected
                            ? "\(device.activeConnections) active connection\(device.activeConnections == 1 ? "" : "s")"
                            : "Not connected")
                    InfoRow(label: "First seen", value: device.firstSeen.formatted(date: .abbreviated, time: .shortened))
                    InfoRow(label: "Last seen", value: formatLastSeen(device.lastSeen))
                }

                if DeviceBandwidthControlsConfig.enabled {
                Section {
                    Toggle("Block this device", isOn: Binding(
                        get: { device.isBlocked },
                        set: { registry.setBlocked(deviceID, blocked: $0) }
                    ))
                    Picker("Bandwidth limit", selection: Binding(
                        get: { bandwidthSelection },
                        set: { newValue in
                            bandwidthSelection = newValue
                            switch newValue {
                            case .unlimited:
                                registry.setCap(deviceID, bytesPerSecond: nil)
                            case .preset(let bytesPerSecond):
                                registry.setCap(deviceID, bytesPerSecond: bytesPerSecond)
                            case .custom:
                                // Doesn't set a cap by itself — the field below
                                // applies one once a value is typed.
                                break
                            }
                        }
                    )) {
                        Text("Unlimited").tag(BandwidthPreset.unlimited)
                        ForEach(BandwidthPreset.presets, id: \.self) { bytesPerSecond in
                            Text("\(bytesPerSecond / 125_000) Mbps").tag(BandwidthPreset.preset(bytesPerSecond))
                        }
                        Text("Custom").tag(BandwidthPreset.custom)
                    }

                    if bandwidthSelection == .custom {
                        HStack {
                            TextField("Mbps", text: $customMbpsText)
                                .keyboardType(.decimalPad)
                                .onSubmit(applyCustomBandwidth)
                                .onChange(of: customMbpsText) { applyCustomBandwidth() }
                            Text("Mbps")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Limits")
                } footer: {
                    Text("New connections from a blocked device are refused. A bandwidth limit applies to this device's combined upload and download rate.")
                }
                }

                Section {
                    Button("Forget This Device", role: .destructive) { confirmForget = true }
                }
            }
        }
        .navigationTitle(device?.displayName ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .onAppear {
            guard !loadedName else { return }
            loadedName = true
            name = device?.customName ?? ""

            let cap = device?.capBytesPerSecond
            bandwidthSelection = BandwidthPreset(capBytesPerSecond: cap)
            if bandwidthSelection == .custom, let cap = cap {
                customMbpsText = Self.formatMbps(bytesPerSecond: cap)
            }
        }
        .onDisappear(perform: commitName)
        .confirmationDialog("Forget this device?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                registry.forget(deviceID)
                dismiss()
            }
        } message: {
            Text("Its name and data usage are removed. It reappears the next time it sends traffic.")
        }
    }

    private func commitName() {
        guard let device = device, (device.customName ?? "") != name else { return }
        registry.rename(deviceID, to: name)
    }

    private func applyCustomBandwidth() {
        guard let mbps = Double(customMbpsText), mbps > 0 else { return }
        let bytesPerSecond = UInt64((mbps * 125_000).rounded())
        registry.setCap(deviceID, bytesPerSecond: bytesPerSecond)
    }

    private static func formatMbps(bytesPerSecond: UInt64) -> String {
        let mbps = Double(bytesPerSecond) / 125_000
        return mbps.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", mbps)
            : String(format: "%.2f", mbps)
    }
}

// MARK: - Shared formatting (also used by the dashboard)

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

func formatRate(_ bytesPerSecond: Double) -> String {
    let bits = bytesPerSecond * 8
    switch bits {
    case 1_000_000...: return String(format: "%.1f Mbps", bits / 1_000_000)
    case 1_000...: return String(format: "%.0f kbps", bits / 1_000)
    default: return String(format: "%.0f bps", bits)
    }
}

private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

func formatBytes(_ bytes: UInt64) -> String {
    byteFormatter.string(fromByteCount: Int64(bytes))
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
}()

func formatLastSeen(_ date: Date) -> String {
    Date().timeIntervalSince(date) < 60 ? "just now" : relativeFormatter.localizedString(for: date, relativeTo: Date())
}
