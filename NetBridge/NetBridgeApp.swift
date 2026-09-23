import SwiftUI

@main
struct NetBridgeApp: App {
    init() {
        // Start logging infrastructure before any view or proxy object exists, so launch-time
        // network state is captured.
        _ = DebugLog.shared
        LogMirror.shared.start()
        NetworkDiagnostics.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
    }
}
