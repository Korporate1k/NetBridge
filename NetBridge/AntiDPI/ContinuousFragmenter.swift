import Foundation

/// Full-session traffic shaping (no Spoofy equivalent — Spoofy only
/// fragments the TLS ClientHello). Applied to every upstream write for the
/// life of a connection, not just the handshake, so packet-size/timing-based
/// DPI/ISP classifiers ("this flow looks like video streaming") can't
/// fingerprint it mid-session either.
///
/// This is a byte-for-byte relay: it can only reshape how the client's own
/// bytes are segmented and paced on the wire. It cannot add padding (would
/// corrupt the TLS stream) and cannot hide total data volume from a
/// volume-based cap — only pattern-based classification.
enum ContinuousFragmenter {
    /// `data` split into `(fragment, delayBeforeSending)` pairs, sized/paced
    /// per the current `AntiDPITuning` (`.light` by default; see the
    /// Settings toggle). The first fragment's delay is always 0 — callers
    /// send it immediately and only wait before subsequent fragments.
    /// Concatenating the fragments in order reproduces `data` exactly.
    static func fragments(for data: Data) -> [(Data, TimeInterval)] {
        guard !data.isEmpty else { return [] }
        let tuning = AntiDPITuning.current
        let bytes = [UInt8](data)
        var result: [(Data, TimeInterval)] = []
        var index = 0
        while index < bytes.count {
            let chunkSize = Int.random(in: tuning.chunkSizeRange)
            let end = min(index + chunkSize, bytes.count)
            let delay = result.isEmpty ? 0 : TimeInterval.random(in: tuning.jitterRange)
            result.append((Data(bytes[index..<end]), delay))
            index = end
        }
        return result
    }
}
