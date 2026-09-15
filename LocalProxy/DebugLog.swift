import Foundation
import Network
import os
import UIKit

/// Full-debug file logger. Writes timestamped, categorized, tunnel-tagged lines to
/// `Documents/localproxy.log` (retrievable via Files or the dashboard's Share Logs), and
/// mirrors every line to `os_log` so it can be streamed live in Console.app over USB.
///
/// The previous session's log is kept as `localproxy.prev.log` instead of being deleted,
/// so relaunching the app never destroys evidence of a failure.
final class DebugLog {
    enum Level: String {
        case info = "INFO"
        case debug = "DEBUG"
        case trace = "TRACE"
    }

    static let shared = DebugLog()

    private static let verboseKey = "localproxy.log.verbose"
    private static let traceKey = "localproxy.log.trace"
    private static let maxBytes: UInt64 = 20 * 1024 * 1024

    private let queue = DispatchQueue(label: "localproxy.debuglog")
    private let osLog = OSLog(subsystem: "com.localproxy.app", category: "localproxy")
    private let formatter: DateFormatter
    private let sessionStart = DispatchTime.now()
    private let logURL: URL
    private let prevURL: URL
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0

    // Read from every network callback; writes come from the dashboard toggles.
    private let flagsLock = NSLock()
    private var _verbose: Bool
    private var _trace: Bool

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logURL = docs.appendingPathComponent("localproxy.log")
        prevURL = docs.appendingPathComponent("localproxy.prev.log")
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        _verbose = UserDefaults.standard.object(forKey: Self.verboseKey) as? Bool ?? true
        _trace = UserDefaults.standard.bool(forKey: Self.traceKey)
        // Launch rotation must not touch LogMirror: it would re-enter DebugLog.shared
        // while this initializer is still running.
        queue.sync { rotate(notifyMirror: false) }
    }

    static var localLogURL: URL { shared.logURL }

    // MARK: - Flags

    var verbose: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _verbose }
        set {
            flagsLock.lock(); _verbose = newValue; flagsLock.unlock()
            UserDefaults.standard.set(newValue, forKey: Self.verboseKey)
            Self.info("app", "verbose logging \(newValue ? "ON" : "OFF")")
        }
    }

    var trace: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _trace }
        set {
            flagsLock.lock(); _trace = newValue; flagsLock.unlock()
            UserDefaults.standard.set(newValue, forKey: Self.traceKey)
            Self.info("app", "trace data logging \(newValue ? "ON" : "OFF")")
        }
    }

    // MARK: - Static API

    static func info(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        shared.write(.info, category, tunnel, message(), sync: false)
    }

    /// INFO line that is flushed to disk immediately — use for errors, failures and closes.
    static func important(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        shared.write(.info, category, tunnel, message(), sync: true)
    }

    static func debug(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        guard shared.verbose else { return }
        shared.write(.debug, category, tunnel, message(), sync: false)
    }

    static func trace(_ category: String, tunnel: Int? = nil, _ message: @autoclosure () -> String) {
        guard shared.trace else { return }
        shared.write(.trace, category, tunnel, message(), sync: false)
    }

    static func mark(_ note: String = "") {
        shared.write(.info, "mark", nil, "==== USER MARK ==== \(note)", sync: true)
        // Push the marker to iCloud Drive right away rather than on the next tick.
        shared.queue.async { LogMirror.shared.flushSoon() }
    }

    static var fileURLs: [URL] {
        [shared.logURL, shared.prevURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var logSizeBytes: UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: shared.logURL.path)[.size] as? UInt64) ?? 0
    }

    static func clear() {
        shared.queue.sync {
            LogMirror.shared.flushSync()
            try? shared.handle?.close()
            shared.handle = nil
            try? FileManager.default.removeItem(at: shared.logURL)
            shared.openFresh()
            LogMirror.shared.startNewPart()
        }
        info("app", "log cleared by user")
    }

    /// Milliseconds since this app session started — monotonic, unaffected by clock changes.
    static func elapsedMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - shared.sessionStart.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Session header

    static func writeSessionHeader(port: Int, locationStatus: String, keepAlive: Bool) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let process = ProcessInfo.processInfo
        important("app", "===== SESSION START =====")
        important("app", "app \(version) (\(build)), iOS \(UIDevice.current.systemVersion), device \(machine)")
        important("app", "locale \(Locale.current.identifier), timezone \(TimeZone.current.identifier), wall clock \(Date())")
        important("app", "lowPowerMode=\(process.isLowPowerModeEnabled) thermalState=\(describe(process.thermalState))")
        important("app", "location auth=\(locationStatus) keepAliveRunning=\(keepAlive)")
        important("app", "listener port=\(port) verbose=\(shared.verbose) trace=\(shared.trace)")
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    // MARK: - Writing

    private func write(_ level: Level, _ category: String, _ tunnel: Int?, _ message: String, sync: Bool) {
        let now = Date()
        let elapsed = Self.elapsedMs()
        let tunnelTag = tunnel.map { " [T\($0)]" } ?? ""
        let line = String(format: "[%@ +%.1fms] [%@] [%@]%@ %@\n",
                          formatter.string(from: now), elapsed, level.rawValue, category, tunnelTag, message)
        os_log("%{public}@", log: osLog, type: level == .info ? .default : .debug, line)

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if self.handle == nil { self.openFresh() }
            self.handle?.write(data)
            self.bytesWritten += UInt64(data.count)
            if sync { self.handle?.synchronizeFile() }
            if self.bytesWritten > Self.maxBytes { self.rotate(notifyMirror: true) }
        }
    }

    /// Must run on `queue`. Moves the current log to `.prev` and starts a fresh file.
    private func rotate(notifyMirror: Bool) {
        handle?.synchronizeFile()
        if notifyMirror { LogMirror.shared.flushSync() }
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: logURL.path) {
            try? fm.removeItem(at: prevURL)
            try? fm.moveItem(at: logURL, to: prevURL)
        }
        openFresh()
        if notifyMirror { LogMirror.shared.startNewPart() }
    }

    /// Must run on `queue`.
    private func openFresh() {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()
        bytesWritten = 0
    }
}

// MARK: - Error formatting shared by every component

enum ErrorDescription {
    /// Full, greppable description of an `NWError`, including the POSIX code number and name
    /// (e.g. `posix 50 ENETDOWN "Network is down"`).
    static func describe(_ error: Error?) -> String {
        guard let error = error else { return "nil" }
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code):
                return "posix \(code.rawValue) \(posixName(code.rawValue)) \"\(nw.localizedDescription)\""
            case .dns(let code):
                return "dns \(code) \"\(nw.localizedDescription)\""
            case .tls(let status):
                return "tls \(status) \"\(nw.localizedDescription)\""
            default:
                return "nw \(nw.debugDescription)"
            }
        }
        let ns = error as NSError
        return "\(String(reflecting: error)) [domain=\(ns.domain) code=\(ns.code)]"
    }

    static func posixName(_ code: Int32) -> String {
        switch code {
        case EPERM: return "EPERM"
        case ENOENT: return "ENOENT"
        case EINTR: return "EINTR"
        case EBADF: return "EBADF"
        case ENOMEM: return "ENOMEM"
        case EACCES: return "EACCES"
        case EINVAL: return "EINVAL"
        case EPIPE: return "EPIPE"
        case EAGAIN: return "EAGAIN"
        case ENOTSOCK: return "ENOTSOCK"
        case EADDRINUSE: return "EADDRINUSE"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case ENETDOWN: return "ENETDOWN"
        case ENETUNREACH: return "ENETUNREACH"
        case ENETRESET: return "ENETRESET"
        case ECONNABORTED: return "ECONNABORTED"
        case ECONNRESET: return "ECONNRESET"
        case ENOBUFS: return "ENOBUFS"
        case EISCONN: return "EISCONN"
        case ENOTCONN: return "ENOTCONN"
        case ESHUTDOWN: return "ESHUTDOWN"
        case ETIMEDOUT: return "ETIMEDOUT"
        case ECONNREFUSED: return "ECONNREFUSED"
        case EHOSTDOWN: return "EHOSTDOWN"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ECANCELED: return "ECANCELED"
        case EMFILE: return "EMFILE"
        default: return "errno\(code)"
        }
    }
}

// MARK: - iCloud Drive mirror

/// Copies the log into a folder the user picked (e.g. in iCloud Drive) so it syncs to their
/// Mac automatically. Uses a security-scoped bookmark from the document picker instead of
/// an iCloud container, which would need a paid-account-only entitlement and break free
/// sideloading. The local log stays the source of truth; new bytes are appended to
/// `localproxy-<session>.log` in the folder every few seconds and immediately on Mark.
final class LogMirror {
    static let shared = LogMirror()

    private static let bookmarkKey = "localproxy.log.mirrorBookmark"

    private let queue = DispatchQueue(label: "localproxy.logmirror", qos: .utility)
    private let stateLock = NSLock()
    private var folderURL: URL?
    private var accessing = false
    private var mirroredOffset: UInt64 = 0
    private var part = 1
    private var timer: DispatchSourceTimer?
    private let sessionStamp: String
    private var _status = "Not set"

    /// Human-readable destination + last result, for the dashboard.
    var status: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _status
    }

    private init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        sessionStamp = formatter.string(from: Date())
    }

    /// Resolves the saved folder (if any) and starts the periodic copy. Call once at launch.
    func start() {
        queue.async {
            if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
                var stale = false
                do {
                    let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
                    self.adopt(url)
                    if stale { self.saveBookmark(for: url) }
                    DebugLog.important("app", "log mirror folder restored: \(url.path) stale=\(stale)")
                } catch {
                    self.setStatus("Saved folder unavailable — choose it again")
                    DebugLog.important("app", "log mirror bookmark failed to resolve: \(ErrorDescription.describe(error))")
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 3, repeating: .seconds(3))
            timer.setEventHandler { [weak self] in self?.flush() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Called with the folder URL returned by the document picker.
    func setFolder(_ url: URL) {
        queue.async {
            self.adopt(url)
            self.saveBookmark(for: url)
            self.mirroredOffset = 0 // copy the whole current session into the new folder
            DebugLog.important("app", "log mirror folder set: \(url.path)")
            self.flush()
        }
    }

    func clearFolder() {
        queue.async {
            if self.accessing { self.folderURL?.stopAccessingSecurityScopedResource() }
            self.folderURL = nil
            self.accessing = false
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            self.setStatus("Not set")
            DebugLog.important("app", "log mirror folder cleared")
        }
    }

    func flushSoon() {
        queue.async { self.flush() }
    }

    /// Blocks until any unmirrored bytes are copied. Used before the local log is rotated
    /// or cleared so nothing is lost.
    func flushSync() {
        queue.sync { self.flush() }
    }

    /// The local log was rotated or cleared: continue in a new remote file from offset 0.
    func startNewPart() {
        queue.sync {
            self.part += 1
            self.mirroredOffset = 0
        }
    }

    // MARK: Private (all on `queue`)

    private func adopt(_ url: URL) {
        if accessing { folderURL?.stopAccessingSecurityScopedResource() }
        accessing = url.startAccessingSecurityScopedResource()
        folderURL = url
        setStatus("\(url.lastPathComponent) — waiting for first copy")
    }

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            DebugLog.important("app", "log mirror bookmark save failed: \(ErrorDescription.describe(error))")
        }
    }

    private func flush() {
        guard let folder = folderURL else { return }
        let local = DebugLog.localLogURL
        guard let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? UInt64) ?? nil,
              size > mirroredOffset else { return }

        let newBytes: Data
        do {
            let reader = try FileHandle(forReadingFrom: local)
            defer { try? reader.close() }
            reader.seek(toFileOffset: mirroredOffset)
            newBytes = reader.readDataToEndOfFile()
        } catch {
            setStatus("Read failed: \(error.localizedDescription)")
            return
        }
        guard !newBytes.isEmpty else { return }

        let fileName = "localproxy-\(sessionStamp)\(part > 1 ? "-part\(part)" : "").log"
        let destination = folder.appendingPathComponent(fileName)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: [], error: &coordinationError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let writer = try FileHandle(forWritingTo: url)
                    defer { try? writer.close() }
                    writer.seekToEndOfFile()
                    writer.write(newBytes)
                } else {
                    try newBytes.write(to: url)
                }
            } catch {
                writeError = error
            }
        }

        if let error = writeError ?? coordinationError {
            // Deliberately not logged through DebugLog every tick: that would grow the log
            // and retrigger this copy in a loop while iCloud is unavailable.
            let text = "Copy failed: \(error.localizedDescription)"
            if status != text {
                setStatus(text)
                DebugLog.important("app", "log mirror copy failed to \(destination.path): \(ErrorDescription.describe(error))")
            }
            return
        }
        mirroredOffset += UInt64(newBytes.count)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        setStatus("\(folder.lastPathComponent)/\(fileName) — synced \(formatter.string(from: Date()))")
    }

    private func setStatus(_ text: String) {
        stateLock.lock(); _status = text; stateLock.unlock()
    }
}
