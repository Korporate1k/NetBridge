import XCTest
import Darwin
@testable import LWIPTunnelEngine

/// Offline tests for the engine <-> app packet path. Everything here runs over a plain `AF_UNIX SOCK_DGRAM`
/// socketpair — the same kind `TunnelEngine.start()` hands to tun2proxy — so none of it needs a tunnel, a device,
/// a proxy or the network.
final class TunnelEngineTests: XCTestCase {
    private var fds: [Int32] = [-1, -1]

    /// `fds[0]` stands in for the engine (writer), `fds[1]` for the app side the read loop drains.
    override func setUp() {
        super.setUp()
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds), 0, "socketpair failed errno=\(errno)")
    }

    override func tearDown() {
        for fd in fds where fd >= 0 { close(fd) }
        fds = [-1, -1]
        super.tearDown()
    }

    private func setBuffers(_ size: Int32) {
        var value = size
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &value, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &value, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    /// Writes one datagram in the engine's framing: 4-byte big-endian protocol family, then the packet.
    @discardableResult
    private func sendFramed(_ payload: [UInt8], family: Int32) -> Int {
        let f = UInt32(bitPattern: family)
        var datagram: [UInt8] = [UInt8(f >> 24 & 0xFF), UInt8(f >> 16 & 0xFF), UInt8(f >> 8 & 0xFF), UInt8(f & 0xFF)]
        datagram.append(contentsOf: payload)
        return datagram.withUnsafeBytes { send(fds[0], $0.baseAddress, $0.count, 0) }
    }

    private func newBuffer() -> [UInt8] { [UInt8](repeating: 0, count: 1500 + 64) }

    // MARK: - Framing and batching

    /// The whole point of batching: several queued datagrams come back from ONE call, in order, with their
    /// families, so the app makes one `writePackets` call instead of N.
    func testDrainsEveryQueuedDatagramInOneBatch() {
        for i in 0..<10 {
            sendFramed([UInt8(i), 0xAA, 0xBB], family: i.isMultiple(of: 2) ? AF_INET : AF_INET6)
        }
        var buf = newBuffer()

        let batch = TunnelEngine.readBatch(fd: fds[1], buf: &buf, maxBatch: 64)

        XCTAssertTrue(batch.keepGoing)
        XCTAssertEqual(batch.packets.count, 10)
        XCTAssertEqual(batch.families.count, batch.packets.count, "families must stay in step with packets")
        for i in 0..<10 {
            XCTAssertEqual(Array(batch.packets[i]), [UInt8(i), 0xAA, 0xBB], "packet \(i) wrong or out of order")
            XCTAssertEqual(batch.families[i], i.isMultiple(of: 2) ? AF_INET : AF_INET6)
        }
    }

    /// `maxBatch` is a hard ceiling; the rest stay queued for the next call rather than being lost.
    func testStopsAtMaxBatchAndLeavesTheRestQueued() {
        for i in 0..<10 { sendFramed([UInt8(i)], family: AF_INET) }
        var buf = newBuffer()

        let first = TunnelEngine.readBatch(fd: fds[1], buf: &buf, maxBatch: 4)
        XCTAssertEqual(first.packets.count, 4)
        XCTAssertEqual(Array(first.packets[0]), [0])

        let second = TunnelEngine.readBatch(fd: fds[1], buf: &buf, maxBatch: 4)
        XCTAssertEqual(second.packets.count, 4)
        XCTAssertEqual(Array(second.packets[0]), [4], "the next batch must resume where the last one stopped")
    }

    /// A datagram with only the 4-byte family header (or less) carries no packet. It must be skipped without
    /// desynchronising `packets` from `families` — they are zipped into `writePackets`, so a mismatch would
    /// mislabel every later packet's protocol.
    func testSkipsHeaderOnlyDatagramsWithoutDesynchronisingFamilies() {
        sendFramed([0x01], family: AF_INET)
        sendFramed([], family: AF_INET6)          // header only: no packet
        _ = [UInt8]([0x00, 0x02]).withUnsafeBytes { send(fds[0], $0.baseAddress, $0.count, 0) }  // shorter than a header
        sendFramed([0x03], family: AF_INET6)
        var buf = newBuffer()

        let batch = TunnelEngine.readBatch(fd: fds[1], buf: &buf, maxBatch: 64)

        XCTAssertEqual(batch.packets.count, 2, "only the two real packets should come through")
        XCTAssertEqual(batch.families.count, 2)
        XCTAssertEqual(Array(batch.packets[0]), [0x01])
        XCTAssertEqual(batch.families[0], AF_INET)
        XCTAssertEqual(Array(batch.packets[1]), [0x03])
        XCTAssertEqual(batch.families[1], AF_INET6, "the skipped datagrams must not shift the families")
    }

    /// How the read loop actually ends, and that packets read before the end are still handed over.
    ///
    /// `shutdown` is the mechanism, not `close`: see the test below — a datagram socketpair does not give a
    /// blocked reader an EOF when the peer closes. That is exactly why `TunnelEngine.stop()` calls
    /// `shutdown(appFd, SHUT_RDWR)` before closing, and this test pins that contract down.
    func testShutdownEndsTheReadLoopAndEarlierPacketsSurvive() {
        sendFramed([0x42], family: AF_INET)
        var buf = newBuffer()

        let batch = TunnelEngine.readBatch(fd: fds[1], buf: &buf, maxBatch: 64)
        XCTAssertEqual(batch.packets.count, 1, "the queued packet must be delivered")
        XCTAssertEqual(Array(batch.packets[0]), [0x42])
        XCTAssertTrue(batch.keepGoing)

        shutdown(fds[1], SHUT_RD)  // what stop() does to unblock a waiting reader

        let next = TunnelEngine.readBatch(fd: fds[1], buf: &buf, maxBatch: 64)
        XCTAssertFalse(next.keepGoing, "shutdown must end the read loop instead of blocking forever")
        XCTAssertNotNil(next.endReason)
    }

    /// The errnos the Rust engine's `device_gone()` has to classify, measured rather than assumed. After the peer
    /// closes, this transport reports **ECONNRESET (54)** on receive and **EDESTADDRREQ (39)** on send — never a
    /// clean EOF. A *blocking* recv past that point never returns at all, which is why classifying ECONNRESET as
    /// transient leaves the engine parked forever instead of reporting a dead device.
    func testPeerCloseReportsECONNRESETAndEDESTADDRREQRatherThanEOF() {
        sendFramed([0x01], family: AF_INET)
        close(fds[0])
        fds[0] = -1
        // Non-blocking deliberately: a blocking recv here would hang the whole suite — which is the finding.
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL, 0) | O_NONBLOCK)
        var buf = newBuffer()
        let bufLen = buf.count

        // Whether the already-queued datagram survives the peer's close is timing-dependent, so sample a few.
        var observed: [Int32] = []
        for _ in 0..<3 {
            let n = buf.withUnsafeMutableBytes { recv(fds[1], $0.baseAddress, bufLen, 0) }
            observed.append(n < 0 ? errno : 0)
        }
        XCTAssertTrue(observed.contains(ECONNRESET), "expected ECONNRESET (54) after the peer closed, saw \(observed)")

        let sent = [UInt8](repeating: 0, count: 8).withUnsafeBytes { send(fds[1], $0.baseAddress, $0.count, 0) }
        XCTAssertLessThan(sent, 0, "sending to a closed peer must fail")
        XCTAssertEqual(errno, EDESTADDRREQ, "expected EDESTADDRREQ (39) writing to a closed peer, got \(errno)")
    }

    // MARK: - The platform behaviour the ENOBUFS fix rests on

    /// Documents why patch 0004 exists. Darwin does not backpressure a datagram socketpair: once the reader falls
    /// far enough behind, `send` fails with **ENOBUFS (55)** — NOT EAGAIN/EWOULDBLOCK, so tokio does not treat it
    /// as "try again later" and the write surfaces as a hard error. It clears as soon as the reader takes one
    /// datagram, which is what makes retrying worthwhile.
    func testSocketpairFailsWithENOBUFSNotEAGAINAndRecoversAfterARead() {
        setBuffers(1 << 20)
        let flags = fcntl(fds[0], F_GETFL, 0)
        _ = fcntl(fds[0], F_SETFL, flags | O_NONBLOCK)

        let packet = [UInt8](repeating: 0xAB, count: 1500)
        var sent = 0
        var failure: Int32 = 0
        while sent < 100_000 {
            if sendFramed(packet, family: AF_INET) < 0 {
                failure = errno
                break
            }
            sent += 1
        }

        XCTAssertEqual(failure, ENOBUFS, "expected ENOBUFS (55), got errno \(failure)")
        XCTAssertNotEqual(failure, EAGAIN, "if this were EAGAIN the engine would have retried on its own")
        XCTAssertGreaterThan(sent, 100, "should absorb a real burst before failing")

        var buf = newBuffer()
        let bufLen = buf.count  // hoisted: reading buf.count inside withUnsafeMutableBytes overlaps its exclusive access
        let n = buf.withUnsafeMutableBytes { recv(fds[1], $0.baseAddress, bufLen, 0) }
        XCTAssertGreaterThan(n, 0)
        XCTAssertGreaterThan(sendFramed(packet, family: AF_INET), 0,
                             "one read should free the queue again — this is what the retry in patch 0004 waits for")
    }

    // MARK: - Configuration guards

    /// `verbosity` becomes a command-line value, and clap calls `exit()` on anything it does not recognise, which
    /// would take the whole extension down with no crash log. Unknown levels must fall back instead.
    func testRejectsUnknownVerbosityLevels() {
        let engine = TunnelEngine(proxyHost: "127.0.0.1", proxyPort: 1080, verbosity: "chatty; rm -rf /")
        XCTAssertEqual(Mirror(reflecting: engine).descendant("verbosity") as? String, TunnelEngine.defaultVerbosity)

        let good = TunnelEngine(proxyHost: "127.0.0.1", proxyPort: 1080, verbosity: "trace")
        XCTAssertEqual(Mirror(reflecting: good).descendant("verbosity") as? String, "trace")
        XCTAssertEqual(TunnelEngine.defaultVerbosity, "warn", "shipping default must stay off the packet path")
    }

    /// `stop()` before `start()` must not trip the state guards or crash.
    func testStopBeforeStartIsSafe() {
        let engine = TunnelEngine(proxyHost: "127.0.0.1", proxyPort: 1080)
        engine.stop()
        engine.stop()
    }
}
