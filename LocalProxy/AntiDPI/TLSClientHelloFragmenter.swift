import Foundation

/// Splits a single TLS ClientHello record into multiple fragments so DPI
/// middleboxes that pattern-match the SNI hostname in one read can't see it
/// whole. Ported from Spoofy's `TLS/TLSDesyncer.swift` (github.com/ringolol/
/// Spoofy) `.sni` split mode, with its `.random` pattern split as the
/// fallback for buffers with no parseable SNI (non-TLS traffic, or a
/// ClientHello without SNI). Pure data transformation — no I/O. Reuses
/// `TLSClientHello.sniRange(in:)` (the existing SNI parser also used by
/// `TrafficSniffer`) rather than a second parser.
enum TLSClientHelloFragmenter {
    /// `data` split into fragments, each to be sent as its own `NWConnection`
    /// write. Concatenating the results in order reproduces `data` exactly.
    static func fragments(for data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        if let sniRange = TLSClientHello.sniRange(in: data) {
            return sniSplit(data, sniRange: sniRange)
        }
        return randomSplit(data, averageChunkSize: 8)
    }

    /// One fragment for everything before the SNI, one fragment per SNI
    /// byte, one fragment for everything after — the hostname substring DPI
    /// regexes match against never appears intact in a single write.
    private static func sniSplit(_ data: Data, sniRange: Range<Int>) -> [Data] {
        let bytes = [UInt8](data)
        var fragments: [Data] = []
        if sniRange.lowerBound > 0 {
            fragments.append(Data(bytes[0..<sniRange.lowerBound]))
        }
        for offset in sniRange {
            fragments.append(Data([bytes[offset]]))
        }
        if sniRange.upperBound < bytes.count {
            fragments.append(Data(bytes[sniRange.upperBound...]))
        }
        return fragments
    }

    /// Random-sized chunks (no fixed, fingerprintable boundary), averaging
    /// `averageChunkSize` bytes per fragment.
    static func randomSplit(_ data: Data, averageChunkSize: Int) -> [Data] {
        guard averageChunkSize > 0 else { return [data] }
        let bytes = [UInt8](data)
        var fragments: [Data] = []
        var index = 0
        while index < bytes.count {
            let chunkSize = Int.random(in: 1...(averageChunkSize * 2))
            let end = min(index + chunkSize, bytes.count)
            fragments.append(Data(bytes[index..<end]))
            index = end
        }
        return fragments
    }
}
