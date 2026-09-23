import Foundation

/// Thread-safe counters shared between the relay code (on per-tunnel queues) and
/// the UI (main thread). A per-device instance forwards every update to its
/// `parent` (the global instance), so one call site feeds both the device's
/// usage and the dashboard totals.
final class ProxyStats {
    private let parent: ProxyStats?
    private let lock = NSLock()
    private var _activeConnections = 0
    private var _bytesUp: UInt64 = 0
    private var _bytesDown: UInt64 = 0

    init(parent: ProxyStats? = nil) {
        self.parent = parent
    }

    var activeConnections: Int {
        lock.lock(); defer { lock.unlock() }
        return _activeConnections
    }

    var bytesUp: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _bytesUp
    }

    var bytesDown: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _bytesDown
    }

    // Each update releases this lock before touching the parent, so two locks are never held at once.

    func connectionOpened() {
        lock.lock(); _activeConnections += 1; lock.unlock()
        parent?.connectionOpened()
    }

    func connectionClosed() {
        lock.lock(); _activeConnections = max(0, _activeConnections - 1); lock.unlock()
        parent?.connectionClosed()
    }

    func addBytesUp(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); _bytesUp &+= UInt64(count); lock.unlock()
        parent?.addBytesUp(count)
    }

    func addBytesDown(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); _bytesDown &+= UInt64(count); lock.unlock()
        parent?.addBytesDown(count)
    }

    /// Local only — never forwarded to `parent`.
    func reset() {
        lock.lock()
        _activeConnections = 0
        _bytesUp = 0
        _bytesDown = 0
        lock.unlock()
    }

    /// Zeroes byte counts but keeps the live connection count. Local only.
    func resetBytes() {
        lock.lock()
        _bytesUp = 0
        _bytesDown = 0
        lock.unlock()
    }
}
