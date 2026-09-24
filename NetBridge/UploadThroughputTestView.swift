import SwiftUI
import Network

/// A diagnostic screen that dials a destination IP:port directly (TCP or
/// UDP, bypassing the proxy — testing the network path/server itself, the
/// same way a speed-test tool measures a link) and pushes a bounded amount
/// of synthetic data, reporting achieved throughput. Companion to
/// `Socks5ClientTestView` ("is my proxy reachable") — this answers "how
/// fast can I push data through my own infrastructure."
///
/// Explicitly scoped as a bounded, single-connection measurement tool, not
/// a load-generation tool: a hard byte cap, a hard duration cap (whichever
/// hits first wins), exactly one connection per run, and synthetic
/// (not user) payload data. The transfer cap / duration / rate limit are
/// all user-adjustable for real sustained-load testing, but never past the
/// hard ceilings in `Caps` below.
struct UploadThroughputTestView: View {
    @State private var destinationHost = ""
    @State private var destinationPort = ""
    @State private var selectedProtocol: TestProtocol = .tcp

    @State private var capMBText = "50"
    @State private var capDurationText = "300"
    @State private var rateLimitMbpsText = ""

    @State private var status: TestStatus = .idle
    @State private var running = false
    @State private var progressBytes: UInt64 = 0

    private enum Caps {
        static let hardCeilingMB = 5000                     // 5 GB — app-enforced ceiling, never exceeded regardless of input
        static let maxDurationSeconds: TimeInterval = 3600   // 60 min — app-enforced ceiling, never exceeded regardless of input
        static let tcpChunkSize = 64 * 1024                  // 64KB per TCP send() call
        // Conservative UDP datagram size — stays under typical path MTU (1500
        // Ethernet minus IP/UDP headers and common VPN/tunnel overhead) to
        // avoid IP fragmentation. Not user-configurable: a protocol-correctness
        // detail, not a test parameter.
        static let udpDatagramSize = 1200
    }

    private enum TestProtocol: String, CaseIterable {
        case tcp = "TCP"
        case udp = "UDP"
    }

    var body: some View {
        Form {
            destinationSection
            capSection
            runSection
        }
        .keyboardDoneButton()
        .navigationTitle("Upload Throughput Test")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        // QA automation hook, same rationale as the app-level QA_TAB/QA_AUTOSTART
        // hooks: no Mac Accessibility permission available to type into fields or
        // tap Start, so env vars pre-fill this screen's state and optionally
        // trigger the run directly. DEBUG-only, compiled out of Release/IPA builds.
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if let host = env["QA_UPLOAD_HOST"] { destinationHost = host }
            if let port = env["QA_UPLOAD_PORT"] { destinationPort = port }
            if let proto = env["QA_UPLOAD_PROTOCOL"], proto.uppercased() == "UDP" { selectedProtocol = .udp }
            if let mb = env["QA_UPLOAD_CAP_MB"] { capMBText = mb }
            if let sec = env["QA_UPLOAD_CAP_SEC"] { capDurationText = sec }
            if let rate = env["QA_UPLOAD_RATE_MBPS"] { rateLimitMbpsText = rate }
            if env["QA_UPLOAD_AUTOSTART"] == "1" {
                // QA_UPLOAD_AUTOSTART_DELAY lets a run wait for a Client-tab VPN
                // started by the same launch (QA_CLIENT_AUTOCONNECT) to come up.
                let delay = env["QA_UPLOAD_AUTOSTART_DELAY"].flatMap(Double.init) ?? 0.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    runUploadTest()
                }
            }
        }
        #endif
    }

    // MARK: - Sections

    private var destinationSection: some View {
        Section {
            TextField("Destination host", text: $destinationHost)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            TextField("Destination port", text: $destinationPort)
                .keyboardType(.numberPad)
            Picker("Protocol", selection: $selectedProtocol) {
                ForEach(TestProtocol.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Destination")
        } footer: {
            Text("Send test data to a server you control — such as another device running NetBridge or your own backend — to measure achievable upload throughput over TCP or UDP.")
        }
    }

    private var capSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Transfer cap (MB)", text: $capMBText)
                    .keyboardType(.numberPad)
                if capMBExceedsCeiling {
                    Text("Capped at \(Caps.hardCeilingMB) MB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Max duration (sec)", text: $capDurationText)
                    .keyboardType(.numberPad)
                if durationExceedsCeiling {
                    Text("Capped at \(Int(Caps.maxDurationSeconds)) sec")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            TextField("Rate limit (Mbps, optional)", text: $rateLimitMbpsText)
                .keyboardType(.numberPad)
        } header: {
            Text("Limits")
        } footer: {
            Text("Stops automatically at whichever of the transfer/duration limits is hit first — hard-capped at \(Caps.hardCeilingMB) MB / \(Int(Caps.maxDurationSeconds / 60)) minutes regardless of what's entered above. Leave rate limit blank to measure maximum throughput, or set it to pace a steady, realistic sustained load. One connection, synthetic data only — this is a link test, not a stress test.")
        }
    }

    private var runSection: some View {
        Section {
            Button {
                runUploadTest()
            } label: {
                HStack {
                    Text("Start Upload Test")
                    if running {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(running || !isValidConfig)
            if running && progressBytes > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(progressBytes), countStyle: .binary)) sent…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            statusView(status)
        }
    }

    // MARK: - Validation / live-clamp captions

    private var isValidConfig: Bool {
        guard !destinationHost.isEmpty, UInt16(destinationPort) != nil else { return false }
        guard let mb = Int(capMBText), mb > 0 else { return false }
        guard let seconds = Int(capDurationText), seconds > 0 else { return false }
        return true
    }

    private var capMBExceedsCeiling: Bool {
        guard let mb = Int(capMBText) else { return false }
        return mb > Caps.hardCeilingMB
    }

    private var durationExceedsCeiling: Bool {
        guard let seconds = Int(capDurationText) else { return false }
        return TimeInterval(seconds) > Caps.maxDurationSeconds
    }

    @ViewBuilder
    private func statusView(_ status: TestStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.footnote)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundColor(.red)
                .font(.footnote)
        }
    }

    // MARK: - Core test

    private func runUploadTest() {
        guard let destPort = UInt16(destinationPort), let nwPort = NWEndpoint.Port(rawValue: destPort) else { return }
        guard let requestedMB = Int(capMBText), requestedMB > 0,
              let requestedSeconds = Int(capDurationText), requestedSeconds > 0 else { return }

        running = true
        status = .idle
        progressBytes = 0

        // Single enforcement point for both hard caps — everything downstream
        // trusts only these two computed values, never the raw text fields.
        let byteCap = UInt64(min(requestedMB, Caps.hardCeilingMB)) * 1_000_000
        let durationCap = min(TimeInterval(requestedSeconds), Caps.maxDurationSeconds)
        // Same accepted range as a device cap; out-of-range or non-finite
        // text (e.g. pasted "inf") means no limit instead of trapping.
        let limiter: RateLimiter? = Double(rateLimitMbpsText)
            .flatMap { BandwidthPreset.bytesPerSecond(mbps: $0) }
            .map { RateLimiter(bytesPerSecond: $0) }

        let proto = selectedProtocol
        let host = destinationHost
        let chunkSize = proto == .tcp ? Caps.tcpChunkSize : Caps.udpDatagramSize
        var chunkBytes = [UInt8](repeating: 0, count: chunkSize)
        chunkBytes.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                arc4random_buf(base, ptr.count)
            }
        }
        let chunk = Data(chunkBytes)

        let stats = ProxyStats()
        let run = UploadTestRun()
        let start = Date()

        let connection: NWConnection = proto == .tcp
            ? DirectTCPTransport().dial(host: host, port: nwPort)
            : NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: EgressTTL.udp)

        var lastProgressUpdate = Date.distantPast

        func finish(_ result: TestStatus) {
            run.finishOnce {
                // Cancelling right after queuing the final send (fire-and-forget)
                // can tear the connection down before already-buffered data
                // actually reaches the wire — confirmed empirically (netcat
                // received 0 bytes despite every chunk's own completion firing
                // success). Waiting for the final send's own completion before
                // cancelling avoids truncating it. UDP has no such buffering
                // ambiguity (each send is already a complete, standalone
                // datagram by the time its own completion fires), so it can
                // cancel immediately.
                func closeAndReport() {
                    connection.cancel()
                    let bytesSent = stats.bytesUp
                    DebugLog.important("uploadtest", "finished: bytes=\(bytesSent) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(start)))s result=\(result)")
                    DispatchQueue.main.async {
                        running = false
                        status = result
                        progressBytes = bytesSent
                    }
                }
                if proto == .tcp {
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                        closeAndReport()
                    })
                } else {
                    closeAndReport()
                }
            }
        }

        DebugLog.important("uploadtest", "starting: \(host):\(destPort) proto=\(proto.rawValue) byteCap=\(byteCap) durationCap=\(durationCap)s rateLimitMbps=\(limiter == nil ? "unlimited" : rateLimitMbpsText)")

        // Backstop: guarantees the test can never hang indefinitely even if
        // the peer stops reading and every completion handler stalls.
        DispatchQueue.global().asyncAfter(deadline: .now() + durationCap + 3) {
            finish(makeResult(stats: stats, start: start, proto: proto, cappedByTime: true))
        }

        func makeResult(stats: ProxyStats, start: Date, proto: TestProtocol, cappedByTime: Bool) -> TestStatus {
            let bytesSent = stats.bytesUp
            let elapsed = max(0.001, Date().timeIntervalSince(start))
            let mbps = Double(bytesSent) * 8 / 1_000_000 / elapsed
            let mb = Double(bytesSent) / 1_000_000
            var message = cappedByTime
                ? String(format: "Sent %.1fMB in %.1fs (time cap reached) — %.1f Mbps", mb, elapsed, mbps)
                : String(format: "Sent %.1fMB (cap reached) in %.1fs — %.1f Mbps", mb, elapsed, mbps)
            if proto == .udp {
                message += " (UDP: attempted send rate — no delivery confirmation from the destination)"
            }
            return .success(message)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .setup, .preparing:
                break
            case .ready:
                sendNext()
            case .waiting(let error):
                DebugLog.important("uploadtest", "waiting: \(ErrorDescription.describe(error))")
            case .failed(let error):
                finish(.failure("Connection failed: \(ErrorDescription.describe(error))"))
            case .cancelled:
                finish(.failure("Connection cancelled"))
            @unknown default:
                break
            }
        }

        func sendNext() {
            guard run.isActive else { return }

            let bytesSent = stats.bytesUp
            if bytesSent >= byteCap {
                finish(makeResult(stats: stats, start: start, proto: proto, cappedByTime: false))
                return
            }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= durationCap {
                finish(makeResult(stats: stats, start: start, proto: proto, cappedByTime: true))
                return
            }

            let remaining = byteCap - bytesSent
            // TCP: slice the tail chunk to land exactly on byteCap. UDP never
            // splits a datagram mid-flight — the loop's cap check on the next
            // iteration stops things instead.
            let thisChunk: Data = {
                guard proto == .tcp else { return chunk }
                return remaining < UInt64(chunk.count) ? chunk.prefix(Int(remaining)) : chunk
            }()

            func doSend() {
                connection.send(
                    content: thisChunk,
                    contentContext: .defaultMessage,
                    isComplete: proto == .udp,
                    completion: .contentProcessed { error in
                        if let error = error {
                            finish(.failure("Send failed after \(bytesSent) bytes: \(ErrorDescription.describe(error))"))
                            return
                        }
                        stats.addBytesUp(thisChunk.count)
                        if Date().timeIntervalSince(lastProgressUpdate) > 0.25 {
                            lastProgressUpdate = Date()
                            let sent = stats.bytesUp
                            DispatchQueue.main.async { progressBytes = sent }
                        }
                        sendNext()
                    }
                )
            }

            if let limiter = limiter {
                let delay = limiter.consume(thisChunk.count)
                if delay > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: doSend)
                    return
                }
            }
            doSend()
        }

        connection.start(queue: .global())
    }
}

private enum TestStatus {
    case idle
    case success(String)
    case failure(String)
}

/// Holds the live `NWConnection` so it isn't deallocated mid-flight, and
/// guards against the duration-cap watchdog and the real completion path
/// both firing — same shape as `Socks5ClientTestView`'s private `TestRun`,
/// plus `isActive` so the send loop can cheaply check "has this already
/// finished" before queuing another chunk.
private final class UploadTestRun {
    private let lock = NSLock()
    private var isFinished = false

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !isFinished
    }

    func finishOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        body()
    }
}
