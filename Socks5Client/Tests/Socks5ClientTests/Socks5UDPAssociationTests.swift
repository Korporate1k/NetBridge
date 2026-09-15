import XCTest
import Network
@testable import Socks5Client

final class Socks5UDPAssociationTests: XCTestCase {
    private var server: MockSocks5Server!

    override func setUpWithError() throws {
        server = MockSocks5Server()
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    private func makeClient() -> Socks5Client {
        Socks5Client(proxy: .init(host: "127.0.0.1", port: server.port))
    }

    func testSuccessfulAssociateAndEcho() {
        let associateExpectation = expectation(description: "associate succeeded")
        let echoExpectation = expectation(description: "datagram echoed back")
        // Held for the duration of the test: `Socks5UDPAssociation` is a
        // live resource (like `NWConnection` itself) that the caller must
        // retain — letting it fall out of scope cancels it via `deinit`.
        var association: Socks5UDPAssociation?

        makeClient().associateUDP { result in
            switch result {
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            case .success(let assoc):
                association = assoc
                associateExpectation.fulfill()
                assoc.onReceive { host, port, payload in
                    XCTAssertEqual(host, "93.184.216.34")
                    XCTAssertEqual(port, 80)
                    XCTAssertEqual(payload, Data("hello".utf8))
                    echoExpectation.fulfill()
                }
                assoc.send(payload: Data("hello".utf8), to: "93.184.216.34", port: 80) { error in
                    XCTAssertNil(error)
                }
            }
        }

        wait(for: [associateExpectation, echoExpectation], timeout: 5)
        _ = association
    }

    func testAssociateReplyFailureCode() {
        server.associateReplyCode = 0x01
        let expectation = expectation(description: "associate failed")
        makeClient().associateUDP { result in
            guard case .failure(.generalFailure) = result else {
                return XCTFail("expected .generalFailure, got \(result)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testControlConnectionDropTearsDownUDP() {
        let associateExpectation = expectation(description: "associate succeeded")
        let closeExpectation = expectation(description: "association closed")
        var association: Socks5UDPAssociation?

        makeClient().associateUDP { [self] result in
            switch result {
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            case .success(let assoc):
                association = assoc
                assoc.onClose = { _ in closeExpectation.fulfill() }
                associateExpectation.fulfill()
                server.dropControlConnection()
            }
        }

        wait(for: [associateExpectation, closeExpectation], timeout: 5)

        let sendExpectation = expectation(description: "send after close errors")
        association?.send(payload: Data([1]), to: "1.2.3.4", port: 80) { error in
            guard case .connectionClosed = error else {
                return XCTFail("expected .connectionClosed, got \(String(describing: error))")
            }
            sendExpectation.fulfill()
        }
        wait(for: [sendExpectation], timeout: 5)
    }

    func testMalformedIncomingDatagramIsDroppedNotDelivered() {
        let associateExpectation = expectation(description: "associate succeeded")
        var association: Socks5UDPAssociation?

        makeClient().associateUDP { result in
            switch result {
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            case .success(let assoc):
                association = assoc
                associateExpectation.fulfill()
            }
        }
        wait(for: [associateExpectation], timeout: 5)

        let receivedUnexpectedly = expectation(description: "onReceive should not fire")
        receivedUnexpectedly.isInverted = true
        association?.onReceive { _, _, _ in
            receivedUnexpectedly.fulfill()
        }
        // Marker payload the mock server recognizes and replies to with a
        // deliberately too-short, unparseable datagram.
        association?.send(payload: Data("TRIGGER_MALFORMED".utf8), to: "93.184.216.34", port: 80) { _ in }

        wait(for: [receivedUnexpectedly], timeout: 1.5)
    }
}
