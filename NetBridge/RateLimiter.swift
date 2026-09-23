import Foundation

/// A simple token-bucket rate limiter: `capacity` tokens refill continuously
/// at `bytesPerSecond`, and `consume(_:)` returns how long the caller should
/// wait before sending `count` bytes so the long-run rate stays at the cap.
/// One instance per device (held by `DeviceRegistry.Entry`); `Tunnel.forward`
/// calls `consume` per chunk and delays the paired `send` by the result.
final class RateLimiter {
    private let lock = NSLock()
    private var bytesPerSecond: Double
    private var tokens: Double
    private var lastRefill = DispatchTime.now()

    init(bytesPerSecond: UInt64) {
        self.bytesPerSecond = Double(bytesPerSecond)
        self.tokens = Double(bytesPerSecond)
    }

    func updateRate(bytesPerSecond: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.bytesPerSecond = Double(bytesPerSecond)
    }

    /// Returns the delay (seconds) the caller should wait before this chunk's
    /// bytes are considered "sent" — 0 if there was enough headroom.
    func consume(_ count: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds &- lastRefill.uptimeNanoseconds) / 1_000_000_000
        lastRefill = now
        tokens = min(bytesPerSecond, tokens + elapsed * bytesPerSecond)

        tokens -= Double(count)
        guard tokens < 0 else { return 0 }
        let deficit = -tokens
        // The next refill will need to pay off this deficit before more
        // sends can proceed at full rate; approximate the wait directly
        // rather than looping, since this is the only consumer of `tokens`.
        let delay = bytesPerSecond > 0 ? deficit / bytesPerSecond : 0
        tokens = 0
        return delay
    }
}
