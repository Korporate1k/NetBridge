import XCTest
import Network
@testable import Socks5Client

final class Socks5ClientConnectTests: XCTestCase {
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

    func testSuccessfulConnectAndEcho() {
        let expectation = expectation(description: "connect + echo")
        let client = makeClient()
        client.connect(destinationHost: "example.com", destinationPort: 80) { result in
            switch result {
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            case .success(let connection):
                let payload = Data("ping".utf8)
                connection.send(content: payload, completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    XCTAssertEqual(data, payload)
                    connection.cancel()
                    expectation.fulfill()
                }
            }
        }
        wait(for: [expectation], timeout: 5)
    }

    func testAuthRejected() {
        server.rejectAuth = true
        let expectation = expectation(description: "auth rejected")
        makeClient().connect(destinationHost: "example.com", destinationPort: 80) { result in
            guard case .failure(.noAcceptableAuthMethod) = result else {
                return XCTFail("expected .noAcceptableAuthMethod, got \(result)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testConnectionRefusedReplyCode() {
        server.connectReplyCode = 0x05
        let expectation = expectation(description: "connection refused")
        makeClient().connect(destinationHost: "example.com", destinationPort: 80) { result in
            guard case .failure(.connectionRefused) = result else {
                return XCTFail("expected .connectionRefused, got \(result)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testHostUnreachableReplyCode() {
        server.connectReplyCode = 0x04
        let expectation = expectation(description: "host unreachable")
        makeClient().connect(destinationHost: "example.com", destinationPort: 80) { result in
            guard case .failure(.hostUnreachable) = result else {
                return XCTFail("expected .hostUnreachable, got \(result)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testCommandNotSupportedReplyCode() {
        server.connectReplyCode = 0x07
        let expectation = expectation(description: "command not supported")
        makeClient().connect(destinationHost: "example.com", destinationPort: 80) { result in
            guard case .failure(.commandNotSupported) = result else {
                return XCTFail("expected .commandNotSupported, got \(result)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testServerClosesWithoutRepliyingToGreeting() {
        server.closeBeforeMethodSelection = true
        let expectation = expectation(description: "connection closed")
        makeClient().connect(destinationHost: "example.com", destinationPort: 80) { result in
            guard case .failure(.connectionClosed) = result else {
                return XCTFail("expected .connectionClosed, got \(result)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testDialFailsWhenNothingIsListening() {
        // Port 1 is (almost certainly) not bound to anything on the loopback
        // interface in a test environment — exercises the dial-failure path.
        let client = Socks5Client(proxy: .init(host: "127.0.0.1", port: 1))
        let expectation = expectation(description: "dial failed")
        client.connect(destinationHost: "example.com", destinationPort: 80) { result in
            guard case .failure(.dialFailed) = result else {
                return XCTFail("expected .dialFailed, got \(result)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }
}
