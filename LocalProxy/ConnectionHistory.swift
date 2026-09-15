import Foundation

/// One relayed connection's summary, built from the same values `Tunnel`
/// already computes for its `DebugLog` close line — this just surfaces them
/// to the UI instead of only the log file.
struct ConnectionSummary: Identifiable {
    let id = UUID()
    let target: String
    let mode: String
    let bytesUp: UInt64
    let bytesDown: UInt64
    let durationMs: Double
    let closedAt: Date
    let reason: String
}

/// A capped, most-recent-first list of recently closed connections, fed by
/// `ProxyServer.accept(_:)` via each `Tunnel.onSummary` callback. Exists
/// alongside `DebugLog` (which already writes every connection's detail to
/// disk) so the dashboard can show a quick, structured recent-activity list
/// without parsing the log file.
final class ConnectionHistory: ObservableObject {
    static let limit = 200

    @Published private(set) var entries: [ConnectionSummary] = []
    private let lock = NSLock()
    private var storage: [ConnectionSummary] = []

    /// Safe to call from any tunnel's queue — mutates the private, lock-protected
    /// `storage` there, and only republishes `entries` (read by SwiftUI) on main.
    func record(_ summary: ConnectionSummary) {
        lock.lock()
        storage.insert(summary, at: 0)
        if storage.count > Self.limit { storage.removeLast(storage.count - Self.limit) }
        let snapshot = storage
        lock.unlock()
        DispatchQueue.main.async { self.entries = snapshot }
    }

    func clear() {
        lock.lock(); storage.removeAll(); lock.unlock()
        DispatchQueue.main.async { self.entries = [] }
    }
}
