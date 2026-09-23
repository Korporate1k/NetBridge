import Foundation
import Network

/// Errors a `Socks5Client`/`Socks5UDPAssociation` operation can fail with.
///
/// The `REP`-code cases cover the full RFC 1928 set, including two
/// (`connectionNotAllowedByRuleset`, `ttlExpired`) that NetBridge's own
/// server never sends — a real third-party SOCKS5 server this client dials
/// can legally return any of them.
public enum Socks5ClientError: Error {
    // Transport-level failures reaching or talking to the proxy itself.
    case dialFailed(NWError)
    case connectionClosed
    case sendFailed(NWError)
    case receiveFailed(NWError)

    // Protocol-level violations (malformed/unexpected bytes from the server).
    case malformedMethodSelection
    case malformedReply
    case malformedUDPDatagram
    case unexpectedProtocolVersion(UInt8)

    // No-auth specifically rejected (the only method this client offers).
    case noAcceptableAuthMethod

    // RFC 1929 username/password authentication failures.
    case authenticationFailed(status: UInt8)
    case malformedAuthReply
    case credentialTooLong(String)

    // One case per RFC 1928 REP code.
    case generalFailure
    case connectionNotAllowedByRuleset
    case networkUnreachable
    case hostUnreachable
    case connectionRefused
    case ttlExpired
    case commandNotSupported
    case addressTypeNotSupported

    /// Maps a raw SOCKS5 `REP` byte to the matching case, falling back to
    /// `.generalFailure` for any unrecognized/reserved value.
    public static func from(replyCode: UInt8) -> Socks5ClientError {
        switch replyCode {
        case 0x01: return .generalFailure
        case 0x02: return .connectionNotAllowedByRuleset
        case 0x03: return .networkUnreachable
        case 0x04: return .hostUnreachable
        case 0x05: return .connectionRefused
        case 0x06: return .ttlExpired
        case 0x07: return .commandNotSupported
        case 0x08: return .addressTypeNotSupported
        default: return .generalFailure
        }
    }
}

extension Socks5ClientError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .dialFailed(let error): return "dial failed: \(error)"
        case .connectionClosed: return "connection closed"
        case .sendFailed(let error): return "send failed: \(error)"
        case .receiveFailed(let error): return "receive failed: \(error)"
        case .malformedMethodSelection: return "malformed method-selection reply"
        case .malformedReply: return "malformed SOCKS5 reply"
        case .malformedUDPDatagram: return "malformed UDP datagram"
        case .unexpectedProtocolVersion(let version): return "unexpected protocol version \(version)"
        case .noAcceptableAuthMethod: return "server rejected no-auth"
        case .authenticationFailed(let status): return "authentication failed (status \(status))"
        case .malformedAuthReply: return "malformed authentication reply"
        case .credentialTooLong(let reason): return "credential too long: \(reason)"
        case .generalFailure: return "general SOCKS server failure"
        case .connectionNotAllowedByRuleset: return "connection not allowed by ruleset"
        case .networkUnreachable: return "network unreachable"
        case .hostUnreachable: return "host unreachable"
        case .connectionRefused: return "connection refused"
        case .ttlExpired: return "TTL expired"
        case .commandNotSupported: return "command not supported"
        case .addressTypeNotSupported: return "address type not supported"
        }
    }
}

extension Socks5ClientError: LocalizedError {
    public var errorDescription: String? { description }
}
