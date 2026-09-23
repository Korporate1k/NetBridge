import Foundation

struct UsageSample: Identifiable {
    let id = UUID()
    let at: Date
    let up: Double // bytes/sec
    let down: Double // bytes/sec
}

/// A capped, time-ordered window of throughput samples for the "Historical
/// usage" graph. Session-scoped like `ProxyServer.bytesUp`/`bytesDown` —
/// reset on `stop()`, not persisted across launches. Sampled every 5s while
/// the proxy runs, mirroring `ProxyServer`'s existing 1Hz throughput-logging
/// timer pattern at a slower, UI-appropriate cadence.
final class UsageHistory: ObservableObject {
    static let defaultCapacity = 720 // 1 hour at 5s resolution

    @Published private(set) var samples: [UsageSample] = []
    private var lastUp: UInt64 = 0
    private var lastDown: UInt64 = 0
    private var lastAt: Date?
    /// Set by `RemoteConfigManager` from `usageHistoryCapacity`.
    private var capacity = UsageHistory.defaultCapacity

    func setCapacity(_ newCapacity: Int) {
        guard newCapacity > 0 else { return }
        capacity = newCapacity
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    func reset() {
        samples = []
        lastUp = 0
        lastDown = 0
        lastAt = nil
    }

    func sample(bytesUp: UInt64, bytesDown: UInt64) {
        let now = Date()
        defer { lastUp = bytesUp; lastDown = bytesDown; lastAt = now }
        guard let last = lastAt else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return }
        let upRate = bytesUp >= lastUp ? Double(bytesUp - lastUp) / elapsed : 0
        let downRate = bytesDown >= lastDown ? Double(bytesDown - lastDown) / elapsed : 0
        samples.append(UsageSample(at: now, up: upRate, down: downRate))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}
