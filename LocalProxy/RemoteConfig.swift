import Foundation

/// Comprehensive server-side control: the paywall's on/off switch, trial
/// management, the free-tier daily cap and bandwidth presets, relay
/// reliability tuning, feature-visibility flags, a minimum-supported-version
/// gate, and an announcement banner — all in one small JSON file the
/// developer edits directly, no backend server needed. Published shape:
///
///     {
///       "relayEnabled": true,
///       "paywallEnabled": false,
///       "dailyCapGB": 5,
///       "bandwidthPresetsMbps": [1, 5, 10],
///
///       "trialEnabled": true,
///       "trialDurationHours": 168,
///       "trialEndDate": "",
///       "trialForceEndAll": false,
///       "bonusActive": false,
///       "bonusDays": 7,
///       "campaignID": "",
///
///       "maxRestartAttempts": 5,
///       "restartWindowSeconds": 60,
///       "maxConcurrentTunnels": 0,
///       "outboundRetryAttempts": 3,
///       "outboundRetryBaseSeconds": 1,
///
///       "doHDefaultUpstreamURL": "https://cloudflare-dns.com/dns-query",
///       "doHTimeoutSeconds": 4,
///
///       "connectionHistoryLimit": 200,
///       "usageHistoryCapacity": 720,
///
///       "showQRCode": true,
///       "showSocks5Tester": true,
///       "showUploadTest": true,
///       "showProfiles": true,
///       "showAdditionalListeners": true,
///       "showDeviceBandwidthControls": true,
///       "autoRestartEnabled": true,
///       "doHEnabled": true,
///       "backgroundKeepAliveEnabled": true,
///
///       "minSupportedVersion": "",
///       "announcementActive": false,
///       "announcementMessage": ""
///     }
///
/// Every field defaults to today's exact behavior when absent, so the
/// config already published (with only the earlier, smaller shape) keeps
/// working unchanged.
struct RemotePromoConfig: Codable {
    var relayEnabled: Bool
    var paywallEnabled: Bool
    var dailyCapGB: Double
    var bandwidthPresetsMbps: [Int]

    var trialEnabled: Bool
    var trialDurationHours: Int
    var trialEndDate: String
    var trialForceEndAll: Bool
    var bonusActive: Bool
    var bonusDays: Int
    var campaignID: String

    var maxRestartAttempts: Int
    var restartWindowSeconds: Double
    var maxConcurrentTunnels: Int
    var outboundRetryAttempts: Int
    var outboundRetryBaseSeconds: Double

    var doHDefaultUpstreamURL: String
    var doHTimeoutSeconds: Double

    var connectionHistoryLimit: Int
    var usageHistoryCapacity: Int

    // Feature visibility — force-hide/disable any of these fleet-wide
    // without a release. The three switches below (unlike the `show*`
    // flags) gate entire subsystems rather than just a UI section.
    var showQRCode: Bool
    var showSocks5Tester: Bool
    var showUploadTest: Bool
    var showProfiles: Bool
    var showAdditionalListeners: Bool
    var showDeviceBandwidthControls: Bool
    var autoRestartEnabled: Bool
    var doHEnabled: Bool
    var backgroundKeepAliveEnabled: Bool

    var minSupportedVersion: String
    var announcementActive: Bool
    var announcementMessage: String

    private enum CodingKeys: String, CodingKey {
        case relayEnabled, paywallEnabled, dailyCapGB, bandwidthPresetsMbps
        case trialEnabled, trialDurationHours, trialEndDate, trialForceEndAll, bonusActive, bonusDays, campaignID
        case autoRestartEnabled, maxRestartAttempts, restartWindowSeconds, maxConcurrentTunnels
        case outboundRetryAttempts, outboundRetryBaseSeconds
        case doHEnabled, doHDefaultUpstreamURL, doHTimeoutSeconds
        case backgroundKeepAliveEnabled, connectionHistoryLimit, usageHistoryCapacity
        case showQRCode, showSocks5Tester, showUploadTest, showProfiles, showAdditionalListeners, showDeviceBandwidthControls
        case minSupportedVersion, announcementActive, announcementMessage
    }

    /// Every field has a default matching today's exact behavior, used both
    /// for the plain initializer and for `decodeIfPresent` fallbacks so
    /// older/partial published configs keep working unchanged.
    init(
        relayEnabled: Bool = true,
        paywallEnabled: Bool = false,
        dailyCapGB: Double = 5,
        bandwidthPresetsMbps: [Int] = [1, 5, 10],
        trialEnabled: Bool = true,
        trialDurationHours: Int = 168,
        trialEndDate: String = "",
        trialForceEndAll: Bool = false,
        bonusActive: Bool = false,
        bonusDays: Int = 7,
        campaignID: String = "",
        autoRestartEnabled: Bool = true,
        maxRestartAttempts: Int = 5,
        restartWindowSeconds: Double = 60,
        maxConcurrentTunnels: Int = 0,
        outboundRetryAttempts: Int = 3,
        outboundRetryBaseSeconds: Double = 1,
        doHEnabled: Bool = true,
        doHDefaultUpstreamURL: String = "https://cloudflare-dns.com/dns-query",
        doHTimeoutSeconds: Double = 4,
        backgroundKeepAliveEnabled: Bool = true,
        connectionHistoryLimit: Int = 200,
        usageHistoryCapacity: Int = 720,
        showQRCode: Bool = true,
        showSocks5Tester: Bool = true,
        showUploadTest: Bool = true,
        showProfiles: Bool = true,
        showAdditionalListeners: Bool = true,
        showDeviceBandwidthControls: Bool = true,
        minSupportedVersion: String = "",
        announcementActive: Bool = false,
        announcementMessage: String = ""
    ) {
        self.relayEnabled = relayEnabled
        self.paywallEnabled = paywallEnabled
        self.dailyCapGB = dailyCapGB
        self.bandwidthPresetsMbps = bandwidthPresetsMbps
        self.trialEnabled = trialEnabled
        self.trialDurationHours = trialDurationHours
        self.trialEndDate = trialEndDate
        self.trialForceEndAll = trialForceEndAll
        self.bonusActive = bonusActive
        self.bonusDays = bonusDays
        self.campaignID = campaignID
        self.autoRestartEnabled = autoRestartEnabled
        self.maxRestartAttempts = maxRestartAttempts
        self.restartWindowSeconds = restartWindowSeconds
        self.maxConcurrentTunnels = maxConcurrentTunnels
        self.outboundRetryAttempts = outboundRetryAttempts
        self.outboundRetryBaseSeconds = outboundRetryBaseSeconds
        self.doHEnabled = doHEnabled
        self.doHDefaultUpstreamURL = doHDefaultUpstreamURL
        self.doHTimeoutSeconds = doHTimeoutSeconds
        self.backgroundKeepAliveEnabled = backgroundKeepAliveEnabled
        self.connectionHistoryLimit = connectionHistoryLimit
        self.usageHistoryCapacity = usageHistoryCapacity
        self.showQRCode = showQRCode
        self.showSocks5Tester = showSocks5Tester
        self.showUploadTest = showUploadTest
        self.showProfiles = showProfiles
        self.showAdditionalListeners = showAdditionalListeners
        self.showDeviceBandwidthControls = showDeviceBandwidthControls
        self.minSupportedVersion = minSupportedVersion
        self.announcementActive = announcementActive
        self.announcementMessage = announcementMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RemotePromoConfig() // defaults source
        relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? d.relayEnabled
        paywallEnabled = try c.decode(Bool.self, forKey: .paywallEnabled)
        dailyCapGB = try c.decodeIfPresent(Double.self, forKey: .dailyCapGB) ?? d.dailyCapGB
        bandwidthPresetsMbps = try c.decodeIfPresent([Int].self, forKey: .bandwidthPresetsMbps) ?? d.bandwidthPresetsMbps
        trialEnabled = try c.decodeIfPresent(Bool.self, forKey: .trialEnabled) ?? d.trialEnabled
        trialDurationHours = try c.decodeIfPresent(Int.self, forKey: .trialDurationHours) ?? d.trialDurationHours
        trialEndDate = try c.decodeIfPresent(String.self, forKey: .trialEndDate) ?? d.trialEndDate
        trialForceEndAll = try c.decodeIfPresent(Bool.self, forKey: .trialForceEndAll) ?? d.trialForceEndAll
        bonusActive = try c.decode(Bool.self, forKey: .bonusActive)
        bonusDays = try c.decode(Int.self, forKey: .bonusDays)
        campaignID = try c.decode(String.self, forKey: .campaignID)
        autoRestartEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoRestartEnabled) ?? d.autoRestartEnabled
        maxRestartAttempts = try c.decodeIfPresent(Int.self, forKey: .maxRestartAttempts) ?? d.maxRestartAttempts
        restartWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .restartWindowSeconds) ?? d.restartWindowSeconds
        maxConcurrentTunnels = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentTunnels) ?? d.maxConcurrentTunnels
        outboundRetryAttempts = try c.decodeIfPresent(Int.self, forKey: .outboundRetryAttempts) ?? d.outboundRetryAttempts
        outboundRetryBaseSeconds = try c.decodeIfPresent(Double.self, forKey: .outboundRetryBaseSeconds) ?? d.outboundRetryBaseSeconds
        doHEnabled = try c.decodeIfPresent(Bool.self, forKey: .doHEnabled) ?? d.doHEnabled
        doHDefaultUpstreamURL = try c.decodeIfPresent(String.self, forKey: .doHDefaultUpstreamURL) ?? d.doHDefaultUpstreamURL
        doHTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .doHTimeoutSeconds) ?? d.doHTimeoutSeconds
        backgroundKeepAliveEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundKeepAliveEnabled) ?? d.backgroundKeepAliveEnabled
        connectionHistoryLimit = try c.decodeIfPresent(Int.self, forKey: .connectionHistoryLimit) ?? d.connectionHistoryLimit
        usageHistoryCapacity = try c.decodeIfPresent(Int.self, forKey: .usageHistoryCapacity) ?? d.usageHistoryCapacity
        showQRCode = try c.decodeIfPresent(Bool.self, forKey: .showQRCode) ?? d.showQRCode
        showSocks5Tester = try c.decodeIfPresent(Bool.self, forKey: .showSocks5Tester) ?? d.showSocks5Tester
        showUploadTest = try c.decodeIfPresent(Bool.self, forKey: .showUploadTest) ?? d.showUploadTest
        showProfiles = try c.decodeIfPresent(Bool.self, forKey: .showProfiles) ?? d.showProfiles
        showAdditionalListeners = try c.decodeIfPresent(Bool.self, forKey: .showAdditionalListeners) ?? d.showAdditionalListeners
        showDeviceBandwidthControls = try c.decodeIfPresent(Bool.self, forKey: .showDeviceBandwidthControls) ?? d.showDeviceBandwidthControls
        minSupportedVersion = try c.decodeIfPresent(String.self, forKey: .minSupportedVersion) ?? d.minSupportedVersion
        announcementActive = try c.decodeIfPresent(Bool.self, forKey: .announcementActive) ?? d.announcementActive
        announcementMessage = try c.decodeIfPresent(String.self, forKey: .announcementMessage) ?? d.announcementMessage
    }
}

@MainActor
final class RemoteConfigManager: ObservableObject {
    // Secret Gist (unlisted, not publicly searchable, but reachable without
    // auth — see https://gist.github.com/Korporate1k/92817bcaa07f1fb621a903919d1574a9).
    // Edit the gist directly (or `gh gist edit`) to change any setting —
    // no app update needed.
    private static let configURL = URL(string: "https://gist.githubusercontent.com/Korporate1k/92817bcaa07f1fb621a903919d1574a9/raw/localproxy-config.json")!
    private static let cacheKey = "remoteConfig.cached"
    /// Fleet changes should reach a running app quickly — poll on this
    /// interval rather than only fetching once at launch. Each request is
    /// cache-busted (see `fetchRequest`) since GitHub's CDN in front of
    /// raw Gist content caches responses for a few minutes, which would
    /// otherwise silently defeat a fast poll.
    private static let pollInterval: TimeInterval = 10
    private var pollTimer: Timer?

    /// Fail-safe defaults: paywall OFF, relay ON, every feature visible,
    /// until a fetch or cache proves otherwise. If the config URL is ever
    /// unreachable, this is what stays in effect.
    @Published private(set) var paywallEnabled = false
    @Published private(set) var showQRCode = true
    @Published private(set) var showSocks5Tester = true
    @Published private(set) var showUploadTest = true
    @Published private(set) var showProfiles = true
    @Published private(set) var showAdditionalListeners = true
    @Published private(set) var showDeviceBandwidthControls = true
    @Published private(set) var backgroundKeepAliveEnabled = true
    @Published private(set) var minSupportedVersion = ""
    @Published private(set) var announcementActive = false
    @Published private(set) var announcementMessage = ""

    private let trial: TrialManager
    private let server: ProxyServer

    init(trial: TrialManager, server: ProxyServer) {
        self.trial = trial
        self.server = server
        if let cached = Self.load(from: KeychainStore.load(key: Self.cacheKey)) {
            DebugLog.important("remoteconfig", "applying cached config paywallEnabled=\(cached.paywallEnabled)")
            apply(cached, persist: false)
        } else {
            DebugLog.important("remoteconfig", "no cached config found — starting from safe defaults")
        }
        Task { await fetch() }
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.fetch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// A cache-busted request for the config JSON — GitHub's CDN caches
    /// raw Gist content for a few minutes by default, which would make a
    /// 10-second poll pointless without this.
    private func fetchRequest() -> URLRequest {
        var components = URLComponents(url: Self.configURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        return request
    }

    /// Re-fetches now — safe to call as often as wanted (e.g. on each
    /// dashboard appearance); a failed fetch just leaves the cached/current
    /// state untouched rather than erroring visibly to the user.
    func fetch() async {
        DebugLog.important("remoteconfig", "fetch starting from \(Self.configURL)")
        do {
            let (data, response) = try await URLSession.shared.data(for: fetchRequest())
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let config = Self.load(from: data) else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8, \(data.count) bytes>"
                DebugLog.important("remoteconfig", "fetch returned unparseable JSON — status=\(status) body=\(body.prefix(200))")
                return
            }
            DebugLog.important("remoteconfig", "fetch succeeded — status=\(status) paywallEnabled=\(config.paywallEnabled) relayEnabled=\(config.relayEnabled)")
            apply(config, persist: true)
        } catch {
            DebugLog.important("remoteconfig", "fetch failed \(ErrorDescription.describe(error)) — keeping cached state")
        }
    }

    private func apply(_ config: RemotePromoConfig, persist: Bool) {
        paywallEnabled = config.paywallEnabled
        showQRCode = config.showQRCode
        showSocks5Tester = config.showSocks5Tester
        showUploadTest = config.showUploadTest
        showProfiles = config.showProfiles
        showAdditionalListeners = config.showAdditionalListeners
        showDeviceBandwidthControls = config.showDeviceBandwidthControls
        backgroundKeepAliveEnabled = config.backgroundKeepAliveEnabled
        minSupportedVersion = config.minSupportedVersion
        announcementActive = config.announcementActive
        announcementMessage = config.announcementMessage

        trial.setTrialEnabled(config.trialEnabled)
        trial.setTrialDuration(hours: Double(config.trialDurationHours))
        trial.setAbsoluteCeiling(Self.parseDate(config.trialEndDate))
        trial.setForceEnded(config.trialForceEndAll)
        if config.bonusActive {
            trial.applyBonus(days: config.bonusDays, campaignID: config.campaignID)
        }

        server.relayEnabled = { config.relayEnabled }
        server.dailyUsage.setDailyLimit(gigabytes: config.dailyCapGB)
        server.autoRestartEnabled = config.autoRestartEnabled
        server.maxRestartAttempts = config.maxRestartAttempts
        server.restartWindow = config.restartWindowSeconds
        server.maxConcurrentTunnels = config.maxConcurrentTunnels
        server.outboundRetryAttempts = config.outboundRetryAttempts
        server.outboundRetryBaseSeconds = config.outboundRetryBaseSeconds
        server.history.setLimit(config.connectionHistoryLimit)
        server.usageHistory.setCapacity(config.usageHistoryCapacity)
        server.stopIfDisallowed()

        DoHResolver.shared.applyRemoteSettings(
            enabled: config.doHEnabled,
            defaultUpstreamURL: config.doHDefaultUpstreamURL,
            timeoutSeconds: config.doHTimeoutSeconds
        )

        BandwidthPresetConfig.apply(mbpsValues: config.bandwidthPresetsMbps)
        BackgroundKeepAliveConfig.enabled = config.backgroundKeepAliveEnabled
        DeviceBandwidthControlsConfig.enabled = config.showDeviceBandwidthControls

        DebugLog.important("remoteconfig", "applied — relayEnabled=\(config.relayEnabled) paywallEnabled=\(config.paywallEnabled) dailyCapGB=\(config.dailyCapGB) bandwidthPresetsMbps=\(config.bandwidthPresetsMbps) " +
            "trialEnabled=\(config.trialEnabled) trialDurationHours=\(config.trialDurationHours) trialEndDate=\(config.trialEndDate) trialForceEndAll=\(config.trialForceEndAll) bonusActive=\(config.bonusActive) bonusDays=\(config.bonusDays) campaignID=\(config.campaignID) " +
            "autoRestartEnabled=\(config.autoRestartEnabled) maxRestartAttempts=\(config.maxRestartAttempts) restartWindowSeconds=\(config.restartWindowSeconds) maxConcurrentTunnels=\(config.maxConcurrentTunnels) outboundRetryAttempts=\(config.outboundRetryAttempts) outboundRetryBaseSeconds=\(config.outboundRetryBaseSeconds) " +
            "doHEnabled=\(config.doHEnabled) doHDefaultUpstreamURL=\(config.doHDefaultUpstreamURL) doHTimeoutSeconds=\(config.doHTimeoutSeconds) connectionHistoryLimit=\(config.connectionHistoryLimit) usageHistoryCapacity=\(config.usageHistoryCapacity) " +
            "showQRCode=\(config.showQRCode) showSocks5Tester=\(config.showSocks5Tester) showUploadTest=\(config.showUploadTest) showProfiles=\(config.showProfiles) showAdditionalListeners=\(config.showAdditionalListeners) showDeviceBandwidthControls=\(config.showDeviceBandwidthControls) backgroundKeepAliveEnabled=\(config.backgroundKeepAliveEnabled) " +
            "minSupportedVersion=\(config.minSupportedVersion) announcementActive=\(config.announcementActive) announcementMessage=\(config.announcementMessage)")

        if persist, let data = try? JSONEncoder().encode(config) {
            KeychainStore.save(data, key: Self.cacheKey)
        }
    }

    private static func load(from data: Data?) -> RemotePromoConfig? {
        guard let data = data else { return nil }
        return try? JSONDecoder().decode(RemotePromoConfig.self, from: data)
    }

    /// Parses a "yyyy-MM-dd" string as UTC midnight — `nil` for an empty
    /// string (meaning "no ceiling, use the per-user trial duration alone")
    /// or anything unparseable.
    private static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}

/// A tiny cross-file bridge so `RemoteConfigManager` (which doesn't import
/// SwiftUI) can hand `DevicesView`'s bandwidth-preset picker its remote
/// values without a direct dependency in either direction.
enum BandwidthPresetConfig {
    static func apply(mbpsValues: [Int]) {
        BandwidthPreset.configurePresets(mbpsValues: mbpsValues)
    }
}

/// Same bridge pattern for `BackgroundKeeper`'s remote kill switch.
enum BackgroundKeepAliveConfig {
    static var enabled = true {
        didSet { BackgroundKeeper.remoteEnabled = enabled }
    }
}

/// Same bridge pattern for `DevicesView`'s per-device block/bandwidth
/// controls section.
enum DeviceBandwidthControlsConfig {
    static var enabled = true
}
