import SwiftUI

struct DevicesView: View {
    @ObservedObject var registry: DeviceRegistry
    @ObservedObject var history: ConnectionHistory
    /// Mirrors `RemoteConfigManager.showDeviceBandwidthControls`.
    let showControls: Bool
    @State private var confirmReset = false

    var body: some View {
        NavigationView {
            List {
                if registry.devices.isEmpty {
                    Section {
                        Text("No devices yet — devices appear once they send traffic through NetBridge.")
                            .foregroundColor(.secondary)
                    } footer: {
                        limitsFooter
                    }
                } else {
                    Section {
                        ForEach(registry.devices) { device in
                            NavigationLink(destination: DeviceDetailView(registry: registry, deviceID: device.id, showControls: showControls)) {
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
        Text("Only traffic sent through NetBridge is counted. Devices are identified by local IP address, so the same device on Wi-Fi and USB shows up twice, each with its own block and bandwidth limit.")
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
                        Text(rateText)
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

    /// A cap limits upload + download combined, so show that total against
    /// it; otherwise just the download rate.
    private var rateText: String {
        if let cap = device.capBytesPerSecond {
            return "↑↓ \(formatRate(device.rateUp + device.rateDown)) / \(formatMbps(bytesPerSecond: cap)) Mbps"
        }
        return "↓ \(formatRate(device.rateDown))"
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

    /// Accepted range for any cap, in Mbps — also bounds remote presets so a
    /// bad value can't overflow the bytes-per-second conversion.
    static let minMbps = 0.1
    static let maxMbps = 10_000.0

    static func configurePresets(mbpsValues: [Int]) {
        let valid = Set(mbpsValues.filter { $0 >= 1 && Double($0) <= maxMbps })
        let bytesPerSecond = valid.sorted().map { UInt64($0) * 125_000 }
        guard !bytesPerSecond.isEmpty else { return }
        presets = bytesPerSecond
    }

    /// Mbps → bytes/s, or nil if not finite or outside `minMbps...maxMbps`.
    static func bytesPerSecond(mbps: Double) -> UInt64? {
        guard mbps.isFinite, mbps >= minMbps, mbps <= maxMbps else { return nil }
        return UInt64((mbps * 125_000).rounded())
    }

    init(capBytesPerSecond: UInt64?) {
        guard let cap = capBytesPerSecond else { self = .unlimited; return }
        self = Self.presets.contains(cap) ? .preset(cap) : .custom
    }
}

struct DeviceDetailView: View {
    @ObservedObject var registry: DeviceRegistry
    let deviceID: String
    let showControls: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loadedName = false
    @State private var confirmForget = false
    @State private var bandwidthSelection: BandwidthPreset = .unlimited
    @State private var customMbpsText = ""
    @State private var customMbpsInvalid = false
    @FocusState private var customFieldFocused: Bool

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
                        if let cap = device.capBytesPerSecond {
                            InfoRow(label: "Combined / limit",
                                    value: "\(formatRate(device.rateUp + device.rateDown)) / \(formatMbps(bytesPerSecond: cap)) Mbps")
                        }
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

                if showControls {
                Section {
                    Toggle("Block this device", isOn: Binding(
                        get: { device.isBlocked },
                        set: { registry.setBlocked(deviceID, blocked: $0) }
                    ))
                    Picker("Bandwidth limit", selection: Binding(
                        get: { bandwidthSelection },
                        set: { newValue in
                            bandwidthSelection = newValue
                            customMbpsInvalid = false
                            switch newValue {
                            case .unlimited:
                                registry.setCap(deviceID, bytesPerSecond: nil)
                            case .preset(let bytesPerSecond):
                                registry.setCap(deviceID, bytesPerSecond: bytesPerSecond)
                            case .custom:
                                // Doesn't change the cap by itself — the field
                                // below applies one when a value is committed.
                                // Start from the current cap, if any.
                                customMbpsText = device.capBytesPerSecond.map { formatMbps(bytesPerSecond: $0) } ?? ""
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
                                .focused($customFieldFocused)
                                .onSubmit(applyCustomBandwidth)
                                .onChange(of: customFieldFocused) { if !customFieldFocused { applyCustomBandwidth() } }
                            Text("Mbps")
                                .foregroundColor(.secondary)
                        }
                        if customMbpsInvalid {
                            Text("Enter a value between \(formatMbps(BandwidthPreset.minMbps)) and \(formatMbps(BandwidthPreset.maxMbps)) Mbps.")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Limits")
                } footer: {
                    Text("New connections from a blocked device are refused. A bandwidth limit applies to this device's combined upload and download rate, TCP and UDP, and takes effect on open connections too. Limits follow the device's IP address.")
                }
                } else if device.isBlocked || device.capBytesPerSecond != nil {
                    // Controls are hidden remotely, but a block or cap set
                    // earlier still applies — show it and let it be removed.
                    Section {
                        if device.isBlocked {
                            InfoRow(label: "Status", value: "Blocked")
                            Button("Unblock") { registry.setBlocked(deviceID, blocked: false) }
                        }
                        if let cap = device.capBytesPerSecond {
                            InfoRow(label: "Bandwidth limit", value: "\(formatMbps(bytesPerSecond: cap)) Mbps")
                            Button("Remove Limit") {
                                registry.setCap(deviceID, bytesPerSecond: nil)
                                bandwidthSelection = .unlimited
                            }
                        }
                    } header: {
                        Text("Limits")
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
                customMbpsText = formatMbps(bytesPerSecond: cap)
            }
        }
        .onDisappear(perform: commitName)
        .confirmationDialog("Forget this device?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                registry.forget(deviceID)
                dismiss()
            }
        } message: {
            Text("Its name, data usage, block and bandwidth limit are removed. It reappears the next time it sends traffic.")
        }
    }

    private func commitName() {
        guard let device = device, (device.customName ?? "") != name else { return }
        registry.rename(deviceID, to: name)
    }

    /// Parses with the user's locale (the decimal pad types "," in many
    /// regions) and applies only a finite value in range; anything else
    /// leaves the current cap untouched and says so.
    private func applyCustomBandwidth() {
        let text = customMbpsText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { customMbpsInvalid = false; return }
        guard let mbps = mbpsParser.number(from: text)?.doubleValue,
              let bytesPerSecond = BandwidthPreset.bytesPerSecond(mbps: mbps) else {
            customMbpsInvalid = true
            return
        }
        customMbpsInvalid = false
        registry.setCap(deviceID, bytesPerSecond: bytesPerSecond)
    }
}

private let mbpsParser: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = .current
    return formatter
}()

func formatMbps(bytesPerSecond: UInt64) -> String {
    formatMbps(Double(bytesPerSecond) / 125_000)
}

func formatMbps(_ mbps: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: mbps)) ?? String(format: "%.2f", mbps)
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
