import Foundation
import Network

/// Entry point for the Anti-DPI feature: splits and paces outbound writes on
/// the relay's upstream (client -> server) leg so DPI/ISP classifiers can't
/// pattern-match a hostname in one read (handshake) or fingerprint a flow by
/// packet-size/timing (the rest of the connection). See
/// `/Users/matthew/.claude/plans/pasted-content-id-0082-https-github-com-concurrent-origami.md`
/// for the full design.
///
/// Read-directly-from-UserDefaults pattern, matching `DoHResolver`
/// (`doh.enabled`) and `EgressInterface` (`egress.bindVPN`) — no plumbing
/// through `Tunnel`/`ProxyServer` init.
/// How hard `ContinuousFragmenter` shapes traffic for the life of a
/// connection. `.light` is the default — small jitter, larger/fewer chunks,
/// still resists pattern-based classification with much less throughput
/// cost than `.aggressive` (small forced chunks + real jitter, maximizing
/// pattern disruption at a real speed cost). Doesn't affect handshake-only
/// SNI fragmentation, which is unconditional whenever Anti-DPI is on.
enum AntiDPITuning: String, CaseIterable, Identifiable {
    case light, aggressive
    var id: String { rawValue }

    static let defaultsKey = "antidpi.tuning"
    static var current: AntiDPITuning {
        AntiDPITuning(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .light
    }

    var label: String {
        switch self {
        case .light: return "Light"
        case .aggressive: return "Aggressive"
        }
    }

    var chunkSizeRange: ClosedRange<Int> {
        switch self {
        case .light: return 1024...8192
        case .aggressive: return 16...96
        }
    }

    var jitterRange: ClosedRange<TimeInterval> {
        switch self {
        case .light: return 0.0005...0.002
        case .aggressive: return 0.002...0.020
        }
    }
}

enum AntiDPI {
    static let enabledKey = "antidpi.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Sends `data` over `connection`, fragmented per `isHandshake`, calling
    /// `completion` once every fragment is sent (matching `NWConnection`'s
    /// own send-completion contract) or on the first fragment's error.
    /// Callers only use this when `isEnabled` — it does no enabled-check of
    /// its own, so it can also be unit-exercised directly.
    static func send(
        _ data: Data,
        over connection: NWConnection,
        queue: DispatchQueue,
        isHandshake: Bool,
        completion: @escaping (NWError?) -> Void
    ) {
        guard !data.isEmpty else {
            completion(nil)
            return
        }

        let fragments: [(Data, TimeInterval)]
        if isHandshake {
            fragments = TLSClientHelloFragmenter.fragments(for: data).map { ($0, 0) }
        } else {
            fragments = ContinuousFragmenter.fragments(for: data)
        }
        guard !fragments.isEmpty else {
            completion(nil)
            return
        }

        sendNext(fragments, index: 0, over: connection, queue: queue, completion: completion)
    }

    private static func sendNext(
        _ fragments: [(Data, TimeInterval)],
        index: Int,
        over connection: NWConnection,
        queue: DispatchQueue,
        completion: @escaping (NWError?) -> Void
    ) {
        let (fragment, delay) = fragments[index]
        let isLast = index == fragments.count - 1
        let doSend = {
            connection.send(content: fragment, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
                if let error = error {
                    completion(error)
                    return
                }
                if isLast {
                    completion(nil)
                } else {
                    sendNext(fragments, index: index + 1, over: connection, queue: queue, completion: completion)
                }
            })
        }
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, execute: doSend)
        } else {
            doSend()
        }
    }
}
