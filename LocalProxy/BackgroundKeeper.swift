import Foundation
import CoreLocation

/// Best-effort background keep-alive: continuous location updates under
/// "Always" authorization discourage iOS from suspending the process while it
/// is backgrounded — the standard workaround, since iOS has no public API for
/// keeping a local network listener alive in the background. Not a guarantee —
/// the reliable mode remains keeping the app foreground.
final class BackgroundKeeper: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isKeepingAlive = false
    @Published private(set) var lastUpdate: Date?

    private let manager = CLLocationManager()
    private var updateCount = 0

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
        DebugLog.important("location", "init authorization=\(Self.describe(authorizationStatus)) servicesEnabled=\(CLLocationManager.locationServicesEnabled())")
        // `start()` was previously only auto-invoked from
        // `locationManagerDidChangeAuthorization`, which fires on a status *change* —
        // so a relaunch where the user had already granted "Always" in a prior
        // session left keep-alive silently off until the toggle was flipped again.
        if authorizationStatus == .authorizedAlways {
            start()
        }
    }

    func requestAlways() {
        DebugLog.important("location", "requestAlways from authorization=\(Self.describe(manager.authorizationStatus))")
        switch manager.authorizationStatus {
        case .notDetermined:
            // iOS 13+ only offers "Always" as an upgrade after "When In Use".
            manager.requestWhenInUseAuthorization()
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization() // upgrade prompt
        default:
            break
        }
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled(),
              manager.authorizationStatus == .authorizedAlways else {
            DebugLog.important("location", "keep-alive start SKIPPED servicesEnabled=\(CLLocationManager.locationServicesEnabled()) authorization=\(Self.describe(manager.authorizationStatus))")
            return
        }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isKeepingAlive = true
        DebugLog.important("location", "keep-alive STARTED")
    }

    func stop() {
        manager.stopUpdatingLocation()
        isKeepingAlive = false
        DebugLog.important("location", "keep-alive STOPPED after \(updateCount) updates")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        DebugLog.important("location", "authorization changed -> \(Self.describe(manager.authorizationStatus))")
        if manager.authorizationStatus == .authorizedAlways {
            start() // auto-start keep-alive once the user upgrades to Always
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastUpdate = Date()
        updateCount += locations.count
        DebugLog.debug("location", "update #\(updateCount) (\(locations.count) fix(es)) accuracy=\(locations.last.map { String(format: "%.0fm", $0.horizontalAccuracy) } ?? "?")")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isKeepingAlive = false
        DebugLog.important("location", "didFailWithError \(ErrorDescription.describe(error)) — keep-alive marked off")
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        DebugLog.important("location", "iOS PAUSED location updates")
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        DebugLog.important("location", "iOS resumed location updates")
    }

    static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
