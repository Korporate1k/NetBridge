import Foundation

/// A token-bucket rate limiter: up to one second of tokens refill
/// continuously at `bytesPerSecond`, and `consume(_:)` returns how long the
/// caller should wait before sending `count` bytes so the long-run rate stays
/// at the cap. A rate of 0 means unlimited.
///
/// One instance per device (owned by `DeviceRegistry.Entry` for the device's
/// whole lifetime, so rate changes reach already-open tunnels), shared by
/// every tunnel and both directions — the cap is the device's combined rate.
///
/// The balance is allowed to go negative: bytes charged but not yet paid for
/// stay owed, so concurrent callers queue behind each other instead of each
/// getting a fresh allowance. Successive `consume` delays therefore never
/// shrink, which keeps a single tunnel's delayed sends in order.
final class RateLimiter {
    private let lock = NSLock()
    private var bytesPerSecond: Double
    private var tokens: Double
    private var lastRefill = DispatchTime.now()

    init(bytesPerSecond: UInt64 = 0) {
        self.bytesPerSecond = Double(bytesPerSecond)
        self.tokens = Double(bytesPerSecond)
    }

    var isLimited: Bool {
        lock.lock(); defer { lock.unlock() }
        return bytesPerSecond > 0
    }

    func updateRate(bytesPerSecond newRate: UInt64) {
        lock.lock(); defer { lock.unlock() }
        refill(now: DispatchTime.now())
        let wasLimited = bytesPerSecond > 0
        bytesPerSecond = Double(newRate)
        if bytesPerSecond == 0 {
            tokens = 0
        } else if !wasLimited {
            tokens = bytesPerSecond
        } else {
            tokens = min(tokens, bytesPerSecond)
        }
    }

    /// Returns the delay (seconds) the caller should wait before sending
    /// `count` bytes — 0 if there was enough headroom or no cap is set.
    func consume(_ count: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard bytesPerSecond > 0 else { return 0 }
        refill(now: DispatchTime.now())
        tokens -= Double(count)
        return tokens >= 0 ? 0 : -tokens / bytesPerSecond
    }

    /// For datagrams, which can't be delayed without unbounded queueing:
    /// charges `count` and returns true if doing so keeps the debt within
    /// `maxDebtSeconds` of budget, otherwise charges nothing and returns
    /// false (the caller drops the datagram).
    func admit(_ count: Int, maxDebtSeconds: Double = 0.25) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytesPerSecond > 0 else { return true }
        refill(now: DispatchTime.now())
        guard tokens - Double(count) >= -bytesPerSecond * maxDebtSeconds else { return false }
        tokens -= Double(count)
        return true
    }

    /// Largest read a tunnel should take at once: about 100 ms of budget when
    /// capped, so sends are paced smoothly rather than as large bursts
    /// separated by long silences, and a cap change takes effect quickly.
    func maxReadLength(default defaultLength: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard bytesPerSecond > 0 else { return defaultLength }
        return min(defaultLength, max(4096, Int(bytesPerSecond / 10)))
    }

    /// Caller holds `lock`.
    private func refill(now: DispatchTime) {
        let elapsed = Double(now.uptimeNanoseconds &- lastRefill.uptimeNanoseconds) / 1_000_000_000
        lastRefill = now
        tokens = min(bytesPerSecond, tokens + elapsed * bytesPerSecond)
    }
}
