import SwiftUI

struct HomeTabView: View {
    @ObservedObject var server: ProxyServer
    @ObservedObject var keeper: BackgroundKeeper
    @ObservedObject var purchases: PurchaseManager
    @ObservedObject var trial: TrialManager
    @ObservedObject var remoteConfig: RemoteConfigManager

    @State private var showQRCode = false
    @State private var showUpgrade = false
    @State private var copied = false

    private var address: String { "\(server.localIP ?? "detecting…"):\(server.port)" }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if remoteConfig.announcementActive && !remoteConfig.announcementMessage.isEmpty {
                        announcementBanner
                    }
                    statusCard
                    usageBanner
                    statsGrid
                    allTimeUsageCard
                    UsageGraphView(samples: server.usageHistory.samples)
                    helpCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("NetBridge")
        }
        .onAppear {
            trial.refresh()
            #if DEBUG
            // QA hook (with qa.forcePaywall in RemoteConfig.swift): opens the paywall on launch, since the
            // simulator can't be tapped from the command line. Set via `simctl spawn … defaults write`.
            if UserDefaults.standard.bool(forKey: "qa.showUpgrade") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showUpgrade = true }
            }
            #endif
        }
        .sheet(isPresented: $showQRCode) {
            QRCodeSheet(server: server)
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeView(purchases: purchases, trial: trial,
                        usedTodayBytes: server.dailyUsage.bytesUsedToday,
                        dailyLimitBytes: server.dailyUsage.dailyLimitBytes)
        }
    }

    // MARK: Announcement

    private var announcementBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "megaphone.fill")
                .foregroundColor(.accentColor)
            Text(remoteConfig.announcementMessage)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard()
    }

    // MARK: Free-tier usage

    private var usageBanner: some View {
        Group {
            if !remoteConfig.paywallEnabled {
                unlimitedBanner
            } else if purchases.isPro {
                EmptyView()
            } else if trial.isInTrial {
                trialBanner
            } else {
                capBanner
            }
        }
    }

    private var unlimitedBanner: some View {
        HStack {
            Label("Unlimited — no daily limit", systemImage: "infinity")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(16)
        .glassCard()
    }

    private var trialBanner: some View {
        HStack {
            Label("Free trial: \(trial.remainingDescription) left — no daily limit",
                  systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(16)
        .glassCard()
    }

    private var capBanner: some View {
        let used = server.dailyUsage.bytesUsedToday
        let limit = server.dailyUsage.dailyLimitBytes
        let overLimit = server.dailyUsage.isOverLimit
        return Button {
            showUpgrade = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(overLimit ? "Daily free limit reached" : "\(DailyUsageTracker.formatDecimalGB(used)) of \(DailyUsageTracker.formatDecimalGB(limit)) used today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(overLimit ? .red : .primary)
                    Spacer()
                    Text("Upgrade")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(overLimit ? Color.red : Color.accentColor)
                            .frame(width: max(4, geometry.size.width * CGFloat(min(Double(used) / Double(limit), 1))))
                    }
                }
                .frame(height: 6)
            }
            .padding(16)
            .glassCard()
        }
        .buttonStyle(.plain)
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
                            Button("\(entry.displayName): \(entry.ip)") { server.selectAddress(entry.ip) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text(selectedInterfaceName)
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .accessibilityLabel("Choose network interface")
                }
                if remoteConfig.showQRCode {
                    Button { showQRCode = true } label: {
                        Image(systemName: "qrcode")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Show QR code")
                }
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

    private var selectedInterfaceName: String {
        server.availableAddresses.first(where: { $0.ip == server.localIP })?.displayName ?? "Network"
    }

    // MARK: Stats

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatTile(title: "Download", value: formatRate(server.rateDown), systemImage: "arrow.down.circle.fill", tint: .blue)
                StatTile(title: "Upload", value: formatRate(server.rateUp), systemImage: "arrow.up.circle.fill", tint: .indigo)
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

    // MARK: All-time usage

    private var allTimeUsageCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("All-Time Usage")
                    .font(.headline)
                Text("\(formatBytes(server.dailyUsage.allTimeBytes)) relayed since install — can't be reset")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .glassCard()
    }

    // MARK: Help

    private var helpCard: some View {
        NavigationLink {
            HowToGuideView(server: server)
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
}

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
