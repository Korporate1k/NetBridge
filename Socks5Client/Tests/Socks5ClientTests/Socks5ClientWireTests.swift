import XCTest
@testable import Socks5Client

final class Socks5ClientWireTests: XCTestCase {
    // MARK: - Greeting / method selection

    func testBuildGreeting() {
        XCTAssertEqual(Socks5ClientWire.buildGreeting(), Data([0x05, 0x01, 0x00]))
    }

    func testParseMethodSelectionNeedsMoreData() {
        guard case .needMoreData = Socks5ClientWire.parseMethodSelection(Data([0x05])) else {
            return XCTFail("expected .needMoreData")
        }
    }

    func testParseMethodSelectionOK() {
        guard case .ok = Socks5ClientWire.parseMethodSelection(Data([0x05, 0x00])) else {
            return XCTFail("expected .ok")
        }
    }

    func testParseMethodSelectionRejected() {
        guard case .rejected(let method) = Socks5ClientWire.parseMethodSelection(Data([0x05, 0xFF])) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(method, 0xFF)
    }

    func testParseMethodSelectionInvalidVersion() {
        guard case .invalidVersion(let version) = Socks5ClientWire.parseMethodSelection(Data([0x04, 0x00])) else {
            return XCTFail("expected .invalidVersion")
        }
        XCTAssertEqual(version, 0x04)
    }

    // MARK: - Request building

    func testBuildRequestIPv4() {
        let request = Socks5ClientWire.buildRequest(command: .connect, host: "93.184.216.34", port: 80)
        XCTAssertEqual(request, Data([0x05, 0x01, 0x00, 0x01, 93, 184, 216, 34, 0, 80]))
    }

    func testBuildRequestDomain() {
        let request = Socks5ClientWire.buildRequest(command: .connect, host: "example.com", port: 80)
        var expected = Data([0x05, 0x01, 0x00, 0x03, UInt8("example.com".utf8.count)])
        expected.append(contentsOf: Array("example.com".utf8))
        expected.append(contentsOf: [0, 80])
        XCTAssertEqual(request, expected)
    }

    func testBuildRequestIPv6() {
        let request = Socks5ClientWire.buildRequest(command: .connect, host: "::1", port: 443)
        var expected = Data([0x05, 0x01, 0x00, 0x04])
        expected.append(contentsOf: [UInt8](repeating: 0, count: 15))
        expected.append(1)
        expected.append(contentsOf: [1, 187])
        XCTAssertEqual(request, expected)
    }

    func testBuildRequestUDPAssociateCommandByte() {
        let request = Socks5ClientWire.buildRequest(command: .udpAssociate, host: "0.0.0.0", port: 0)
        XCTAssertEqual(request[request.startIndex + 1], 0x03)
    }

    // MARK: - Reply parsing

    func testParseReplySuccessIPv4() {
        let data = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        guard case .parsed(let code, let host, let port, let consumed) = Socks5ClientWire.parseReply(data) else {
            return XCTFail("expected .parsed")
        }
        XCTAssertEqual(code, 0x00)
        XCTAssertEqual(host, "0.0.0.0")
        XCTAssertEqual(port, 0)
        XCTAssertEqual(consumed, 10)
    }

    func testParseReplyFailureCode() {
        let data = Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        guard case .parsed(let code, _, _, _) = Socks5ClientWire.parseReply(data) else {
            return XCTFail("expected .parsed")
        }
        XCTAssertEqual(code, 0x05)
    }

    func testParseReplyDomain() {
        let name = "host"
        var data = Data([0x05, 0x00, 0x00, 0x03, UInt8(name.utf8.count)])
        data.append(contentsOf: Array(name.utf8))
        data.append(contentsOf: [0, 80])
        guard case .parsed(_, let host, let port, _) = Socks5ClientWire.parseReply(data) else {
            return XCTFail("expected .parsed")
        }
        XCTAssertEqual(host, "host")
        XCTAssertEqual(port, 80)
    }

    func testParseReplyIPv6() {
        var data = Data([0x05, 0x00, 0x00, 0x04])
        data.append(contentsOf: [UInt8](repeating: 0, count: 15))
        data.append(1)
        data.append(contentsOf: [1, 187])
        guard case .parsed(_, let host, let port, _) = Socks5ClientWire.parseReply(data) else {
            return XCTFail("expected .parsed")
        }
        XCTAssertEqual(host, "0:0:0:0:0:0:0:1")
        XCTAssertEqual(port, 443)
    }

    func testParseReplyNeedsMoreData() {
        guard case .needMoreData = Socks5ClientWire.parseReply(Data([0x05, 0x00])) else {
            return XCTFail("expected .needMoreData")
        }
    }

    func testParseReplyInvalidVersion() {
        let data = Data([0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        guard case .invalidVersion(let version) = Socks5ClientWire.parseReply(data) else {
            return XCTFail("expected .invalidVersion")
        }
        XCTAssertEqual(version, 0x04)
    }

    // MARK: - UDP datagram framing

    func testUDPDatagramRoundTrip() {
        let payload = Data([1, 2, 3])
        let datagram = Socks5ClientWire.buildUDPDatagram(host: "8.8.8.8", port: 53, payload: payload)
        guard case .parsed(let host, let port, let parsedPayload) = Socks5ClientWire.parseUDPDatagram(datagram) else {
            return XCTFail("expected .parsed")
        }
        XCTAssertEqual(host, "8.8.8.8")
        XCTAssertEqual(port, 53)
        XCTAssertEqual(parsedPayload, payload)
    }

    func testUDPDatagramDomainRoundTrip() {
        let payload = Data("hello".utf8)
        let datagram = Socks5ClientWire.buildUDPDatagram(host: "example.com", port: 443, payload: payload)
        guard case .parsed(let host, let port, let parsedPayload) = Socks5ClientWire.parseUDPDatagram(datagram) else {
            return XCTFail("expected .parsed")
        }
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 443)
        XCTAssertEqual(parsedPayload, payload)
    }

    func testUDPDatagramRejectsFragmentation() {
        var datagram = Socks5ClientWire.buildUDPDatagram(host: "8.8.8.8", port: 53, payload: Data([1]))
        datagram[datagram.startIndex + 2] = 1 // FRAG != 0
        guard case .invalid = Socks5ClientWire.parseUDPDatagram(datagram) else {
            return XCTFail("expected .invalid")
        }
    }

    func testUDPDatagramTooShortIsInvalid() {
        guard case .invalid = Socks5ClientWire.parseUDPDatagram(Data([0, 0])) else {
            return XCTFail("expected .invalid")
        }
    }
}
