import Foundation

/// Tracks combined upload+download bytes relayed today, for the free tier's
/// daily cap — plus a separate lifetime total that never resets (not by day
/// rollover, not by any UI action, and not by reinstall). Both are persisted
/// in the Keychain (`KeychainStore`), not a file in Application Support — a
/// file is wiped on delete-and-reinstall, which would let a free user
/// reinstall to get a fresh 5GB whenever they hit the cap. Keychain items
/// survive a reinstall on the same device, closing that loophole the same
/// way `TrialManager` closes it for the trial window.
final class DailyUsageTracker: ObservableObject {
    static let defaultDailyLimitBytes: UInt64 = 5_000_000_000 // 5GB, decimal — matches how carriers state data caps
    private static let recordKey = "usage.daily"

    /// Set by `RemoteConfigManager` from the remote config's `dailyCapGB` —
    /// a plain in-memory setting (re-applied every launch from the fetched/
    /// cached config), not persisted here itself.
    @Published private(set) var dailyLimitBytes = DailyUsageTracker.defaultDailyLimitBytes
    @Published private(set) var bytesUsedToday: UInt64 = 0
    /// Lifetime total, since first install — no reset button, no daily
    /// rollover, nothing in the UI clears this. Purely informational.
    @Published private(set) var allTimeBytes: UInt64 = 0

    private struct Record: Codable {
        var date: Date
        var bytesUsed: UInt64
        var allTimeBytes: UInt64 = 0
    }

    private var day: Date

    var remainingBytes: UInt64 {
        bytesUsedToday >= dailyLimitBytes ? 0 : dailyLimitBytes - bytesUsedToday
    }

    var isOverLimit: Bool { bytesUsedToday >= dailyLimitBytes }

    /// Updates the daily cap — a no-op for an invalid (<= 0) value.
    func setDailyLimit(gigabytes: Double) {
        guard gigabytes > 0 else { return }
        dailyLimitBytes = UInt64(gigabytes * 1_000_000_000)
    }

    /// Decimal GB formatting (matches how `dailyLimitBytes` is defined) —
    /// deliberately not the shared `formatBytes()` helper elsewhere in the
    /// app, which uses binary (GiB) counting and would show "4.66 GB" for
    /// what's meant to read as a clean "5 GB" cap.
    static func formatDecimalGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return String(format: gb < 10 ? "%.2f GB" : "%.1f GB", gb)
    }

    init() {
        day = Date()
        load()
    }

    /// Adds `bytes` to both today's total (rolling over to 0 first if the
    /// stored day has changed) and the never-reset lifetime total.
    func add(_ bytes: UInt64) {
        guard bytes > 0 else { return }
        rolloverIfNeeded()
        bytesUsedToday &+= bytes
        allTimeBytes &+= bytes
        save()
    }

    private func rolloverIfNeeded() {
        let now = Date()
        guard !Calendar.current.isDate(day, inSameDayAs: now) else { return }
        day = now
        bytesUsedToday = 0
    }

    private func load() {
        guard let data = KeychainStore.load(key: Self.recordKey) else { return }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            day = record.date
            bytesUsedToday = Calendar.current.isDate(record.date, inSameDayAs: Date()) ? record.bytesUsed : 0
            allTimeBytes = record.allTimeBytes
        } catch {
            DebugLog.important("usage", "daily usage load failed \(ErrorDescription.describe(error))")
        }
    }

    private func save() {
        let record = Record(date: day, bytesUsed: bytesUsedToday, allTimeBytes: allTimeBytes)
        do {
            let data = try JSONEncoder().encode(record)
            KeychainStore.save(data, key: Self.recordKey)
        } catch {
            DebugLog.important("usage", "daily usage save failed \(ErrorDescription.describe(error))")
        }
    }
}
