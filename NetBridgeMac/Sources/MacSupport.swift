import SwiftUI
import Network
import os

// The iOS app's shared files (`ClientTunnelManager`, `Socks5ClientTestView`, ...)
// reference `DebugLog`, `ErrorDescription` and a few UIKit-only SwiftUI modifiers.
// The real `DebugLog.swift` / `GlassEffects.swift` pull in UIKit and server-side
// types, so the Mac target gets these small stand-ins instead and the iOS files
// compile here unchanged.

/// os_log-backed stand-in for the iOS file logger, same static API.
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

enum ErrorDescription {
    static func describe(_ error: Error?) -> String {
        guard let error else { return "nil" }
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code): return "posix \(code.rawValue) \"\(nw.localizedDescription)\""
            case .dns(let code): return "dns \(code) \"\(nw.localizedDescription)\""
            case .tls(let status): return "tls \(status) \"\(nw.localizedDescription)\""
            default: return "nw \(nw.debugDescription)"
            }
        }
        let ns = error as NSError
        return "\(String(reflecting: error)) [domain=\(ns.domain) code=\(ns.code)]"
    }
}

// MARK: - UIKit-only SwiftUI modifiers (no-ops on macOS)

enum KeyboardTypeCompat { case URL, numberPad }
enum AutocapitalizationCompat { case none }
enum TitleDisplayModeCompat { case inline }

extension View {
    func keyboardType(_ type: KeyboardTypeCompat) -> some View { self }
    func autocapitalization(_ style: AutocapitalizationCompat) -> some View { self }
    func navigationBarTitleDisplayMode(_ mode: TitleDisplayModeCompat) -> some View { self }
    func keyboardDoneButton() -> some View { self }
}
