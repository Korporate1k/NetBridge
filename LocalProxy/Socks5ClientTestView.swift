import SwiftUI
import Network
import Socks5Client

/// A diagnostic screen that uses the `Socks5Client` package to dial OUT to a
/// SOCKS5 server — this device's own listener, or another device's — and
/// exercises CONNECT and UDP ASSOCIATE. Same checks a manual `curl --socks5`/
/// hand-crafted DNS query test would do from a Mac, but built into the app so
/// a second device can be the client without needing a laptop at all.
struct Socks5ClientTestView: View {
    @State var proxyHost: String
    @State var proxyPort: String

    @State private var connectDestinationHost = "example.com"
    @State private var connectDestinationPort = "80"
    @State private var connectStatus: TestStatus = .idle
    @State private var connectRunning = false

    @State private var udpDestinationHost = "8.8.8.8"
    @State private var udpDestinationPort = "53"
    @State private var udpStatus: TestStatus = .idle
    @State private var udpRunning = false

    var body: some View {
        Form {
            proxySection
            connectSection
            udpSection
        }
        .keyboardDoneButton()
        .navigationTitle("SOCKS5 Client Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var proxySection: some View {
        Section {
            TextField("Proxy host", text: $proxyHost)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            TextField("Proxy port", text: $proxyPort)
                .keyboardType(.numberPad)
        } header: {
            Text("SOCKS5 proxy")
        } footer: {
            Text("The server to dial — e.g. another device running LocalProxy. Defaults to this device's own listener.")
        }
    }

    private var connectSection: some View {
        Section {
            TextField("Destination host", text: $connectDestinationHost)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            TextField("Destination port", text: $connectDestinationPort)
                .keyboardType(.numberPad)
            Button {
                runConnectTest()
            } label: {
                HStack {
                    Text("Test CONNECT")
                    if connectRunning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(connectRunning || !isValidConfig)
            statusView(connectStatus)
        } header: {
            Text("TCP CONNECT")
        } footer: {
            Text("Sends a plain HTTP GET through the proxy and shows the response's status line — the same check as curl --socks5.")
        }
    }

    private var udpSection: some View {
        Section {
            TextField("Destination host", text: $udpDestinationHost)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            TextField("Destination port", text: $udpDestinationPort)
                .keyboardType(.numberPad)
            Button {
                runUDPTest()
            } label: {
                HStack {
                    Text("Test UDP ASSOCIATE")
                    if udpRunning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(udpRunning || !isValidConfig)
            statusView(udpStatus)
        } header: {
            Text("UDP ASSOCIATE")
        } footer: {
            Text("Sends a DNS query through the proxy's UDP relay and waits for a reply.")
        }
    }

    private var isValidConfig: Bool {
        !proxyHost.isEmpty && UInt16(proxyPort) != nil
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

    // MARK: - CONNECT test

    private func runConnectTest() {
        guard let port = UInt16(proxyPort), let destPort = UInt16(connectDestinationPort) else { return }
        connectRunning = true
        connectStatus = .idle

        let run = TestRun()
        let start = DispatchTime.now()
        let client = Socks5Client(proxy: .init(host: proxyHost, port: port))
        client.logHandler = { DebugLog.debug("socks5client", $0) }
        let destinationHost = connectDestinationHost

        func finish(_ status: TestStatus) {
            run.finishOnce {
                run.connection?.cancel()
                DispatchQueue.main.async {
                    connectRunning = false
                    connectStatus = status
                }
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            finish(.failure("Timed out after 8s"))
        }

        client.connect(destinationHost: destinationHost, destinationPort: destPort) { result in
            switch result {
            case .failure(let error):
                finish(.failure(error.description))
            case .success(let connection):
                guard run.registerIfActive(connection: connection) else {
                    connection.cancel()
                    return
                }
                let elapsedMs = elapsedMilliseconds(since: start)
                let request = "GET / HTTP/1.1\r\nHost: \(destinationHost)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { sendError in
                    if let sendError = sendError {
                        finish(.failure("Connected in \(elapsedMs)ms, but request send failed: \(ErrorDescription.describe(sendError))"))
                        return
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error = error {
                            finish(.failure("Connected in \(elapsedMs)ms, but read failed: \(ErrorDescription.describe(error))"))
                            return
                        }
                        guard let data = data, !data.isEmpty else {
                            finish(.failure("Connected in \(elapsedMs)ms, but got no response"))
                            return
                        }
                        let text = String(decoding: data, as: UTF8.self)
                        let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? "\(data.count) bytes back"
                        finish(.success("Connected in \(elapsedMs)ms — \(firstLine)"))
                    }
                })
            }
        }
    }

    // MARK: - UDP ASSOCIATE test

    private func runUDPTest() {
        guard let port = UInt16(proxyPort), let destPort = UInt16(udpDestinationPort) else { return }
        udpRunning = true
        udpStatus = .idle

        let run = TestRun()
        let start = DispatchTime.now()
        let client = Socks5Client(proxy: .init(host: proxyHost, port: port))
        client.logHandler = { DebugLog.debug("socks5client", $0) }
        let destinationHost = udpDestinationHost

        func finish(_ status: TestStatus) {
            run.finishOnce {
                run.association?.cancel()
                DispatchQueue.main.async {
                    udpRunning = false
                    udpStatus = status
                }
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            finish(.failure("Timed out after 8s"))
        }

        client.associateUDP { result in
            switch result {
            case .failure(let error):
                finish(.failure(error.description))
            case .success(let association):
                guard run.registerIfActive(association: association) else {
                    association.cancel()
                    return
                }
                association.onReceive { _, _, payload in
                    let elapsedMs = elapsedMilliseconds(since: start)
                    finish(.success("Reply in \(elapsedMs)ms — \(payload.count) bytes"))
                }
                let query = Self.buildDNSQuery(domain: "example.com")
                association.send(payload: query, to: destinationHost, port: destPort) { error in
                    if let error = error {
                        finish(.failure("UDP ASSOCIATE ok, but send failed: \(error.description)"))
                    }
                }
            }
        }
    }

    /// A minimal, valid DNS query (fixed transaction ID, one question, type A,
    /// class IN) — enough to prove a real round trip through the UDP relay,
    /// without needing a full DNS response parser to judge success.
    private static func buildDNSQuery(domain: String) -> Data {
        var data = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(0x00)
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        return data
    }
}

private func elapsedMilliseconds(since start: DispatchTime) -> Int {
    Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

private enum TestStatus {
    case idle
    case success(String)
    case failure(String)
}

/// Holds the live resource from a test's completion (so it isn't deallocated
/// mid-flight — `Socks5UDPAssociation` in particular must be retained per its
/// documented contract) and guards against the timeout and the real
/// completion both firing.
private final class TestRun {
    private let lock = NSLock()
    private var isFinished = false
    var connection: NWConnection?
    var association: Socks5UDPAssociation?

    func finishOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        body()
    }

    /// Registers a resource that arrived just as the timeout fired — returns
    /// false (and the caller should cancel it itself) if the run already
    /// finished, so nothing outlives the test silently.
    func registerIfActive(connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        self.connection = connection
        return true
    }

    func registerIfActive(association: Socks5UDPAssociation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        self.association = association
        return true
    }
}
