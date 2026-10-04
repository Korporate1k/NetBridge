import SwiftUI

@main
struct NetBridgeTVApp: App {
    @StateObject private var model = TVClientModel()

    var body: some Scene {
        WindowGroup {
            TVClientView()
                .environmentObject(model)
        }
    }
}
