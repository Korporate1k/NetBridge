import Foundation
import Network
import os

// The shared client files (`ClientTunnelManager`, `KeychainStore`) reference `DebugLog`, whose real implementation
// is the iOS app's file logger (UIKit, server-side types). The tvOS client gets this os_log-backed stand-in with
// the same static API, so those files compile here unchanged (same approach as `NetBridgeMac/Sources/MacSupport.swift`).
enum DebugLog {
    private static let logger = Logger(subsystem: "com.Korporate1k.LocalProxy", category: "app")

    static func info(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        let text = message()
        logger.info("[\(category, privacy: .public)] \(text, privacy: .public)")
    }

    static func important(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        let text = message()
        logger.notice("[\(category, privacy: .public)] \(text, privacy: .public)")
    }

    static func debug(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("[\(category, privacy: .public)] \(text, privacy: .public)")
    }

    static func trace(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("[\(category, privacy: .public)] \(text, privacy: .public)")
    }
}
