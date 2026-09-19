import Foundation
import Network
import CoreTelephony
import UIKit

// MARK: - Shared formatters

enum PathDescription {
    /// One-line, greppable snapshot of an `NWPath`: status, why it's unsatisfied, which
    /// interfaces it can and does use, cost flags, address families, gateways, endpoints,
    /// and the framework's own debug description (which names NECP policy denials).
    static func describe(_ path: NWPath?) -> String {
        guard let path = path else { return "path=nil" }
        var parts: [String] = []
        parts.append("status=\(status(path.status))")
        if path.status != .satisfied {
            parts.append("unsatisfiedReason=\(path.unsatisfiedReason)")
        }
        let available = path.availableInterfaces.map { "\($0.name)(\(interfaceType($0.type)))" }
        parts.append("available=[\(available.joined(separator: ","))]")
        let allTypes: [NWInterface.InterfaceType] = [.cellular, .wifi, .wiredEthernet, .loopback, .other]
        let used = allTypes.filter { path.usesInterfaceType($0) }.map(interfaceType)
        parts.append("uses=[\(used.joined(separator: ","))]")
        parts.append("expensive=\(path.isExpensive) constrained=\(path.isConstrained)")
        parts.append("ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6) dns=\(path.supportsDNS)")
        let gateways = path.gateways.map(EndpointDescription.describe)
        parts.append("gateways=[\(gateways.joined(separator: ","))]")
        if let local = path.localEndpoint { parts.append("local=\(EndpointDescription.describe(local))") }
        if let remote = path.remoteEndpoint { parts.append("remote=\(EndpointDescription.describe(remote))") }
        if #available(iOS 26.0, *) {
            parts.append("linkQuality=\(path.linkQuality)")
        }
        parts.append("raw=\"\(path.debugDescription)\"")
        return parts.joined(separator: " ")
    }

    static func status(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requiresConnection"
        @unknown default: return "unknown"
        }
    }

    static func interfaceType(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .cellular: return "cellular"
        case .wifi: return "wifi"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}

enum EndpointDescription {
    /// Tags the address family so IPv4 vs IPv6 (and NAT64/CLAT-synthesized IPv6) is obvious.
    static func describe(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint = endpoint else { return "nil" }
        switch endpoint {
        case .hostPort(let host, let port):
            switch host {
            case .ipv4(let address):
                return "v4:\(address):\(port)"
            case .ipv6(let address):
                let text = "\(address)"
                let nat64 = text.lowercased().hasPrefix("64:ff9b:") ? "(nat64)" : ""
                return "v6\(nat64):[\(text)]:\(port)"
            case .name(let name, let interface):
                return "name:\(name):\(port)\(interface.map { "%\($0.name)" } ?? "")"
            @unknown default:
                return "host:\(host):\(port)"
            }
        default:
            return "\(endpoint)"
        }
    }

    /// Clean IPv4/IPv6 address string with no port or brackets, for use as a
    /// lookup key (e.g. GeoIP) rather than for display/logging.
    static func rawIP(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        default: return nil
        }
    }
}

enum DurationFormat {
    static func ms(since start: DispatchTime) -> String {
        ms(from: start, to: DispatchTime.now())
    }

    static func ms(from start: DispatchTime, to end: DispatchTime) -> String {
        String(format: "%.1fms", Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    static func ms(_ interval: TimeInterval) -> String {
        String(format: "%.1fms", interval * 1000)
    }
}

enum TransferReportDescription {
    static func describe(_ report: NWConnection.DataTransferReport) -> String {
        func path(_ p: NWConnection.DataTransferReport.PathReport) -> String {
            let radio = p.radioType.map { "\($0)" } ?? "nil"
            return "iface=\(p.interface.name)(\(PathDescription.interfaceType(p.interface.type))) radio=\(radio) sentTransportBytes=\(p.sentTransportByteCount) recvTransportBytes=\(p.receivedTransportByteCount) RETRANSMITTED=\(p.retransmittedTransportByteCount) recvDuplicate=\(p.receivedTransportDuplicateByteCount) recvOutOfOrder=\(p.receivedTransportOutOfOrderByteCount) sentAppBytes=\(p.sentApplicationByteCount) recvAppBytes=\(p.receivedApplicationByteCount) pktsSent=\(p.sentIPPacketCount) pktsRecv=\(p.receivedIPPacketCount) srtt=\(DurationFormat.ms(p.transportSmoothedRTT)) minRtt=\(DurationFormat.ms(p.transportMinimumRTT)) rttVar=\(DurationFormat.ms(p.transportRTTVariance))"
        }
        return "duration=\(DurationFormat.ms(report.duration)) aggregate{\(path(report.aggregatePathReport))} paths=[\(report.pathReports.map(path).joined(separator: " ; "))]"
    }
}

// MARK: - Interface table (getifaddrs)

struct InterfaceInfo: Equatable {
    var flags: UInt32 = 0
    var ipv4: Set<String> = []
    var ipv6: Set<String> = []
    var hasLinkData = false
    var ibytes: UInt32 = 0
    var obytes: UInt32 = 0
    var ipackets: UInt32 = 0
    var opackets: UInt32 = 0
    var ierrors: UInt32 = 0
    var oerrors: UInt32 = 0
    var iqdrops: UInt32 = 0

    var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    var isRunning: Bool { flags & UInt32(IFF_RUNNING) != 0 }

    var summary: String {
        let v4 = ipv4.sorted().joined(separator: ",")
        let v6 = ipv6.sorted().joined(separator: ",")
        return "up=\(isUp) running=\(isRunning) flags=0x\(String(flags, radix: 16)) v4=[\(v4)] v6=[\(v6)]"
    }

    /// Identity used for change detection — counters excluded (they change constantly).
    func sameConfiguration(as other: InterfaceInfo) -> Bool {
        flags == other.flags && ipv4 == other.ipv4 && ipv6 == other.ipv6
    }
}

enum InterfaceTable {
    static func snapshot() -> [String: InterfaceInfo] {
        var result: [String: InterfaceInfo] = [:]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return result }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            var info = result[name] ?? InterfaceInfo()
            info.flags = ifa.ifa_flags
            guard let addr = ifa.ifa_addr else { result[name] = info; continue }

            switch Int32(addr.pointee.sa_family) {
            case AF_INET, AF_INET6:
                if let ip = numericHost(addr) {
                    if Int32(addr.pointee.sa_family) == AF_INET { info.ipv4.insert(ip) } else { info.ipv6.insert(ip) }
                }
            case AF_LINK:
                if let data = ifa.ifa_data {
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    info.hasLinkData = true
                    info.ibytes = stats.ifi_ibytes
                    info.obytes = stats.ifi_obytes
                    info.ipackets = stats.ifi_ipackets
                    info.opackets = stats.ifi_opackets
                    info.ierrors = stats.ifi_ierrors
                    info.oerrors = stats.ifi_oerrors
                    info.iqdrops = stats.ifi_iqdrops
                }
            default:
                break
            }
            result[name] = info
        }
        return result
    }

    static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = host.withUnsafeMutableBufferPointer { buf -> Int32 in
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), buf.baseAddress, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        }
        return rc == 0 ? String(cString: host) : nil
    }
}

// MARK: - Session-wide monitors

/// Runs for the whole app session, independent of the proxy: network path monitors,
/// a 1 Hz interface table (with per-interface byte deltas while tunnels are open),
/// cellular radio technology, app lifecycle, power and thermal state.
final class NetworkDiagnostics {
    static let shared = NetworkDiagnostics()

    /// Set by `ProxyServer`; drives the per-interface byte-delta lines.
    var openTunnelCount: () -> Int = { 0 }

    private let queue = DispatchQueue(label: "localproxy.diagnostics", qos: .utility)
    private var monitors: [(String, NWPathMonitor)] = []
    private var lastPathText: [String: String] = [:]
    private var timer: DispatchSourceTimer?
    private var lastInterfaces: [String: InterfaceInfo] = [:]
    private var observers: [NSObjectProtocol] = []
    private let telephony = CTTelephonyNetworkInfo()
    private let cellularData = CTCellularData()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DebugLog.important("app", "diagnostics starting")
        startPathMonitors()
        startInterfaceTable()
        startRadio()
        startLifecycle()
    }

    // MARK: Path monitors

    private func startPathMonitors() {
        let specs: [(String, NWPathMonitor)] = [
            ("any", NWPathMonitor()),
            ("cellular", NWPathMonitor(requiredInterfaceType: .cellular)),
            ("wifi", NWPathMonitor(requiredInterfaceType: .wifi)),
            ("other", NWPathMonitor(requiredInterfaceType: .other)),
        ]
        for (label, monitor) in specs {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                let text = PathDescription.describe(path)
                // Every update is logged; flag when it's a real change vs a repeat.
                let changed = self.lastPathText[label] != text
                self.lastPathText[label] = text
                DebugLog.important("path", "monitor[\(label)] \(changed ? "CHANGED" : "update") \(text)")
            }
            monitor.start(queue: queue)
        }
        monitors = specs
    }

    // MARK: Interface table

    private func startInterfaceTable() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tickInterfaces() }
        timer.resume()
        self.timer = timer
    }

    private func tickInterfaces() {
        let current = InterfaceTable.snapshot()

        if lastInterfaces.isEmpty {
            for name in current.keys.sorted() {
                DebugLog.important("iface", "initial \(name) \(current[name]!.summary)")
            }
        } else {
            for name in Set(current.keys).union(lastInterfaces.keys).sorted() {
                switch (lastInterfaces[name], current[name]) {
                case (nil, let now?):
                    DebugLog.important("iface", "ADDED \(name) \(now.summary)")
                case (_?, nil):
                    DebugLog.important("iface", "REMOVED \(name)")
                case (let before?, let now?):
                    if !before.sameConfiguration(as: now) {
                        DebugLog.important("iface", "CHANGED \(name) before: \(before.summary) -> now: \(now.summary)")
                    }
                    if now.ierrors &- before.ierrors > 0 || now.oerrors &- before.oerrors > 0 || now.iqdrops &- before.iqdrops > 0 {
                        DebugLog.important("iface", "ERRORS \(name) +ierr=\(now.ierrors &- before.ierrors) +oerr=\(now.oerrors &- before.oerrors) +iqdrops=\(now.iqdrops &- before.iqdrops)")
                    }
                default:
                    break
                }
            }

            if openTunnelCount() > 0 {
                var deltas: [String] = []
                for name in current.keys.sorted() {
                    guard let now = current[name], let before = lastInterfaces[name], now.hasLinkData else { continue }
                    let din = now.ibytes &- before.ibytes
                    let dout = now.obytes &- before.obytes
                    if din > 0 || dout > 0 {
                        deltas.append("\(name) in=\(din) out=\(dout) pin=\(now.ipackets &- before.ipackets) pout=\(now.opackets &- before.opackets)")
                    }
                }
                DebugLog.debug("iface", "bytes/s tunnels=\(openTunnelCount()) \(deltas.isEmpty ? "(no traffic)" : deltas.joined(separator: " | "))")
            }
        }
        lastInterfaces = current
    }

    // MARK: Radio

    private func startRadio() {
        DebugLog.important("radio", "radio access technology at start: \(describeRadio())")
        let observer = NotificationCenter.default.addObserver(
            forName: .CTServiceRadioAccessTechnologyDidChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self = self else { return }
            DebugLog.important("radio", "RADIO CHANGED service=\(note.object ?? "?") now: \(self.describeRadio())")
        }
        observers.append(observer)

        cellularData.cellularDataRestrictionDidUpdateNotifier = { state in
            let text: String
            switch state {
            case .restricted: text = "restricted"
            case .notRestricted: text = "notRestricted"
            case .restrictedStateUnknown: text = "unknown"
            @unknown default: text = "unknown(\(state.rawValue))"
            }
            DebugLog.important("radio", "app cellular data restriction: \(text)")
        }
    }

    private func describeRadio() -> String {
        guard let map = telephony.serviceCurrentRadioAccessTechnology, !map.isEmpty else { return "none" }
        return map.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "CTRadioAccessTechnology", with: ""))" }
            .joined(separator: ",")
    }

    // MARK: Lifecycle / power

    private func startLifecycle() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "screenLocking (protectedDataWillBecomeUnavailable)"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "screenUnlocked (protectedDataDidBecomeAvailable)"),
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING"),
            (UIApplication.willTerminateNotification, "willTerminate"),
        ]
        for (name, label) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                DebugLog.important("lifecycle", label)
            })
        }

        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            DebugLog.important("lifecycle", "thermal state -> \(DebugLog.describe(ProcessInfo.processInfo.thermalState))")
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            DebugLog.important("lifecycle", "low power mode -> \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        })

        DispatchQueue.main.async {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            DebugLog.important("lifecycle", "battery \(Self.batteryText()) state=\(Self.batteryStateText()) idleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled) appState=\(Self.appStateText())")
            self.observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: nil) { _ in
                DebugLog.important("lifecycle", "battery state -> \(Self.batteryStateText()) level=\(Self.batteryText())")
            })
            self.observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: nil) { _ in
                DebugLog.debug("lifecycle", "battery level -> \(Self.batteryText())")
            })
        }
    }

    private static func batteryText() -> String {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "unknown" : "\(Int(level * 100))%"
    }

    private static func batteryStateText() -> String {
        switch UIDevice.current.batteryState {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private static func appStateText() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
