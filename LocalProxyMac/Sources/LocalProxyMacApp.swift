import SwiftUI

@main
struct LocalProxyMacApp: App {
    @StateObject private var model = MacClientModel()

    var body: some Scene {
        WindowGroup("NetBridge") {
            MacRootView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 620)
    }
}
