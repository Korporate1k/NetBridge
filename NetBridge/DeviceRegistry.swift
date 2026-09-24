import Foundation
import Network
import UIKit

struct DeviceSummary: Identifiable {
    let id: String
    let displayName: String
    let customName: String?
    let detectedName: String?
    let bytesUp: UInt64
    let bytesDown: UInt64
    let rateUp: Double
    let rateDown: Double
    let activeConnections: Int
    let firstSeen: Date
    let lastSeen: Date
    let isBlocked: Bool
    let capBytesPerSecond: UInt64?

    var ip: String { id }
    var totalBytes: UInt64 { bytesUp &+ bytesDown }
    var isConnected: Bool { activeConnections > 0 }
}

/// Per-device data usage for clients proxied through NetBridge, keyed by the
/// client's local IP (iOS exposes no list of connected clients, so only devices
/// that send traffic through the proxy are known). Usage is saved to disk and
/// survives relaunches until `resetUsage()`.
///
/// Each device's live counts come from a `ProxyStats` whose parent is the
/// global stats, so the existing relay call sites feed both without change.
final class DeviceRegistry: ObservableObject {
    private static let saveInterval: TimeInterval = 30

    @Published private(set) var devices: [DeviceSummary] = []

    var connectedCount: Int { devices.filter(\.isConnected).count }

    private struct Record: Codable {
        var ip: String
        var customName: String?
        var detectedName: String?
        var bytesUp: UInt64
        var bytesDown: UInt64
        var firstSeen: Date
        var lastSeen: Date
        var isBlocked: Bool = false
        var capBytesPerSecond: UInt64?
    }

    private final class Entry {
        let ip: String
        var customName: String?
        var detectedName: String?
        /// Usage persisted before this launch (or since the last reset); live counts add on top.
        var baselineUp: UInt64
        var baselineDown: UInt64
        let firstSeen: Date
        var lastSeen: Date
        var live: ProxyStats?
        var prevUp: UInt64
        var prevDown: UInt64
        var rateUp: Double = 0
        var rateDown: Double = 0
        var isBlocked: Bool = false
        var capBytesPerSecond: UInt64? {
            didSet { rateLimiter.updateRate(bytesPerSecond: capBytesPerSecond ?? 0) }
        }
        /// Lives as long as the entry (rate 0 = unlimited) so every tunnel
        /// from this device shares it and cap changes reach open tunnels.
        let rateLimiter = RateLimiter()

        init(record: Record) {
            ip = record.ip
            customName = record.customName
            detectedName = record.detectedName
            baselineUp = record.bytesUp
            baselineDown = record.bytesDown
            firstSeen = record.firstSeen
            lastSeen = record.lastSeen
            prevUp = record.bytesUp
            prevDown = record.bytesDown
            isBlocked = record.isBlocked
            capBytesPerSecond = record.capBytesPerSecond
            // didSet doesn't run during init.
            rateLimiter.updateRate(bytesPerSecond: record.capBytesPerSecond ?? 0)
        }

        init(ip: String, now: Date) {
            self.ip = ip
            baselineUp = 0
            baselineDown = 0
            firstSeen = now
            lastSeen = now
            prevUp = 0
            prevDown = 0
        }

        var totalUp: UInt64 { baselineUp &+ (live?.bytesUp ?? 0) }
        var totalDown: UInt64 { baselineDown &+ (live?.bytesDown ?? 0) }

        var record: Record {
            Record(ip: ip, customName: customName, detectedName: detectedName,
                   bytesUp: totalUp, bytesDown: totalDown, firstSeen: firstSeen, lastSeen: lastSeen,
                   isBlocked: isBlocked, capBytesPerSecond: capBytesPerSecond)
        }

        var summary: DeviceSummary {
            DeviceSummary(id: ip,
                          displayName: customName ?? detectedName ?? ip,
                          customName: customName,
                          detectedName: detectedName,
                          bytesUp: totalUp,
                          bytesDown: totalDown,
                          rateUp: rateUp,
                          rateDown: rateDown,
                          activeConnections: live?.activeConnections ?? 0,
                          firstSeen: firstSeen,
                          lastSeen: lastSeen,
                          isBlocked: isBlocked,
                          capBytesPerSecond: capBytesPerSecond)
        }
    }

    // Entries are touched from the listener queue (new tunnels), tunnel queues
    // (target hosts) and main (refresh/edits), so everything goes through `lock`.
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var dirty = false
    private var lastSaveAt = Date.distantPast
    private var lastRefreshAt = Date()
    private let fileURL: URL?
    private var backgroundObserver: NSObjectProtocol?

    init() {
        fileURL = try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("devices.json")
        load()
        publish()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.save()
        }
    }

    deinit {
        if let backgroundObserver = backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    static func deviceKey(for endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unknown" }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        let unscoped = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        // An IPv4 client seen through a dual-stack socket is the same device
        // as its plain IPv4 form — key both the same so they share one cap.
        let mappedPrefix = "::ffff:"
        if unscoped.lowercased().hasPrefix(mappedPrefix) {
            let v4 = String(unscoped.dropFirst(mappedPrefix.count))
            if IPv4Address(v4) != nil { return v4 }
        }
        return unscoped
    }

    // MARK: - Relay-side hooks

    /// The counters and the rate limiter a new tunnel from `ip` should use,
    /// fetched under one lock so a concurrent `forget` can't split them.
    /// Counters are created once per device per launch; the limiter lives as
    /// long as the device's entry.
    func attach(forDevice ip: String, parent: ProxyStats) -> (stats: ProxyStats, rateLimiter: RateLimiter) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let entry: Entry
        if let existing = entries[ip] {
            entry = existing
        } else {
            entry = Entry(ip: ip, now: now)
            entries[ip] = entry
        }
        entry.lastSeen = now
        dirty = true
        if let live = entry.live { return (live, entry.rateLimiter) }
        let live = ProxyStats(parent: parent)
        entry.live = live
        return (live, entry.rateLimiter)
    }

    /// Whether new connections from `ip` should be refused outright. Reads
    /// only — an IP that's never been seen can't have been blocked, so this
    /// never creates an entry (unlike `attach(forDevice:parent:)`).
    func isBlocked(_ ip: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[ip]?.isBlocked ?? false
    }

    func setBlocked(_ ip: String, blocked: Bool) {
        lock.lock()
        entries[ip]?.isBlocked = blocked
        lock.unlock()
        publish()
        save()
    }

    func setCap(_ ip: String, bytesPerSecond: UInt64?) {
        lock.lock()
        // A cap of 0 would read as "capped" in the UI while limiting nothing.
        entries[ip]?.capBytesPerSecond = (bytesPerSecond ?? 0) > 0 ? bytesPerSecond : nil
        lock.unlock()
        publish()
        save()
    }

    // MARK: - UI-side (main thread)

    /// Recomputes rates and republishes. Pass `isRunning: false` when the proxy stops so rates drop to zero.
    func refresh(isRunning: Bool = true) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefreshAt)
        lastRefreshAt = now

        lock.lock()
        for entry in entries.values {
            let up = entry.totalUp
            let down = entry.totalDown
            let changed = up != entry.prevUp || down != entry.prevDown
            if isRunning && elapsed > 0 {
                entry.rateUp = up >= entry.prevUp ? Double(up - entry.prevUp) / elapsed : 0
                entry.rateDown = down >= entry.prevDown ? Double(down - entry.prevDown) / elapsed : 0
            } else {
                entry.rateUp = 0
                entry.rateDown = 0
            }
            if changed || (entry.live?.activeConnections ?? 0) > 0 {
                entry.lastSeen = now
                dirty = true
            }
            entry.prevUp = up
            entry.prevDown = down
        }
        let shouldSave = dirty && now.timeIntervalSince(lastSaveAt) >= Self.saveInterval
        lock.unlock()

        publish()
        if shouldSave { save() }
    }

    func rename(_ ip: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        entries[ip]?.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        lock.unlock()
        publish()
        save()
    }

    func forget(_ ip: String) {
        lock.lock()
        // Tunnels still open keep this limiter — lift the cap on them too.
        entries.removeValue(forKey: ip)?.rateLimiter.updateRate(bytesPerSecond: 0)
        lock.unlock()
        publish()
        save()
    }

    func resetUsage() {
        lock.lock()
        for entry in entries.values {
            entry.live?.resetBytes()
            entry.baselineUp = 0
            entry.baselineDown = 0
            entry.prevUp = 0
            entry.prevDown = 0
            entry.rateUp = 0
            entry.rateDown = 0
        }
        lock.unlock()
        publish()
        save()
    }

    func save() {
        guard let fileURL = fileURL else { return }
        lock.lock()
        let records = entries.values.map(\.record)
        dirty = false
        lastSaveAt = Date()
        lock.unlock()
        do {
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            DebugLog.important("devices", "save failed \(ErrorDescription.describe(error))")
        }
    }

    // MARK: - Private

    private func load() {
        guard let fileURL = fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            for record in try JSONDecoder().decode([Record].self, from: data) {
                entries[record.ip] = Entry(record: record)
            }
        } catch {
            DebugLog.important("devices", "load failed \(ErrorDescription.describe(error))")
        }
    }

    private func publish() {
        lock.lock()
        let summaries = entries.values.map(\.summary)
        lock.unlock()
        devices = summaries.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
            return $0.ip < $1.ip
        }
    }
}
